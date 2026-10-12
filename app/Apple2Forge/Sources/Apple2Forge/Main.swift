import Apple2ForgeCore
import Foundation

/// Command-line modes, for the app gate and for scripting. With none of these
/// flags the app starts normally.
///   --dump-menu              Print the Library menu as indented text and exit.
///   --library=DIR            Use DIR instead of the remembered library folder.
///   --set-library=DIR        Validate and remember DIR as the library folder, then exit.
///   --print-library          Print the remembered library folder and exit.
///   --defaults-suite=NAME    Keep settings in the NAME defaults domain (tests).
///   --download-to=DIR [--limit=N]  Run download → catalog → sweep into DIR, then exit.
///   --print-launch=TITLE_ID  Print the a2emu arguments for a title and exit.
///   --build=DISK [--t2]      Run the build pipeline on DISK, print each stage, then exit
///                            (0 when Analyze and Wrap (T1) pass, plus the T2 stages with --t2).
///   --project=DIR            Use DIR as the apple2-native project folder.
///   --builds-dir=DIR         Write builds to DIR instead of Application Support.
/// UI test hooks (the app starts normally, then acts as the menus would):
///   --launch=TITLE_ID        Start the title, as choosing it in the Library menu does.
///   --swap-after=S:D:PATH    S seconds later, insert disks/PATH into drive D, as the Disk menu does.
///   --drop=PATH              Queue PATH as a drop on the Build tab does (repeatable; --t2 tries T2).
///   --quit-after-build=S     Quit S seconds after the build queue empties.
@main
enum Apple2ForgeMain {
    static func main() {
        // A disk change written after a2emu quits must fail as an error, not end the app.
        signal(SIGPIPE, SIG_IGN)
        let options = CommandLineOptions(CommandLine.arguments.dropFirst())
        AppSettings.shared.configure(suite: options.value("--defaults-suite"),
                                     libraryOverride: options.value("--library"),
                                     launchTitleID: options.value("--launch"),
                                     swapAfter: options.value("--swap-after"))
        AppSettings.shared.configureBuildTool(project: options.value("--project"),
                                              buildsDirectory: options.value("--builds-dir"),
                                              drops: options.values("--drop"), t2: options.has("--t2"),
                                              quitAfterBuild: options.value("--quit-after-build"))
        if let status = runCommandLineMode(options) {
            exit(status)
        }
        Apple2ForgeApp.main()
    }

    private static func runCommandLineMode(_ options: CommandLineOptions) -> Int32? {
        let settings = AppSettings.shared
        if let folder = options.value("--set-library") {
            do {
                try settings.locationStore.save(URL(filePath: folder, directoryHint: .isDirectory))
                print(folder)
                return 0
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                return 2
            }
        }
        if options.has("--print-library") {
            print(settings.libraryDirectory.path)
            return 0
        }
        if options.has("--dump-menu") {
            do {
                print(try LibraryCatalog.load(fromLibrary: settings.libraryDirectory).menuOutline, terminator: "")
                return 0
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if let titleID = options.value("--print-launch") {
            do {
                let catalog = try LibraryCatalog.load(fromLibrary: settings.libraryDirectory)
                guard let title = catalog.titles.first(where: { $0.id == titleID }) else {
                    fputs("ERROR: no title with id \(titleID)\n", stderr)
                    return 2
                }
                let launch = try EmulatorLaunch(title: title, libraryDirectory: settings.libraryDirectory,
                                                romDirectory: settings.romDirectory,
                                                options: settings.emulatorOptions)
                print(([launch.windowTitle] + launch.arguments).joined(separator: "\n"))
                return 0
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if let folder = options.value("--download-to") {
            return runDownload(into: URL(filePath: folder, directoryHint: .isDirectory),
                               limit: options.value("--limit").flatMap(Int.init))
        }
        if let disk = options.value("--build") {
            return runBuild(disk: URL(filePath: disk), attemptT2: options.has("--t2"))
        }
        return nil
    }

    private static func runBuild(disk: URL, attemptT2: Bool) -> Int32 {
        guard DiskTypes.accepts(disk) else {
            fputs("ERROR: \(disk.lastPathComponent) is not a disk image (.dsk, .do, .po or .nib)\n", stderr)
            return 2
        }
        guard let project = AppSettings.shared.project else {
            fputs("ERROR: the apple2-native project folder was not found; pass --project=DIR\n", stderr)
            return 2
        }
        let pipeline = BuildPipeline(project: project, buildsRoot: AppSettings.shared.buildsDirectory)
        let finished = DispatchSemaphore(value: 0)
        let status = LockedStatus()
        // Stop the running stage's whole process tree, then let the pipeline report.
        let signalSources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { pipeline.cancel() }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }
        Task.detached {
            let record = await pipeline.run(disk: disk, attemptT2: attemptT2) { event in
                switch event {
                case .started(let slug, let folder): print("== \(slug) → \(folder.path)")
                case .status(let stage, let stageStatus):
                    guard stageStatus != .running else { return }
                    print("\(stage.rawValue): \(stageStatus.label)\(stageStatus.detail.map { " (\($0))" } ?? "")")
                case .log(_, let line): fputs(line + "\n", stderr)
                }
            }
            print("Tier: \(record.report.tier.rawValue)")
            print("T2 possible: \(record.report.t2Possible)")
            var required: [BuildStage] = [.analyze, .package]
            if record.analysis?.supported == true { required.append(.wrapT1) }
            if attemptT2 { required += [.capture, .coverage, .recompile] }
            if !required.allSatisfy({ record.status(of: $0) == .passed }) { status.value = 1 }
            finished.signal()
        }
        finished.wait()
        return status.value
    }

    private static func runDownload(into folder: URL, limit: Int?) -> Int32 {
        guard let tools = ToolPaths.locate() else {
            fputs("ERROR: the bundled scripts or a2emu are missing; rebuild Apple2Forge.app\n", stderr)
            return 2
        }
        do {
            try LibraryLocation.validate(folder)
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            return 2
        }
        let pipeline = DownloadPipeline(tools: tools, library: folder,
                                        romDirectory: AppSettings.shared.romDirectory, limit: limit)
        let finished = DispatchSemaphore(value: 0)
        let status = LockedStatus()
        Task.detached {
            do {
                try await pipeline.run { event in
                    switch event {
                    case .started(let step): print("== \(step.rawValue)")
                    case .skipped(let step, let reason): print("== \(step.rawValue): skipped. \(reason)")
                    case .progress(let progress): print("   \(progress.doneFiles)/\(progress.totalFiles) files")
                    case .log(let line): fputs(line + "\n", stderr)
                    }
                }
            } catch {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
                status.value = 1
            }
            finished.signal()
        }
        finished.wait()
        return status.value
    }
}

private final class LockedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = 0
    var value: Int32 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct CommandLineOptions {
    private let arguments: [String]

    init(_ arguments: ArraySlice<String>) {
        self.arguments = Array(arguments)
    }

    func has(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    func value(_ flag: String) -> String? {
        values(flag).first
    }

    func values(_ flag: String) -> [String] {
        arguments.filter { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
    }
}
