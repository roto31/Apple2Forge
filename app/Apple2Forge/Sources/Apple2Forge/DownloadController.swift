import AppKit
import Apple2ForgeCore
import Observation

/// Library ▸ Download Educational Library… and Change Library Location….
/// Asks where the library goes (the default folder or one picked with the
/// standard folder panel), remembers the choice, then runs the bundled
/// download, catalog and compatibility scripts and reports their progress.
@MainActor
@Observable
final class DownloadController {
    enum State: Equatable {
        case idle
        case running(PipelineStep)
        case finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var progress = DownloadProgress()
    private(set) var log: [String] = []
    private(set) var notes: [String] = []
    private var pipeline: DownloadPipeline?
    private static let logLimit = 400

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Returns false if the user cancelled or nothing could start.
    @discardableResult
    func startDownload(library: LibraryModel) -> Bool {
        guard !isRunning else { return true }
        guard let folder = chooseLocation(message: "Where should the educational library be saved?",
                                          info: "About 330 MB of disk images. The default is your Application Support folder.")
        else { return false }
        return startDownload(library: library, to: folder)
    }

    /// Saves `folder` as the library location and runs download → catalog → sweep.
    @discardableResult
    func startDownload(library: LibraryModel, to folder: URL) -> Bool {
        guard !isRunning else { return true }
        guard pythonIsAvailable() else {
            state = .failed("python3 is missing. Install the Xcode command-line tools (xcode-select --install), then try again.")
            return true
        }
        guard let tools = ToolPaths.locate() else {
            state = .failed("The bundled download scripts are missing. Rebuild Apple2Forge.app (tools/60_build_app.sh).")
            return true
        }
        do {
            try AppSettings.shared.locationStore.save(folder)
        } catch {
            state = .failed(error.localizedDescription)
            return true
        }
        FirstRunState(defaults: AppSettings.shared.defaults).clearLibraryDeclined()
        library.reload()
        let pipeline = DownloadPipeline(tools: tools, library: folder, romDirectory: AppSettings.shared.romDirectory)
        run(pipeline, library: library) { try await pipeline.run(onEvent: $0) }
        return true
    }

    func changeLocation(library: LibraryModel) {
        guard chooseLocation(message: "Choose where the educational library is kept.",
                             info: "If the folder has no library yet, use Library ▸ Download Educational Library….") != nil
        else { return }
        library.reload()
    }

    /// Library ▸ Rebuild Catalog: only the catalog step, e.g. after editing the subject rules.
    func rebuildCatalog(library: LibraryModel) {
        guard !isRunning, let tools = ToolPaths.locate() else { return }
        let pipeline = DownloadPipeline(tools: tools, library: library.directory,
                                        romDirectory: AppSettings.shared.romDirectory)
        run(pipeline, library: library) { try await pipeline.runCatalogOnly(onEvent: $0) }
    }

    func cancel() {
        pipeline?.cancel()
    }

    // MARK: - Running

    private func run(_ pipeline: DownloadPipeline, library: LibraryModel,
                     operation: @escaping (@escaping @Sendable (PipelineEvent) -> Void) async throws -> Void) {
        self.pipeline = pipeline
        progress = DownloadProgress()
        log = []
        notes = []
        state = .running(.download)
        Task {
            do {
                try await operation { event in Task { @MainActor in self.handle(event) } }
                finish(library: library, error: nil)
            } catch {
                finish(library: library, error: error)
            }
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .started(let step): state = .running(step)
        case .progress(let update): progress = update
        case .skipped(let step, let reason): notes.append("\(step.rawValue) skipped: \(reason)")
        case .log(let line):
            log.append(line)
            if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        }
    }

    private func finish(library: LibraryModel, error: Error?) {
        pipeline = nil
        library.reload()
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .finished
        }
    }

    // MARK: - Location

    /// The alert from the Library menu: Use Default Location, Choose Location…, or Cancel.
    /// A valid choice is remembered and returned.
    private func chooseLocation(message: String, info: String) -> URL? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "Use Default Location")
        alert.addButton(withTitle: "Choose Location…")
        alert.addButton(withTitle: "Cancel")
        let folder: URL
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            folder = LibraryLocation.defaultDirectory
        case .alertSecondButtonReturn:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Use This Folder"
            panel.directoryURL = AppSettings.shared.libraryDirectory.deletingLastPathComponent()
            guard panel.runModal() == .OK, let picked = panel.url else { return nil }
            folder = picked
        default:
            return nil
        }
        do {
            try AppSettings.shared.locationStore.save(folder)
            return folder
        } catch {
            let problem = NSAlert()
            problem.alertStyle = .warning
            problem.messageText = "That folder can’t hold the library."
            problem.informativeText = error.localizedDescription
            problem.runModal()
            return nil
        }
    }

    private func pythonIsAvailable() -> Bool {
        let check = Process()
        check.executableURL = URL(filePath: "/usr/bin/xcode-select")
        check.arguments = ["-p"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
    }
}