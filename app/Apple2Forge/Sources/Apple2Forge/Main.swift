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
/// UI test hooks (the app starts normally, then acts as the menus would):
///   --launch=TITLE_ID        Start the title, as choosing it in the Library menu does.
///   --swap-after=S:D:PATH    S seconds later, insert disks/PATH into drive D, as the Disk menu does.
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
                                                romDirectory: settings.romDirectory)
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
        return nil
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
        arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
    }
}
