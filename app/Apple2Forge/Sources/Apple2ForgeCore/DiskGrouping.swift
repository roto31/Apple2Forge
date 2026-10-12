import Foundation

/// One title to build from dropped disk images (may be several sides).
public struct DiskBuildGroup: Codable, Sendable, Equatable {
    public let title: String
    public let paths: [String]
    public let sideCount: Int

    public var diskURLs: [URL] { paths.map { URL(filePath: $0) } }
}

public enum DiskGroupingError: Error, LocalizedError {
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let detail): detail
        }
    }
}

/// Groups disk paths the same way the library catalog does (tools/lib/t1_disk_set.py).
public enum DiskGrouping {
    private static let helper = "tools/lib/t1_disk_set.py"

    public static func groups(for urls: [URL], project: ProjectTools) throws -> [DiskBuildGroup] {
        guard !urls.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        var args: [String] = ["-I", project.file(helper).path, "--group"]
        args.append(contentsOf: urls.map(\.path))
        process.arguments = args
        process.currentDirectoryURL = project.root
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DiskGroupingError.scriptFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let decoder = JSONDecoder()
        return try decoder.decode([DiskBuildGroup].self, from: Data(stdout.utf8))
    }

    /// One group per disk when the helper cannot run.
    public static func fallbackSingleGroups(_ urls: [URL]) -> [DiskBuildGroup] {
        urls.map { url in
            DiskBuildGroup(title: url.deletingPathExtension().lastPathComponent, paths: [url.path], sideCount: 1)
        }
    }
}
