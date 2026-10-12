import AppKit
import Apple2ForgeCore
import SwiftUI

struct Apple2ForgeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = LibraryModel()
    @State private var session = EmulatorSession()
    @State private var download = DownloadController()
    @State private var firstRun = FirstRunController()
    /// The Library tab runs the --launch hook when it appears, so it opens first then.
    @State private var tab = AppSettings.shared.launchTitleID == nil ? MainTab.build : .library

    var body: some Scene {
        Window("Apple2Forge", id: "main") {
            TabView(selection: $tab) {
                BuildWindow(queue: .shared, setup: .shared)
                    .tabItem { Text("Build") }
                    .tag(MainTab.build)
                LibraryWindow(library: library, session: session, download: download)
                    .tabItem { Text("Library") }
                    .tag(MainTab.library)
            }
            .sheet(isPresented: $firstRun.showRomInstallSheet) {
                RomInstallProgressView(controller: firstRun)
            }
            .task {
                let state = FirstRunState(defaults: AppSettings.shared.defaults)
                await firstRun.runIfNeeded(state: state, download: download, library: library) {
                    tab = .library
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            LibraryCommands(library: library, session: session, download: download)
            DiskCommands(session: session)
        }
        Settings {
            SettingsView(setup: .shared)
        }
    }
}

enum MainTab: Hashable {
    case build, library
}

/// Disk images dropped on the app icon or opened with the app join the build queue.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { BuildQueue.shared.add(urls) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { BuildQueue.shared.stopAll() }
    }
}

struct LibraryCommands: Commands {
    let library: LibraryModel
    let session: EmulatorSession
    let download: DownloadController

    var body: some Commands {
        CommandMenu("Library") {
            if library.menu.isEmpty {
                Text("No library yet").disabled(true)
            }
            ForEach(library.menu) { subject in
                Menu(subject.subject) {
                    ForEach(subject.titles) { title in
                        Button(title.menuLabel) { session.launch(title, library: library) }
                            .disabled(title.requirement.machine == nil)
                    }
                }
            }
            Divider()
            Button("Download Educational Library…") { download.startDownload(library: library) }
                .disabled(download.isRunning)
            Button("Change Library Location…") { download.changeLocation(library: library) }
                .disabled(download.isRunning)
            Button("Show Library in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.directory])
            }
            Button("Rebuild Catalog") { download.rebuildCatalog(library: library) }
                .disabled(download.isRunning || library.catalog == nil)
        }
    }
}

struct DiskCommands: Commands {
    let session: EmulatorSession
    private static let drives = [1, 2]

    var body: some Commands {
        CommandMenu("Disk") {
            if let title = session.title {
                ForEach(Self.drives, id: \.self) { drive in
                    Menu("Insert into Drive \(drive)") {
                        ForEach(title.sideChoices, id: \.side.path) { choice in
                            Button(choice.label) { session.insert(choice.side, drive: drive) }
                        }
                    }
                }
                Divider()
                ForEach(Self.drives, id: \.self) { drive in
                    Button("Eject Drive \(drive)") { session.eject(drive: drive) }
                        .disabled(session.driveContents[drive] == nil)
                }
            } else {
                Text("Start a title from the Library menu").disabled(true)
            }
        }
    }
}
