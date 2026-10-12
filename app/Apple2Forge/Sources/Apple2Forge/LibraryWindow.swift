import Apple2ForgeCore
import SwiftUI

/// The main window: where the library is, what is running, and download progress.
struct LibraryWindow: View {
    let library: LibraryModel
    let session: EmulatorSession
    let download: DownloadController
    @AppStorage(FirstRunState.libraryDeclinedKey, store: AppSettings.shared.defaults)
    private var libraryDownloadDeclined = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if libraryDownloadDeclined && library.catalog == nil {
                libraryDeclinedBanner
            }
            libraryStatus
            Divider()
            runningStatus
            if download.state != .idle {
                Divider()
                DownloadStatusView(download: download)
            }
            Spacer(minLength: 0)
            Text("Use only disks you are entitled to use. Builds are for personal use.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .frame(minHeight: 260)
        .task { await runStartupHooks() }
    }

    private func runStartupHooks() async {
        let settings = AppSettings.shared
        guard let titleID = settings.launchTitleID else { return }
        guard let title = library.catalog?.titles.first(where: { $0.id == titleID }) else {
            session.lastError = "No title with id \(titleID) in the library."
            return
        }
        session.launch(title, library: library)
        guard let swap = settings.scheduledSwap,
              let side = title.sideChoices.first(where: { $0.side.path == swap.sidePath })?.side
        else { return }
        try? await Task.sleep(for: .seconds(swap.delaySeconds))
        session.insert(side, drive: swap.drive)
    }

    private var libraryDeclinedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Educational library not downloaded", systemImage: "info.circle")
                .font(.headline)
            Text("You can download the games and applications later from Library ▸ Download Educational Library…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Download Now…") {
                _ = download.startDownload(library: library, to: LibraryLocation.defaultDirectory)
            }
            .disabled(download.isRunning)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var libraryStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Educational Library").font(.headline)
            LabeledContent("Location", value: library.directory.path)
            if let catalog = library.catalog {
                LabeledContent("Titles", value: "\(library.visibleTitleCount) in \(library.menu.count) subjects")
                LabeledContent("Data revision", value: catalog.dataRevision)
                Text("Choose a title from the Library menu to start it.")
                    .foregroundStyle(.secondary)
            } else {
                Text(library.loadError ?? "No library yet.")
                    .foregroundStyle(.secondary)
                Button("Download Educational Library…") { download.startDownload(library: library) }
                    .disabled(download.isRunning)
            }
        }
    }

    @ViewBuilder
    private var runningStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = session.title, let machine = session.machine {
                Text("Running: \(title.title)").font(.headline)
                LabeledContent("Machine", value: machine.displayName)
                ForEach(session.driveContents.keys.sorted(), id: \.self) { drive in
                    LabeledContent("Drive \(drive)", value: session.driveContents[drive] ?? "")
                }
                Text("Change disks with the Disk menu.").foregroundStyle(.secondary)
            } else {
                Text("Nothing running").font(.headline)
            }
            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

struct DownloadStatusView: View {
    let download: DownloadController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch download.state {
            case .idle:
                EmptyView()
            case .running(let step):
                Text(step.rawValue).font(.headline)
                if step == .download {
                    ProgressView(value: download.progress.fraction) {
                        Text(progressText)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { download.cancel() }
            case .finished:
                Label("Library ready", systemImage: "checkmark.circle").font(.headline)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(download.notes, id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if !download.log.isEmpty {
                ScrollView {
                    Text(download.log.suffix(60).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
            }
        }
    }

    private var progressText: String {
        let progress = download.progress
        let megabytes = ByteCountFormatter.string(fromByteCount: progress.doneBytes, countStyle: .file)
        var text = "\(progress.doneFiles) of \(progress.totalFiles) files, \(megabytes)"
        if let eta = progress.etaSeconds {
            text += ", about \(Duration.seconds(eta).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) left"
        }
        return text
    }
}
