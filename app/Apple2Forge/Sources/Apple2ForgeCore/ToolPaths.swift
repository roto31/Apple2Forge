import Foundation

/// Where the app finds a2emu and the Stage 6a scripts. Inside Apple2Forge.app
/// they are copied to Contents/Resources (laid out like the repo: tools/,
/// library/); a development build run from the repo uses the repo itself.
public struct ToolPaths: Sendable, Equatable {
    /// Folder holding tools/ and library/.
    public let root: URL
    public let emulator: URL

    public static let fetchScript = "tools/07_fetch_edu_library.sh"
    public static let catalogScript = "tools/50_library.sh"
    public static let sweepScript = "tools/55_compat_sweep.sh"

    public init(root: URL, emulator: URL) {
        self.root = root
        self.emulator = emulator
    }

    public func script(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    /// The bundle's Resources when running as Apple2Forge.app, else the repo
    /// that contains this executable (app/Apple2Forge/.build/<config>/Apple2Forge).
    public static func locate(bundle: Bundle = .main) -> ToolPaths? {
        if bundle.bundleURL.pathExtension == "app", let resources = bundle.resourceURL {
            let paths = ToolPaths(root: resources, emulator: resources.appending(path: "a2emu"))
            return paths.isComplete ? paths : nil
        }
        var folder = bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            let paths = ToolPaths(root: current, emulator: current.appending(path: "build/a2emu-norom/a2emu"))
            if paths.isComplete { return paths }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }

    public var isComplete: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: emulator.path)
            && [Self.fetchScript, Self.catalogScript, Self.sweepScript]
                .allSatisfy { fileManager.fileExists(atPath: script($0).path) }
    }
}
