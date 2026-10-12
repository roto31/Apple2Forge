import Apple2ForgeCore
import Foundation

/// Settings shared by the command-line modes and the UI.
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    /// A disk change the app makes on its own, for the app gate (--swap-after).
    struct ScheduledSwap {
        let delaySeconds: Double
        let drive: Int
        let sidePath: String
    }

    static let projectFolderKey = "projectFolder"
    static let setupCheckPassedKey = "setupCheckPassed"

    private(set) var defaults = UserDefaults.standard
    private(set) var locationStore = LibraryLocationStore()
    private var libraryOverride: URL?
    private(set) var launchTitleID: String?
    private(set) var scheduledSwap: ScheduledSwap?
    private var projectOverride: URL?
    private var buildsOverride: URL?
    /// Disk images to queue at launch, as a drop on the window does (--drop).
    private(set) var dropPaths: [String] = []
    private(set) var buildT2OnDrop = false
    /// Quit this many seconds after the queue empties (--quit-after-build).
    private(set) var quitAfterBuildSeconds: Double?
    private(set) var skipFirstRun = false

    var skipAutomationHooks: Bool {
        launchTitleID != nil || !dropPaths.isEmpty
    }

    func configureFirstRun(skip: Bool) {
        skipFirstRun = skip
    }

    func configure(suite: String?, libraryOverride: String?, launchTitleID: String? = nil,
                   swapAfter: String? = nil) {
        if let suite, let defaults = UserDefaults(suiteName: suite) {
            self.defaults = defaults
            locationStore = LibraryLocationStore(defaults: defaults)
        }
        self.libraryOverride = libraryOverride.map { URL(filePath: $0, directoryHint: .isDirectory) }
        self.launchTitleID = launchTitleID
        // SECONDS:DRIVE:PATH, the path relative to the library's disks folder.
        if let parts = swapAfter?.split(separator: ":", maxSplits: 2).map(String.init), parts.count == 3,
           let delay = Double(parts[0]), let drive = Int(parts[1]) {
            scheduledSwap = ScheduledSwap(delaySeconds: delay, drive: drive, sidePath: parts[2])
        }
    }

    /// --library, else the remembered folder, else the default one.
    var libraryDirectory: URL {
        libraryOverride ?? locationStore.saved ?? LibraryLocation.defaultDirectory
    }

    var emulatorOptions: EmulatorOptions {
        EmulatorOptions.saved(in: defaults)
    }

    var hasChosenLocation: Bool {
        libraryOverride != nil || locationStore.saved != nil
    }

    /// Installed by tools/05_fetch_rom.sh --install; never inside the app.
    var romDirectory: URL {
        LibraryLocation.supportDirectory.appending(path: "roms", directoryHint: .isDirectory)
    }

    var logDirectory: URL {
        URL.libraryDirectory.appending(path: "Logs/Apple2Forge", directoryHint: .isDirectory)
    }

    func configureBuildTool(project: String?, buildsDirectory: String?, drops: [String], t2: Bool,
                            quitAfterBuild: String?) {
        projectOverride = project.map { URL(filePath: $0, directoryHint: .isDirectory) }
        buildsOverride = buildsDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) }
        dropPaths = drops
        buildT2OnDrop = t2
        quitAfterBuildSeconds = quitAfterBuild.flatMap(Double.init)
    }

    /// The apple2-native project whose scripts the build tool runs.
    var project: ProjectTools? {
        ProjectTools.locate(chosen: projectOverride ?? defaults.url(forKey: Self.projectFolderKey))
    }

    /// Remembers FOLDER if it holds the project's scripts.
    func saveProjectFolder(_ folder: URL) -> Bool {
        guard ProjectTools(root: folder).isComplete else { return false }
        defaults.set(folder, forKey: Self.projectFolderKey)
        return true
    }

    var buildsDirectory: URL {
        buildsOverride ?? BuildPipeline.defaultBuildsRoot
    }
}
