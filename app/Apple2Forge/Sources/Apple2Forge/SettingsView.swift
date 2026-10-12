import AppKit
import Apple2ForgeCore
import SwiftUI

/// Apple2Forge ▸ Settings…: one tab each for the picture, sound, machine,
/// floating buttons, and the Build tab's project setup. The game options are
/// read when a title starts.
struct SettingsView: View {
    let setup: SetupModel

    var body: some View {
        TabView {
            PictureSettings()
                .tabItem { Label("Picture", systemImage: "tv") }
            SoundSettings()
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            MachineSettings()
                .tabItem { Label("Machine", systemImage: "cpu") }
            ControlsSettings()
                .tabItem { Label("Controls", systemImage: "hand.point.up.left") }
            BuildSettings(setup: setup)
                .tabItem { Label("Build", systemImage: "hammer") }
        }
    }
}

private var store: UserDefaults { AppSettings.shared.defaults }

/// A grey explanation under a setting.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PictureSettings: View {
    @AppStorage(DisplayStyle.defaultsKey, store: store) private var display = DisplayStyle.smooth

    var body: some View {
        Form {
            Picker("Picture style", selection: $display) {
                ForEach(DisplayStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Note("Smooth draws sharp pixels and solid colours. Classic shows the softer picture and colour fringes of an Apple II on a colour monitor. Both run the program the same way.")
            Note("Applies the next time a title starts. While playing, F3 or the picture button over the game tries the other colour modes.")
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize()
    }
}

private struct SoundSettings: View {
    @AppStorage(EmulatorOptions.soundKey, store: store) private var sound = true

    var body: some View {
        Form {
            Toggle("Play sound", isOn: $sound)
            Note("The Apple II's speaker. While playing, the speaker button over the game turns it off and on.")
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize()
    }
}

private struct MachineSettings: View {
    @AppStorage(EmulatorOptions.fastKey, store: store) private var fast = false
    @AppStorage(EmulatorOptions.joystickKey, store: store) private var joystick = false

    var body: some View {
        Form {
            Section {
                ForEach(RomSlot.allCases) { RomRow(slot: $0) }
                Button("Show ROM Folder") { reveal(AppSettings.shared.romDirectory) }
            } header: {
                Text("ROMs")
            } footer: {
                Note("Apple2Forge never includes Apple's ROMs. Choose your own copy of each file: it is checked, then copied into the ROM folder. A file it replaces is kept in a backup folder there.")
            }
            Section("Play") {
                Picker("Speed", selection: $fast) {
                    Text("Normal").tag(false)
                    Text("Fast (5×)").tag(true)
                }
                Note("Fast makes disks load quicker, but games and sound run fast too.")
                Toggle("Start in joystick mode", isOn: $joystick)
                Note("The arrow keys move the joystick and Space, Left Option and Left Control are its buttons. F7 or the joystick button over the game switches it while playing.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 620)
    }
}

/// One ROM file: what it must be, whether it is installed, and how to change it.
private struct RomRow: View {
    let slot: RomSlot
    @State private var status = RomStatus.missing
    @State private var hasBackup = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slot.displayName)
                Spacer()
                Button("Choose…", action: choose)
                if hasBackup {
                    Button("Restore Previous", action: restore)
                }
            }
            Text(statusText).font(.callout).foregroundStyle(statusColor)
            Note("Needs a \(slot.requirement).")
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
        .onAppear(perform: refresh)
    }

    private var statusText: String {
        switch status {
        case .missing: "Not installed"
        case .installed(let chip?): "Installed: matches \(chip)"
        case .installed(nil): "Installed"
        case .invalid(let reason): "Not usable: \(reason)"
        }
    }

    private var statusColor: Color {
        switch status {
        case .installed: .green
        case .missing: .secondary
        case .invalid: .red
        }
    }

    private func refresh() {
        let folder = AppSettings.shared.romDirectory
        status = RomCatalog.status(of: slot, in: folder)
        hasBackup = RomCatalog.latestBackup(of: slot, in: folder) != nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(slot.displayName): a \(slot.requirement)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try RomCatalog.install(file, as: slot, into: AppSettings.shared.romDirectory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func restore() {
        do {
            try RomCatalog.restoreLatestBackup(of: slot, in: AppSettings.shared.romDirectory)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

private struct ControlsSettings: View {
    @AppStorage(ControlsMode.defaultsKey, store: store) private var controls = ControlsMode.fade

    var body: some View {
        Form {
            Picker("Floating buttons", selection: $controls) {
                ForEach(ControlsMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Note("A row of buttons over the game: restart, joystick mode, picture mode, sound and full screen. With the first choice they appear when you move the mouse over the game and fade away after a moment. The keys and the Disk menu work either way.")
            Note("Applies the next time a title starts.")
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize()
    }
}

/// Project (work) folder, the ROM builds use, builds folder, apple2tc commit, setup check.
private struct BuildSettings: View {
    let setup: SetupModel
    @State private var project = AppSettings.shared.project
    @State private var folderError: String?

    var body: some View {
        Form {
            Section("Project folder") {
                LabeledContent("apple2-native", value: project?.root.path ?? "Not found")
                Note("The build stages run this folder's scripts. Its work folder holds each disk's intermediate files.")
                HStack {
                    Button("Choose…", action: chooseProject)
                    if let project {
                        Button("Show Work Folder") { reveal(project.file("work")) }
                    }
                }
                if let folderError {
                    Text(folderError).foregroundStyle(.red)
                }
                LabeledContent("apple2tc commit", value: project?.apple2tcCommit ?? "Not set up (run the setup check)")
            }
            Section("Apple II ROM for builds") {
                Note("Builds use roms/apple2plus.rom in the project folder. T1 apps use the Apple ][+ ROM from the Machine tab.")
                ForEach(setup.fileItems.filter { $0.name.hasPrefix("Apple II+ ROM") }) { item in
                    LabeledContent(item.name, value: item.passed ? "\(item.detail) (12288 bytes)" : item.detail)
                }
            }
            Section("Builds") {
                LabeledContent("Output", value: AppSettings.shared.buildsDirectory.path)
                Button("Show Builds Folder") { reveal(AppSettings.shared.buildsDirectory) }
            }
            Section("Setup check") {
                SetupChecklistView(setup: setup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
        .onAppear { setup.refreshFiles() }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose the apple2-native project folder (it contains tools/00_setup.sh)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if AppSettings.shared.saveProjectFolder(folder) {
            folderError = nil
            project = AppSettings.shared.project
            setup.refreshFiles()
        } else {
            folderError = "\(folder.path) does not contain the project's tools folder."
        }
    }
}

private func reveal(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([folder])
}
