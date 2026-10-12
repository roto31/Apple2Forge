import Foundation

/// The apple2-native project folder whose Stage 0–5 scripts the build tool
/// runs. The toolchain (vendor/apple2tc, build/a2emu-norom) and per-disk work
/// folders live there, so the scripts are run in place rather than copied
/// into the app.
public struct ProjectTools: Sendable, Equatable {
    public let root: URL

    public static let setupScript = "tools/00_setup.sh"
    public static let analyzeScript = "tools/10_analyze.sh"
    public static let wrapT1Script = "tools/20_wrap_t1.sh"
    public static let captureScript = "tools/30_capture.sh"
    public static let recordScript = "tools/45_record.sh"
    public static let coverageScript = "tools/40_coverage.sh"
    public static let recompileScript = "tools/50_recompile.sh"
    public static let wrapT2Script = "tools/55_wrap_t2.sh"
    public static let gatesLibrary = "tools/lib/gates.sh"
    public static let profilesFile = "tools/t2/profiles.json"
    /// Info.plist key 60_build_app.sh sets to the project the app was built from.
    public static let infoPlistKey = "A2FProjectRoot"

    private static let requiredFiles = [setupScript, analyzeScript, wrapT1Script, recordScript, gatesLibrary,
                                        profilesFile]

    public init(root: URL) {
        self.root = root
    }

    public func file(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    public var emulator: URL { file("build/a2emu-norom/a2emu") }
    public var romFile: URL { file("roms/apple2plus.rom") }

    public var isComplete: Bool {
        Self.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: file($0).path) }
    }

    /// The pinned apple2tc commit from vendor/apple2tc.COMMIT, if Stage 0 has run.
    public var apple2tcCommit: String? {
        guard let text = try? String(contentsOf: file("vendor/apple2tc.COMMIT"), encoding: .utf8) else { return nil }
        let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    public func workDirectory(slug: String) -> URL {
        file("work").appending(path: slug, directoryHint: .isDirectory)
    }

    /// The chosen folder, else the one recorded in Info.plist, else the
    /// project containing this executable (a development build).
    public static func locate(chosen: URL?, bundle: Bundle = .main) -> ProjectTools? {
        var candidates: [URL] = []
        if let chosen { candidates.append(chosen) }
        if let recorded = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String {
            candidates.append(URL(filePath: recorded, directoryHint: .isDirectory))
        }
        var folder = bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            candidates.append(current)
            folder = current.deletingLastPathComponent()
        }
        return candidates.lazy.map(ProjectTools.init(root:)).first(where: \.isComplete)
    }
}
