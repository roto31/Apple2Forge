import Foundation

public enum Machine: String, Sendable {
    case iiPlus
    case iie

    /// ROM files this machine needs from the ROM folder. They are installed
    /// by tools/05_fetch_rom.sh and never shipped with the app.
    public var romFiles: [String] {
        switch self {
        case .iiPlus: ["apple2plus.rom"]
        case .iie: ["apple2e-enhanced.rom", "apple2e-video.rom"]
        }
    }

    public var displayName: String {
        switch self {
        case .iiPlus: "Apple ][+"
        case .iie: "Apple //e"
        }
    }
}

public enum LaunchError: Error, LocalizedError, Equatable {
    case cannotStart(String)
    case missingRoms(Machine, [String])
    case missingDisk(String)

    public var errorDescription: String? {
        switch self {
        case .cannotStart(let title):
            "\(title) is not a startup disk. Its other disks are used from within another title."
        case .missingRoms(let machine, let files):
            "The \(machine.displayName) ROM is not installed (\(files.joined(separator: ", "))). In Terminal, run tools/05_fetch_rom.sh --install" + (machine == .iie ? " --model=iie" : "") + " from the Apple ][ - Native Games folder."
        case .missingDisk(let path):
            "The disk image \(path) is missing. Download the educational library again to restore it."
        }
    }
}

/// How the app starts a2emu for a title: a symlink named after the title (a2emu
/// shows argv[0] as its window title), the arguments, and the machine.
public struct EmulatorLaunch: Sendable, Equatable {
    /// a2emu reads "mount D PATH" / "eject D" lines from this descriptor: its standard input.
    public static let controlDescriptor = 0

    public let machine: Machine
    public let arguments: [String]
    public let windowTitle: String

    public init(title: LibraryTitle, libraryDirectory: URL, romDirectory: URL,
                fileManager: FileManager = .default) throws {
        guard let machine = title.requirement.machine else { throw LaunchError.cannotStart(title.title) }
        let missing = machine.romFiles.filter {
            !fileManager.fileExists(atPath: romDirectory.appending(path: $0).path)
        }
        guard missing.isEmpty else { throw LaunchError.missingRoms(machine, missing) }
        let disks = [title.boot.drive1] + (title.boot.drive2.map { [$0] } ?? [])
        let diskPaths = disks.map { EmulatorLaunch.diskURL($0, in: libraryDirectory).path }
        if let absent = diskPaths.first(where: { !fileManager.fileExists(atPath: $0) }) {
            throw LaunchError.missingDisk(absent)
        }

        var arguments = ["--control-fd=\(Self.controlDescriptor)"]
        switch machine {
        case .iiPlus:
            arguments.append("--rom=\(romDirectory.appending(path: "apple2plus.rom").path)")
        case .iie:
            arguments += ["--model=iie",
                          "--rom=\(romDirectory.appending(path: "apple2e-enhanced.rom").path)",
                          "--video-rom=\(romDirectory.appending(path: "apple2e-video.rom").path)"]
        }
        for (index, path) in diskPaths.enumerated() {
            arguments.append("--disk\(index + 1)=\(path)")
        }
        self.machine = machine
        self.arguments = arguments
        self.windowTitle = EmulatorLaunch.windowTitle(for: title.title)
    }

    public static func diskURL(_ relativePath: String, in libraryDirectory: URL) -> URL {
        libraryDirectory.appending(path: "disks").appending(path: relativePath)
    }

    /// A file name that shows the title: no path separators or colons.
    public static func windowTitle(for title: String) -> String {
        let cleaned = title.map { "/:".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Apple2Forge" : name
    }
}

/// A line for a2emu's control descriptor.
public enum DriveCommand: Sendable, Equatable {
    case mount(drive: Int, path: String)
    case eject(drive: Int)

    public enum CommandError: Error, Equatable {
        case badDrive(Int)
        case badPath(String)
    }

    public func line() throws -> String {
        switch self {
        case .mount(let drive, let path):
            guard (1...2).contains(drive) else { throw CommandError.badDrive(drive) }
            guard !path.contains("\n"), !path.isEmpty else { throw CommandError.badPath(path) }
            return "mount \(drive) \(path)\n"
        case .eject(let drive):
            guard (1...2).contains(drive) else { throw CommandError.badDrive(drive) }
            return "eject \(drive)\n"
        }
    }
}
