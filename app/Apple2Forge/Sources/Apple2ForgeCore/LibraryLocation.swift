import Foundation

/// Where the downloaded library lives: the default folder in Application
/// Support, or one the user picked. Never inside an app bundle, because
/// writing there breaks the bundle's code signature.
public enum LibraryLocation {
    public static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Apple2Forge", directoryHint: .isDirectory)
    }

    public static var defaultDirectory: URL {
        supportDirectory.appending(path: "library", directoryHint: .isDirectory)
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case insideAppBundle(String)
        case notWritable(String)

        public var errorDescription: String? {
            switch self {
            case .insideAppBundle(let path):
                "\(path) is inside an app. Saving the library there would break that app's signature. Choose another folder."
            case .notWritable(let path):
                "Apple2Forge cannot write to \(path). Choose a folder you own."
            }
        }
    }

    public static func isInsideAppBundle(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            .contains { $0.lowercased().hasSuffix(".app") }
    }

    /// Creates the folder if needed and checks it can hold the library.
    public static func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if isInsideAppBundle(url) { throw ValidationError.insideAppBundle(path) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ValidationError.notWritable(path)
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw ValidationError.notWritable(path) }
    }
}

/// Remembers the chosen library folder across launches, as a bookmark so a
/// moved or renamed folder is still found.
public struct LibraryLocationStore: @unchecked Sendable {
    static let bookmarkKey = "libraryFolderBookmark"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var saved: URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
        else { return nil }
        if stale { try? save(url) }
        return url
    }

    /// Validates the folder, then remembers it.
    public func save(_ url: URL) throws {
        try LibraryLocation.validate(url)
        defaults.set(try url.bookmarkData(), forKey: Self.bookmarkKey)
    }
}
