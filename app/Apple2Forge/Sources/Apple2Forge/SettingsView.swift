import AppKit
import Apple2ForgeCore
import SwiftUI

/// Project (work) folder, ROM, builds folder, apple2tc commit, setup check.
struct SettingsView: View {
    let setup: SetupModel
    @State private var project = AppSettings.shared.project
    @State private var folderError: String?

    var body: some View {
        Form {
            Section("Project folder") {
                LabeledContent("apple2-native", value: project?.root.path ?? "Not found")
                Text("The build stages run this folder's scripts. Its work folder holds each disk's intermediate files.")
                    .font(.callout).foregroundStyle(.secondary)
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
            Section("Apple II ROM") {
                Text("Apple2Forge never includes a ROM. Builds use the one you supply: roms/apple2plus.rom in the project; T1 apps use the one in Application Support.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(setup.fileItems.filter { $0.name.hasPrefix("Apple II+ ROM") }) { item in
                    LabeledContent(item.name, value: item.passed ? "\(item.detail) (12288 bytes)" : item.detail)
                }
                Button("Show ROM Folder") { reveal(AppSettings.shared.romDirectory) }
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

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
