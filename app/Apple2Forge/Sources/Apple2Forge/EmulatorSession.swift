import Apple2ForgeCore
import Foundation
import Observation

/// The running a2emu, if any. One title runs at a time; starting another
/// closes the first. Disk swaps go to a2emu over its standard input.
@MainActor
@Observable
final class EmulatorSession {
    private(set) var title: LibraryTitle?
    private(set) var machine: Machine?
    private(set) var driveContents: [Int: String] = [:]
    var lastError: String?

    private var process: Process?
    private var control: FileHandle?
    private var libraryDirectory: URL?

    func launch(_ title: LibraryTitle, library: LibraryModel) {
        lastError = nil
        guard let tools = ToolPaths.locate() else {
            lastError = "The bundled emulator is missing. Rebuild Apple2Forge.app (tools/60_build_app.sh)."
            return
        }
        let launch: EmulatorLaunch
        do {
            launch = try EmulatorLaunch(title: title, libraryDirectory: library.directory,
                                        romDirectory: AppSettings.shared.romDirectory)
        } catch {
            lastError = error.localizedDescription
            return
        }
        stop()
        do {
            let process = Process()
            process.executableURL = try windowTitleLink(named: launch.windowTitle, to: tools.emulator)
            process.arguments = launch.arguments
            let control = Pipe()
            process.standardInput = control
            let log = try emulatorLog()
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in self?.processEnded(finished) }
            }
            try process.run()
            self.process = process
            self.control = control.fileHandleForWriting
            self.title = title
            self.machine = launch.machine
            self.libraryDirectory = library.directory
            driveContents = [1: title.boot.drive1]
            if let second = title.boot.drive2 { driveContents[2] = second }
        } catch {
            lastError = "Could not start the emulator: \(error.localizedDescription)"
        }
    }

    func insert(_ side: DiskSide, drive: Int) {
        guard let libraryDirectory else { return }
        let path = EmulatorLaunch.diskURL(side.path, in: libraryDirectory).path
        if send(.mount(drive: drive, path: path)) { driveContents[drive] = side.path }
    }

    func eject(drive: Int) {
        if send(.eject(drive: drive)) { driveContents[drive] = nil }
    }

    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? control?.close()
        process = nil
        control = nil
        title = nil
        machine = nil
        driveContents = [:]
    }

    private func send(_ command: DriveCommand) -> Bool {
        guard let control else { return false }
        do {
            try control.write(contentsOf: Data(command.line().utf8))
            return true
        } catch {
            lastError = "The emulator did not accept the disk change: \(error.localizedDescription)"
            return false
        }
    }

    private func processEnded(_ finished: Process) {
        guard finished === process else { return }
        if finished.terminationStatus != 0 {
            lastError = "The emulator stopped (exit \(finished.terminationStatus)). See ~/Library/Logs/Apple2Forge/emulator.log."
        }
        stop()
    }

    /// a2emu titles its window with argv[0], so it is started through a link named after the title.
    private func windowTitleLink(named name: String, to emulator: URL) throws -> URL {
        let folder = URL.cachesDirectory.appending(path: "Apple2Forge/launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appending(path: name)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: emulator)
        return link
    }

    private func emulatorLog() throws -> FileHandle {
        let folder = AppSettings.shared.logDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "emulator.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
