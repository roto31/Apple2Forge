import Foundation

public enum BuildStage: String, CaseIterable, Codable, Sendable {
    case analyze = "Analyze"
    case wrapT1 = "Wrap (T1)"
    case capture = "Capture"
    case coverage = "Coverage"
    case recompile = "Recompile (T2)"
    case package = "Package"

    public var logName: String {
        switch self {
        case .analyze: "analyze"
        case .wrapT1: "wrap-t1"
        case .capture: "capture"
        case .coverage: "coverage"
        case .recompile: "recompile"
        case .package: "package"
        }
    }
}

public enum StageStatus: Codable, Sendable, Equatable {
    case pending
    case running
    case passed
    case failed(String)
    case skipped(String)

    public var label: String {
        switch self {
        case .pending: "WAITING"
        case .running: "RUNNING"
        case .passed: "PASS"
        case .failed: "FAIL"
        case .skipped: "SKIPPED"
        }
    }

    public var detail: String? {
        switch self {
        case .failed(let text), .skipped(let text): text
        default: nil
        }
    }
}

/// Disk image types the drop zone takes. The analyzer decides which it can use.
public enum DiskTypes {
    public static let extensions: Set<String> = ["dsk", "do", "po", "nib"]

    public static func accepts(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

public struct BuildRecord: Codable, Sendable, Equatable {
    public struct Stage: Codable, Sendable, Equatable {
        public let stage: BuildStage
        public let status: StageStatus
    }

    public let disk: String
    public let disks: [String]?
    public let slug: String
    public let sha256: String
    public let profile: String?
    public let machine: Machine?
    public let analysis: AnalysisSummary?
    public let stages: [Stage]
    public let report: CompatibilityReport
    public let t1App: String?
    public let t2App: String?
    public let outputFolder: String

    public func status(of stage: BuildStage) -> StageStatus? {
        stages.first { $0.stage == stage }?.status
    }
}

public enum BuildEvent: Sendable, Equatable {
    case started(slug: String, outputFolder: URL)
    case status(BuildStage, StageStatus)
    case log(BuildStage, String)
}

/// Analyze → Wrap (T1) → Capture → Coverage → Recompile (T2) → Package for one
/// disk, by running the project's stage scripts. Capture, Coverage and
/// Recompile run only for disks with a T2 profile and only when asked
/// (they take minutes). Products are copied to BUILDS/<slug>/.
public final class BuildPipeline: @unchecked Sendable {
    private let project: ProjectTools
    private let buildsRoot: URL
    private let runner = ScriptRunner()
    private static let coverageJobs = 4
    private static let recompileJobs = 8

    public init(project: ProjectTools, buildsRoot: URL) {
        self.project = project
        self.buildsRoot = buildsRoot
    }

    public static var defaultBuildsRoot: URL {
        LibraryLocation.supportDirectory.appending(path: "builds", directoryHint: .isDirectory)
    }

    public func cancel() {
        runner.cancel()
    }

    public static func logURL(outputFolder: URL, stage: BuildStage) -> URL {
        outputFolder.appending(path: "logs/\(stage.logName).log")
    }

    public func run(disks: [URL], displayName: String, romDirectory: URL, attemptT2: Bool,
                    onEvent: @escaping @Sendable (BuildEvent) -> Void) async -> BuildRecord {
        let disk = disks[0]
        let slug = (try? diskSlug(disk)) ?? "disk"
        let output = buildsRoot.appending(path: slug, directoryHint: .isDirectory)
        setAsidePreviousBuild(in: output)
        onEvent(.started(slug: slug, outputFolder: output))
        var stages = Dictionary(uniqueKeysWithValues: BuildStage.allCases.map { ($0, StageStatus.pending) })
        func set(_ stage: BuildStage, _ status: StageStatus) {
            stages[stage] = status
            onEvent(.status(stage, status))
        }
        func runScript(_ stage: BuildStage, _ script: String, _ arguments: [String],
                       appendToLog: Bool = false) async -> Bool {
            set(stage, .running)
            let log = Self.logURL(outputFolder: output, stage: stage)
            do {
                let status = try await runner.run(project.file(script), arguments: arguments, in: project.root,
                                                  log: log, appendToLog: appendToLog) { onEvent(.log(stage, $0)) }
                if status == 0 { return true }
                set(stage, .failed(runner.isCancelled ? "cancelled" : "\(script) exited \(status); see the log"))
            } catch {
                set(stage, .failed("could not start \(script): \(error.localizedDescription)"))
            }
            return false
        }

        let sha = (try? BuildProfile.sha256(of: disk)) ?? ""
        let profile = (try? BuildProfile.load(from: project.file(ProjectTools.profilesFile)))?
            .first { $0.diskSHA256 == sha }
        let work = project.workDirectory(slug: slug)
        let baseName = displayName
        let t1App = work.appending(path: "t1/\(baseName).app")
        let t2App = work.appending(path: "t2/\(baseName) (T2-hybrid).app")
        var wrappedMachine: Machine?

        // Analyze
        var analysis: AnalysisSummary?
        if await runScript(.analyze, ProjectTools.analyzeScript, [disk.path]) {
            do {
                analysis = try AnalysisSummary.load(fromAnalysis: work.appending(path: "analysis.json"))
                set(.analyze, .passed)
            } catch {
                set(.analyze, .failed("no analysis.json: \(error.localizedDescription)"))
            }
        }

        // Wrap (T1)
        if let analysis, analysis.supported {
            let wrapArgs = disks.map(\.path) + ["--name", baseName, "--rom-dir", romDirectory.path]
            if await runScript(.wrapT1, ProjectTools.wrapT1Script, wrapArgs) {
                wrappedMachine = Self.machine(in: t1App)
                set(.wrapT1, .passed)
            }
        } else {
            set(.wrapT1, .skipped(analysis.map { "Unsupported: \($0.headline)" } ?? "Analyze did not pass"))
        }

        // Capture → Coverage → Recompile (T2)
        let t2Stages: [BuildStage] = [.capture, .coverage, .recompile]
        if let reason = Self.reasonToSkipT2(analysis: analysis, t1Passed: stages[.wrapT1] == .passed,
                                            profile: profile, attemptT2: attemptT2) {
            t2Stages.forEach { set($0, .skipped(reason)) }
        } else {
            let diskArguments = ["--disk", disk.path]
            func runT2Stage(_ stage: BuildStage) async -> Bool {
                switch stage {
                case .capture:
                    return await runScript(.capture, ProjectTools.captureScript, diskArguments)
                case .coverage:
                    let sessions = (profile?.coverageSessions ?? []).flatMap { ["--sessions", project.file($0).path] }
                    return await runScript(.coverage, ProjectTools.coverageScript,
                                           diskArguments + sessions + ["--jobs", "\(Self.coverageJobs)"])
                default:
                    guard await runScript(.recompile, ProjectTools.recompileScript,
                                          diskArguments + ["--jobs", "\(Self.recompileJobs)"])
                    else { return false }
                    return await runScript(.recompile, ProjectTools.wrapT2Script,
                                           diskArguments + ["--name", "\(baseName) (T2-hybrid)"], appendToLog: true)
                }
            }
            var failedStage: BuildStage?
            for stage in t2Stages {
                if let failedStage {
                    set(stage, .skipped("\(failedStage.rawValue) did not pass"))
                } else if await runT2Stage(stage) {
                    set(stage, .passed)
                } else {
                    failedStage = stage
                }
            }
        }

        // Package
        set(.package, .running)
        let report = CompatibilityReport.make(analysis: analysis, stages: stages, profile: profile,
                                              attemptedT2: attemptT2)
        var products: (t1: URL?, t2: URL?) = (nil, nil)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for name in ["analysis.json", "analysis.md"] {
                try copyIfPresent(work.appending(path: name), to: output.appending(path: name))
            }
            if stages[.wrapT1] == .passed {
                products.t1 = output.appending(path: t1App.lastPathComponent)
                try copyIfPresent(t1App, to: products.t1!)
            }
            if stages[.recompile] == .passed {
                products.t2 = output.appending(path: t2App.lastPathComponent)
                try copyIfPresent(t2App, to: products.t2!)
                try copyIfPresent(work.appending(path: "t2build/equivalence/equivalence.md"),
                                  to: output.appending(path: "equivalence.md"))
                try copyIfPresent(work.appending(path: "t2build/fuzz/equivalence/equivalence.md"),
                                  to: output.appending(path: "random-key-equivalence.md"))
            }
            try report.markdown.write(to: output.appending(path: "report.md"), atomically: true, encoding: .utf8)
            set(.package, .passed)
        } catch {
            set(.package, .failed(error.localizedDescription))
        }

        let record = BuildRecord(
            disk: disk.path, disks: disks.count > 1 ? disks.map(\.path) : nil, slug: slug, sha256: sha,
            profile: profile?.name, machine: wrappedMachine, analysis: analysis,
            stages: BuildStage.allCases.map { BuildRecord.Stage(stage: $0, status: stages[$0] ?? .pending) },
            report: report, t1App: products.t1?.path, t2App: products.t2?.path, outputFolder: output.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(record).write(to: output.appending(path: "report.json"), options: .atomic)
        return record
    }

    /// Nil when the T2 stages should run.
    static func reasonToSkipT2(analysis: AnalysisSummary?, t1Passed: Bool, profile: BuildProfile?,
                               attemptT2: Bool) -> String? {
        guard let analysis, analysis.supported else { return "The disk is not supported" }
        guard t1Passed else { return "Wrap (T1) did not pass" }
        guard profile != nil else {
            return "Needs a recorded playthrough and a T2 game profile (see the compatibility report)"
        }
        guard attemptT2 else { return "T2 is available for this disk: choose Try T2 (about 9 minutes)" }
        return nil
    }

    public func run(disk: URL, romDirectory: URL, attemptT2: Bool,
                    onEvent: @escaping @Sendable (BuildEvent) -> Void) async -> BuildRecord {
        await run(disks: [disk], displayName: disk.deletingPathExtension().lastPathComponent, romDirectory: romDirectory,
                  attemptT2: attemptT2, onEvent: onEvent)
    }

    static func machine(in app: URL) -> Machine? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let raw = root["A2NMachine"] as? String else { return nil }
        return Machine(rawValue: raw)
    }

    /// The project's own slug rule (tools/lib/gates.sh disk_slug), so paths match the scripts'.
    private func diskSlug(_ disk: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\" && disk_slug \"$2\"", "slug",
                             project.file(ProjectTools.gatesLibrary).path, disk.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let slug = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !slug.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return slug
    }

    /// A rebuild keeps the previous products: everything but recordings and
    /// older backups moves into previous-<time>/.
    private func setAsidePreviousBuild(in output: URL) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(atPath: output.path) else { return }
        let movable = items.filter { $0 != "recordings" && !$0.hasPrefix("previous-") }
        guard !movable.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let backup = output.appending(path: "previous-\(formatter.string(from: Date()))", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        for item in movable {
            try? fileManager.moveItem(at: output.appending(path: item), to: backup.appending(path: item))
        }
    }

    private func copyIfPresent(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
