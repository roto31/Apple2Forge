import AppKit
import Apple2ForgeCore
import Observation

/// One coverage recording kept with a build (builds/<slug>/recordings/<time>/).
struct CoverageRecording: Identifiable, Equatable {
    let folder: URL
    let summary: String
    var id: URL { folder }
    var name: String { folder.lastPathComponent }
}

/// One dropped disk and its pipeline progress.
@MainActor @Observable
final class BuildItem: Identifiable {
    enum State { case waiting, running, finished }
    private static let logTailLength = 6

    let id = UUID()
    let disk: URL
    let attemptT2: Bool
    var state = State.waiting
    var stages = Dictionary(uniqueKeysWithValues: BuildStage.allCases.map { ($0, StageStatus.pending) })
    var outputFolder: URL?
    var record: BuildRecord?
    var logTail: [String] = []
    var recordings: [CoverageRecording] = []
    var isRecording = false
    var message: String?

    init(disk: URL, attemptT2: Bool) {
        self.disk = disk
        self.attemptT2 = attemptT2
    }

    var name: String { disk.lastPathComponent }

    func apply(_ event: BuildEvent) {
        switch event {
        case .started(_, let folder):
            outputFolder = folder
        case .status(let stage, let status):
            stages[stage] = status
        case .log(_, let line):
            logTail.append(line)
            if logTail.count > Self.logTailLength { logTail.removeFirst(logTail.count - Self.logTailLength) }
        }
    }

    func logURL(_ stage: BuildStage) -> URL? {
        guard let outputFolder else { return nil }
        let url = BuildPipeline.logURL(outputFolder: outputFolder, stage: stage)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Builds dropped disks one at a time, and runs coverage recordings.
@MainActor @Observable
final class BuildQueue {
    static let shared = BuildQueue()

    private(set) var items: [BuildItem] = []
    private(set) var rejections: [String] = []
    private var pipeline: BuildPipeline?
    private var recorders: [ScriptRunner] = []
    /// Called each time the queue runs dry after a build.
    var onQueueEmpty: (() -> Void)?

    var isBuilding: Bool { pipeline != nil }

    func add(_ urls: [URL], attemptT2: Bool = false) {
        for url in urls {
            if DiskTypes.accepts(url) {
                items.append(BuildItem(disk: url, attemptT2: attemptT2))
            } else {
                rejections.append("\(url.lastPathComponent) is not a disk image. Apple2Forge takes .dsk, .do, .po and .nib files.")
            }
        }
        startNext()
    }

    func dismissRejections() {
        rejections.removeAll()
    }

    func tryT2(_ item: BuildItem) {
        add([item.disk], attemptT2: true)
    }

    func cancel(_ item: BuildItem) {
        switch item.state {
        case .running: pipeline?.cancel()
        case .waiting: items.removeAll { $0 === item }
        case .finished: break
        }
    }

    /// On quit: stop the running build and any recorder, children included.
    func stopAll() {
        pipeline?.cancel()
        recorders.forEach { $0.cancel() }
    }

    func removeFinished() {
        items.removeAll { $0.state == .finished && !$0.isRecording }
    }

    private func startNext() {
        guard pipeline == nil else { return }
        guard let next = items.first(where: { $0.state == .waiting }) else { return }
        guard let project = AppSettings.shared.project else {
            next.stages[.analyze] = .failed("The apple2-native project folder was not found. Choose it in Apple2Forge > Settings.")
            next.state = .finished
            startNext()
            return
        }
        let pipeline = BuildPipeline(project: project, buildsRoot: AppSettings.shared.buildsDirectory)
        self.pipeline = pipeline
        next.state = .running
        Task {
            // Events arrive on the main queue in order, ahead of this task's resumption.
            let record = await pipeline.run(disk: next.disk, attemptT2: next.attemptT2) { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { next.apply(event) } }
            }
            next.record = record
            next.state = .finished
            loadRecordings(next)
            self.pipeline = nil
            if items.contains(where: { $0.state == .waiting }) {
                startNext()
            } else {
                onQueueEmpty?()
            }
        }
    }

    // MARK: Coverage recordings

    func record(_ item: BuildItem) {
        guard let output = item.outputFolder else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let folder = output.appending(path: "recordings/\(formatter.string(from: Date()))", directoryHint: .isDirectory)
        runRecorder(item, arguments: [item.disk.path, "--out", folder.path], log: folder.appending(path: "record.log"),
                    done: "Recording saved. Its coverage report is below.")
    }

    func replay(_ item: BuildItem, _ recording: CoverageRecording) {
        runRecorder(item, arguments: [item.disk.path, "--out", recording.folder.path, "--replay"],
                    log: recording.folder.appending(path: "replay.log"),
                    done: "Replay finished; replay.log says whether it ran the recorded code exactly.")
    }

    private func runRecorder(_ item: BuildItem, arguments: [String], log: URL, done: String) {
        guard let project = AppSettings.shared.project else {
            item.message = "The project folder was not found. Choose it in Apple2Forge > Settings."
            return
        }
        item.isRecording = true
        item.message = "The emulator window is open. Play every menu and mode you want covered, then close the window."
        let runner = ScriptRunner()
        recorders.append(runner)
        Task {
            let status = try? await runner.run(project.file(ProjectTools.recordScript), arguments: arguments,
                                               in: project.root, log: log) { _ in }
            recorders.removeAll { $0 === runner }
            item.isRecording = false
            item.message = status == 0 ? done : "The recorder failed. See \(log.path)."
            loadRecordings(item)
        }
    }

    private func loadRecordings(_ item: BuildItem) {
        guard let output = item.outputFolder else { return }
        let root = output.appending(path: "recordings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        item.recordings = folders.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { folder in
            struct Report: Decodable {
                let keys: Int
                let executedBytes: Int
                enum CodingKeys: String, CodingKey { case keys; case executedBytes = "executed_bytes" }
            }
            guard let data = try? Data(contentsOf: folder.appending(path: "record.json")),
                  let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
            return CoverageRecording(folder: folder,
                                     summary: "\(report.keys) keys, \(report.executedBytes) bytes of code ran")
        }
    }

    // MARK: Files

    func export(_ app: URL, item: BuildItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = app.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: app, to: destination)
            item.message = "Exported \(destination.lastPathComponent). It is for your personal use only."
        } catch {
            item.message = "Export failed: \(error.localizedDescription)"
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The first-run checklist: Stage 0's gates plus the files builds need.
@MainActor @Observable
final class SetupModel {
    static let shared = SetupModel()

    private(set) var gateItems: [SetupCheckItem] = []
    private(set) var fileItems: [SetupCheckItem] = []
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?

    var items: [SetupCheckItem] { gateItems + fileItems }
    var hasPassed: Bool { AppSettings.shared.defaults.bool(forKey: AppSettings.setupCheckPassedKey) }
    var allPassed: Bool { exitStatus == 0 && items.allSatisfy(\.passed) }

    var logURL: URL { AppSettings.shared.logDirectory.appending(path: "setup-check.log") }

    func runIfFirstLaunch() {
        refreshFiles()
        if !hasPassed && !isRunning && exitStatus == nil { run() }
    }

    func refreshFiles() {
        guard let project = AppSettings.shared.project else {
            fileItems = [SetupCheckItem(name: "Project folder", passed: false,
                                        detail: "not found: choose the apple2-native folder in Settings")]
            return
        }
        fileItems = [SetupCheckItem(name: "Project folder", passed: true, detail: project.root.path)]
            + SetupCheck.files(project: project, romDirectory: AppSettings.shared.romDirectory)
    }

    func run() {
        refreshFiles()
        guard let project = AppSettings.shared.project else { return }
        isRunning = true
        let log = logURL
        Task {
            let status = (try? await ScriptRunner().run(project.file(ProjectTools.setupScript), arguments: [],
                                                        in: project.root, log: log) { _ in }) ?? -1
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            gateItems = SetupCheck.gates(fromSummary: text.components(separatedBy: "\n"))
            exitStatus = status
            refreshFiles()
            isRunning = false
            AppSettings.shared.defaults.set(allPassed, forKey: AppSettings.setupCheckPassedKey)
        }
    }
}
