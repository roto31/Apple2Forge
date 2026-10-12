import Foundation

/// Runs one project script with bash in the project folder, appending every
/// output line to a log file and handing it on as it arrives.
public final class ScriptRunner: @unchecked Sendable {
    /// Apps opened from Finder get a minimal PATH; the scripts need Homebrew's
    /// python3 (3.10+) and cmake ahead of the system ones.
    static let extraPath = ["/opt/homebrew/bin", "/usr/local/bin"]

    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Returns the script's exit status. Throws only if it could not start.
    public func run(_ script: URL, arguments: [String], in folder: URL, log: URL, appendToLog: Bool = false,
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !appendToLog || !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: log)
        try logHandle.seekToEnd()
        defer { try? logHandle.close() }
        let logLock = NSLock()
        let lines = LineSplitter { line in
            logLock.withLock { logHandle.write(Data((line + "\n").utf8)) }
            onLine(line)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = folder
        process.environment = Self.environment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { lines.append($0.availableData) }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    if cancelled { throw CocoaError(.userCancelled) }
                    try process.run()
                    current = process
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        lines.append(output.fileHandleForReading.readDataToEndOfFile())
        lines.flush()
        lock.withLock { current = nil }
        return status
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPath + [path]).joined(separator: ":")
        return environment
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            if let current, current.isRunning { Self.terminateTree(current.processIdentifier) }
        }
    }

    /// Signals PID's descendants before PID: bash waits for its running child
    /// before acting on a signal, so signalling the script alone would leave
    /// a long stage (coverage, recompile) running after a cancel or quit.
    static func terminateTree(_ pid: pid_t) {
        for child in childPIDs(of: pid) { terminateTree(child) }
        kill(pid, SIGTERM)
    }

    static func childPIDs(of pid: pid_t) -> [pid_t] {
        let estimate = proc_listchildpids(pid, nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) * 2)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }
}
