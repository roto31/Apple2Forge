import Foundation

public enum PipelineStep: String, Sendable, CaseIterable {
    case download = "Downloading disk images"
    case catalog = "Building the catalog"
    case sweep = "Checking which machine each title needs"
}

public struct DownloadProgress: Sendable, Equatable {
    public var doneFiles = 0
    public var totalFiles = 0
    public var doneBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var etaSeconds: Int?

    public init() {}

    public var fraction: Double {
        totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0
    }
}

public enum PipelineEvent: Sendable, Equatable {
    case started(PipelineStep)
    case progress(DownloadProgress)
    case skipped(PipelineStep, reason: String)
    case log(String)
}

public enum PipelineError: Error, LocalizedError, Equatable {
    case stepFailed(PipelineStep, status: Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .stepFailed(let step, let status):
            "\(step.rawValue) failed (exit \(status)). The log in ~/Library/Logs/Apple2Forge has the details."
        case .cancelled:
            "The download was cancelled. Starting it again resumes where it stopped."
        }
    }
}

/// Download → catalog → compatibility sweep, by running the bundled scripts.
/// No download, grouping or sweep logic lives in Swift.
public final class DownloadPipeline: @unchecked Sendable {
    private let tools: ToolPaths
    private let library: URL
    private let romDirectory: URL
    private let limit: Int?
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init(tools: ToolPaths, library: URL, romDirectory: URL, limit: Int? = nil) {
        self.tools = tools
        self.library = library
        self.romDirectory = romDirectory
        self.limit = limit
    }

    public func run(onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        var fetchArguments = ["--dest=\(library.path)", "--progress=json"]
        if let limit { fetchArguments.append("--limit=\(limit)") }
        try await runStep(.download, script: ToolPaths.fetchScript, arguments: fetchArguments, onEvent: onEvent)
        try await runStep(.catalog, script: ToolPaths.catalogScript, arguments: ["--library=\(library.path)"],
                          onEvent: onEvent)
        let missingRoms = (Machine.iiPlus.romFiles + Machine.iie.romFiles).filter {
            !FileManager.default.fileExists(atPath: romDirectory.appending(path: $0).path)
        }
        if missingRoms.isEmpty {
            try await runStep(.sweep, script: ToolPaths.sweepScript,
                              arguments: ["--library=\(library.path)", "--emulator=\(tools.emulator.path)",
                                          "--rom-dir=\(romDirectory.path)"],
                              onEvent: onEvent)
        } else {
            onEvent(.skipped(.sweep, reason: "ROMs not installed: \(missingRoms.joined(separator: ", ")). Titles use the machine their file names suggest."))
        }
    }

    public func runCatalogOnly(onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        try await runStep(.catalog, script: ToolPaths.catalogScript, arguments: ["--library=\(library.path)"],
                          onEvent: onEvent)
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            current?.interrupt()
        }
    }

    private func runStep(_ step: PipelineStep, script: String, arguments: [String],
                         onEvent: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        onEvent(.started(step))
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [tools.script(script).path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let jsonLines = LineSplitter { line in
            if let progress = DownloadPipeline.progress(fromJSONLine: line) {
                onEvent(.progress(progress))
            } else {
                onEvent(.log(line))
            }
        }
        let textLines = LineSplitter { onEvent(.log($0)) }
        output.fileHandleForReading.readabilityHandler = { jsonLines.append($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { textLines.append($0.availableData) }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try lock.withLock {
                    if cancelled { throw PipelineError.cancelled }
                    try process.run()
                    current = process
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        jsonLines.append(output.fileHandleForReading.readDataToEndOfFile())
        textLines.append(errors.fileHandleForReading.readDataToEndOfFile())
        jsonLines.flush()
        textLines.flush()
        let wasCancelled = lock.withLock {
            current = nil
            return cancelled
        }
        if wasCancelled { throw PipelineError.cancelled }
        guard status == 0 else { throw PipelineError.stepFailed(step, status: status) }
    }

    /// A "file" or "listed" event from 07_fetch_edu_library.sh --progress=json.
    public static func progress(fromJSONLine line: String) -> DownloadProgress? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = record["event"] as? String, event == "file" || event == "listed"
        else { return nil }
        var progress = DownloadProgress()
        progress.totalFiles = record["total_files"] as? Int ?? 0
        progress.totalBytes = (record["total_bytes"] as? NSNumber)?.int64Value ?? 0
        progress.doneFiles = record["done_files"] as? Int ?? 0
        progress.doneBytes = (record["done_bytes"] as? NSNumber)?.int64Value ?? 0
        progress.etaSeconds = record["eta_seconds"] as? Int
        return progress
    }
}

/// Collects pipe output and hands it on one complete line at a time.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var complete: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return complete
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest: String? = lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
        if let rest { onLine(rest) }
    }
}
