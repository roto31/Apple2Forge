import AppKit
import Apple2ForgeCore
import Observation
import SwiftUI

/// First launch: offer automatic ROM install or a file picker, then offer the
/// educational library download to the default folder.
@MainActor
@Observable
final class FirstRunController {
    var showRomInstallSheet = false
    private(set) var romInstallLines: [String] = []

    private var isRunningFlow = false

    func runIfNeeded(
        state: FirstRunState,
        download: DownloadController,
        library: LibraryModel,
        selectLibraryTab: @escaping () -> Void
    ) async {
        let settings = AppSettings.shared
        guard state.shouldRun(skipExplicit: settings.skipFirstRun, skipForAutomation: settings.skipAutomationHooks) else {
            return
        }
        guard !isRunningFlow else { return }
        isRunningFlow = true
        defer {
            isRunningFlow = false
            state.markCompleted()
        }

        library.reload()
        if FirstRunState.needsRomStep(romDirectory: settings.romDirectory) {
            await runRomStep(settings: settings)
        }

        library.reload()
        guard library.catalog == nil else { return }

        if askLibraryDownload() {
            selectLibraryTab()
            _ = download.startDownload(library: library, to: LibraryLocation.defaultDirectory)
        } else {
            state.markLibraryDeclined()
            selectLibraryTab()
        }
    }

    // MARK: - ROMs

    private func runRomStep(settings: AppSettings) async {
        switch askAutomaticRomInstall() {
        case .automatic:
            await installRomsAutomatically(settings: settings)
        case .manual:
            await installRomsFromPicker(settings: settings)
        case .skipped:
            break
        }
    }

    private enum RomChoice {
        case automatic, manual, skipped
    }

    private func askAutomaticRomInstall() -> RomChoice {
        let alert = NSAlert()
        alert.messageText = "Install the ROMs Apple2Forge needs?"
        alert.informativeText = """
        Apple2Forge needs Apple ][+ and enhanced Apple //e ROM files to run software. \
        You can download chip images from the Apple II Documentation Project mirror and install them automatically.

        Use these ROMs only if you are entitled to, for example because you own the machine.
        """
        alert.addButton(withTitle: "Download and Install")
        alert.addButton(withTitle: "Choose My Own Files…")
        alert.addButton(withTitle: "Skip for Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .automatic
        case .alertSecondButtonReturn: return .manual
        default: return .skipped
        }
    }

    private func installRomsAutomatically(settings: AppSettings) async {
        guard pythonIsAvailable() else {
            showRomFailure("python3 is missing. Install the Xcode command-line tools (xcode-select --install), then try again.")
            return
        }
        guard let tools = ToolPaths.locate(),
              FileManager.default.fileExists(atPath: tools.script(ToolPaths.romScript).path)
        else {
            showRomFailure("The ROM download script is missing. Rebuild Apple2Forge.app, or choose ROM files manually.")
            return
        }
        let workDirectory = romWorkDirectory()
        let log = settings.logDirectory.appending(path: "rom-install.log")
        romInstallLines = []
        showRomInstallSheet = true
        defer { showRomInstallSheet = false }
        do {
            try await RomInstaller.installAutomatically(
                tools: tools,
                romDirectory: settings.romDirectory,
                workDirectory: workDirectory,
                log: log
            ) { line in
                Task { @MainActor in
                    self.romInstallLines.append(line)
                    if self.romInstallLines.count > 80 {
                        self.romInstallLines.removeFirst(self.romInstallLines.count - 80)
                    }
                }
            }
        } catch {
            showRomFailure(error.localizedDescription)
        }
    }

    private func showRomFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not install ROMs automatically"
        alert.informativeText = message
        alert.addButton(withTitle: "Choose ROM Files…")
        alert.addButton(withTitle: "Skip for Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await installRomsFromPicker(settings: AppSettings.shared) }
        default:
            break
        }
    }

    private func installRomsFromPicker(settings: AppSettings) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose Apple II ROM files"
        panel.prompt = "Install"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let summary = RomInstaller.installPicked(panel.urls, into: settings.romDirectory)
        let installed = summary.results.compactMap { result -> String? in
            guard case .success(let slot) = result.outcome else { return nil }
            return slot.displayName
        }
        let failures = summary.results.compactMap { result -> String? in
            guard case .failure(let error) = result.outcome else { return nil }
            return "\(result.url.lastPathComponent): \(error.localizedDescription)"
        }
        var text = ""
        if !installed.isEmpty {
            text += "Installed: \(installed.joined(separator: ", ")).\n"
        }
        if !failures.isEmpty {
            text += failures.joined(separator: "\n")
            if !text.isEmpty { text += "\n" }
        }
        if !summary.missingSlots.isEmpty {
            text += "Still missing: \(summary.missingSlots.map(\.displayName).joined(separator: ", ")). "
            text += "Add them later in Settings ▸ Machine."
        }
        guard !text.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "ROM installation"
        alert.informativeText = text
        alert.runModal()
    }

    private func askLibraryDownload() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the educational library?"
        alert.informativeText = """
        Would you like to download the educational games and applications to the default location? \
        About 330 MB of disk images will be saved in your Application Support folder.
        """
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func romWorkDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appending(path: "Apple2Forge/rom-fetch", directoryHint: .isDirectory)
    }

    private func pythonIsAvailable() -> Bool {
        let check = Process()
        check.executableURL = URL(filePath: "/usr/bin/xcode-select")
        check.arguments = ["-p"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
    }
}

struct RomInstallProgressView: View {
    let controller: FirstRunController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installing ROMs…").font(.headline)
            ProgressView()
            if !controller.romInstallLines.isEmpty {
                ScrollView {
                    Text(controller.romInstallLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
