import Foundation

/// Remembers whether the first-launch setup flow has finished.
public struct FirstRunState: @unchecked Sendable {
    public static let completedKey = "firstRunCompleted"
    public static let libraryDeclinedKey = "libraryDownloadDeclined"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isCompleted: Bool { defaults.bool(forKey: Self.completedKey) }
    public var libraryDownloadDeclined: Bool { defaults.bool(forKey: Self.libraryDeclinedKey) }

    public func markCompleted() {
        defaults.set(true, forKey: Self.completedKey)
    }

    public func markLibraryDeclined() {
        defaults.set(true, forKey: Self.libraryDeclinedKey)
    }

    public func clearLibraryDeclined() {
        defaults.removeObject(forKey: Self.libraryDeclinedKey)
    }

    public static func needsRomStep(romDirectory: URL) -> Bool {
        !RomCatalog.missingSlots(in: romDirectory).isEmpty
    }

    public func shouldRun(skipExplicit: Bool, skipForAutomation: Bool) -> Bool {
        !skipExplicit && !skipForAutomation && !isCompleted
    }
}
