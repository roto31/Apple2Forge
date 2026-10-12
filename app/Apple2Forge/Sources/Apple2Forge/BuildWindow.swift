import AppKit
import Apple2ForgeCore
import SwiftUI

/// The Build tab: drop disk images, watch each pipeline, read its report.
struct BuildWindow: View {
    let queue: BuildQueue
    let setup: SetupModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            ForEach(queue.rejections, id: \.self) { message in
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if !queue.rejections.isEmpty {
                Button("Dismiss") { queue.dismissRejections() }
            }
            if !setup.hasPassed || setup.isRunning {
                SetupChecklistView(setup: setup)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(queue.items) { item in
                        PipelineCard(item: item, queue: queue)
                    }
                }
            }
            HStack {
                Text("Use only disks you are entitled to use. Builds are for personal use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if queue.items.contains(where: { $0.state == .finished }) {
                    Button("Clear Finished") { queue.removeFinished() }
                }
            }
        }
        .padding(20)
        .frame(width: 680, alignment: .leading)
        .frame(minHeight: 560)
        .task { startupHooks() }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "opticaldiscdrive").font(.largeTitle)
            Text("Drop .dsk, .do, .po or .nib disk images here")
                .font(.headline)
            Text("Each disk is analyzed and wrapped as a T1 app automatically.")
                .foregroundStyle(.secondary)
            Button("Choose Disk Images…", action: chooseDisks)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8])))
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func chooseDisks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        queue.add(panel.urls)
    }

    private func startupHooks() {
        setup.runIfFirstLaunch()
        let settings = AppSettings.shared
        if let seconds = settings.quitAfterBuildSeconds {
            queue.onQueueEmpty = {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
            }
        }
        if !settings.dropPaths.isEmpty {
            queue.add(settings.dropPaths.map { URL(filePath: $0) }, attemptT2: settings.buildT2OnDrop)
        }
    }
}

struct PipelineCard: View {
    let item: BuildItem
    let queue: BuildQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(BuildStage.allCases, id: \.self) { stage in
                    stageRow(stage)
                }
            }
            if item.state == .running, !item.logTail.isEmpty {
                Text(item.logTail.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            if let report = item.record?.report {
                ReportView(report: report)
                actions
            }
            if let message = item.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
            ForEach(item.recordings) { recording in
                HStack {
                    Text("Recording \(recording.name): \(recording.summary)").font(.callout)
                    Spacer()
                    Button("Report") { queue.open(recording.folder.appending(path: "record.md")) }
                    Button("Replay") { queue.replay(item, recording) }
                        .disabled(item.isRecording)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var header: some View {
        HStack {
            Text(item.name).font(.headline)
            if item.attemptT2 { Text("with T2").foregroundStyle(.secondary) }
            Spacer()
            switch item.state {
            case .waiting:
                Text("Waiting").foregroundStyle(.secondary)
                Button("Remove") { queue.cancel(item) }
            case .running:
                ProgressView().controlSize(.small)
                Button("Cancel") { queue.cancel(item) }
            case .finished:
                if let folder = item.outputFolder {
                    Button("Show in Finder") { queue.reveal(folder) }
                }
            }
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: BuildStage) -> some View {
        let status = item.stages[stage] ?? .pending
        GridRow {
            Text(stage.rawValue)
            Text(status.label)
                .font(.system(.body, design: .monospaced).bold())
                .foregroundStyle(color(status))
            Text(status.detail ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let log = item.logURL(stage) {
                Button("Show Log") { queue.open(log) }.controlSize(.small)
            } else {
                Text("")
            }
        }
    }

    private func color(_ status: StageStatus) -> Color {
        switch status {
        case .passed: .green
        case .failed: .red
        case .running: .blue
        case .pending, .skipped: .secondary
        }
    }

    private var actions: some View {
        HStack {
            if let path = item.record?.t1App {
                Button("Export T1 App…") { queue.export(URL(filePath: path), item: item) }
            }
            if let path = item.record?.t2App {
                Button("Export T2-hybrid App…") { queue.export(URL(filePath: path), item: item) }
            }
            if item.record?.profile != nil, item.record?.t2App == nil, !item.attemptT2 {
                Button("Try T2") { queue.tryT2(item) }
            }
            if item.record?.analysis?.supported == true {
                Button("Record Coverage…") { queue.record(item) }
                    .disabled(item.isRecording)
            }
            if let folder = item.outputFolder {
                Button("Report") { queue.open(folder.appending(path: "report.md")) }
            }
        }
    }
}

struct ReportView: View {
    let report: CompatibilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compatibility: tier \(report.tier.rawValue)").font(.headline)
            Text(report.headline).foregroundStyle(.secondary)
            Text("T2 possible: \(report.t2Possible)")
            if !report.reasons.isEmpty {
                Text("Why not higher").bold()
                ForEach(report.reasons, id: \.self) { Text("• \($0)") }
            }
            Text("Next steps").bold()
            ForEach(report.nextSteps, id: \.self) { Text("• \($0)") }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

/// The Stage 0 gates and build files, each PASS or FAIL.
struct SetupChecklistView: View {
    let setup: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Setup check").font(.headline)
                if setup.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running Stage 0…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Again") { setup.run() }.disabled(setup.isRunning)
                Button("Show Log") { NSWorkspace.shared.open(setup.logURL) }
                    .disabled(setup.exitStatus == nil)
            }
            ForEach(setup.items) { item in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(item.passed ? .green : .red)
                    Text(item.name)
                    Text(item.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
            }
        }
    }
}
