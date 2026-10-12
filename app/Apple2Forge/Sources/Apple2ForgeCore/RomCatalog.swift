import CryptoKit
import Foundation

/// One of the ROM files the emulator needs. Apple2Forge never includes them;
/// you choose your own copy and it is checked, then copied into the ROM folder.
public enum RomSlot: String, CaseIterable, Sendable, Identifiable {
    case iiPlus
    case iieEnhanced
    case iieVideo

    public var id: String { rawValue }

    public var fileName: String {
        switch self {
        case .iiPlus: "apple2plus.rom"
        case .iieEnhanced: "apple2e-enhanced.rom"
        case .iieVideo: "apple2e-video.rom"
        }
    }

    public var displayName: String {
        switch self {
        case .iiPlus: "Apple ][+ ROM"
        case .iieEnhanced: "Apple //e ROM"
        case .iieVideo: "Apple //e video ROM"
        }
    }

    /// What the file must be, for the Settings window and error messages.
    public var requirement: String {
        switch self {
        case .iiPlus: "12 KB Apple ][+ (Autostart) ROM"
        case .iieEnhanced: "16 KB enhanced Apple //e ROM, or a 32 KB file holding one"
        case .iieVideo: "4 KB enhanced Apple //e video (character) ROM"
        }
    }

    public var machine: Machine {
        self == .iiPlus ? .iiPlus : .iie
    }
}

public enum RomError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case wrongSize(RomSlot, Int)
    case wrongMachine(RomSlot, String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            "\(path) could not be read."
        case .wrongSize(let slot, let size):
            "That file is \(size) bytes. The \(slot.displayName) must be a \(slot.requirement)."
        case .wrongMachine(let slot, let found):
            "That file is \(found), not a \(slot.requirement). Apple2Forge emulates the Apple ][+ and the enhanced Apple //e only."
        }
    }
}

/// The state of one ROM file in the ROM folder.
public enum RomStatus: Equatable, Sendable {
    case missing
    /// Installed and valid; `chip` names the Apple parts it matches, if known.
    case installed(chip: String?)
    case invalid(String)
}

/// Checks, identifies and installs ROM files.
///
/// Identity comes from the Monitor ROM's signature bytes. $FBB3 is $EA in the
/// Apple ][+ Autostart Monitor and $06 in the Apple //e Monitor (Apple //e
/// Technical Reference Manual, 1985, Appendix C, p. 230). On a //e-family ROM,
/// $FBC0 tells the versions apart: $EA original, $E0 enhanced, $00 Apple //c.
/// That second byte isn't in the manuals checked for references.md.
public enum RomCatalog {
    static let iiPlusSize = 12_288
    static let iiPlusWithIntegerSize = 20_480
    static let iieSize = 16_384
    static let iieDoubleSize = 32_768
    static let videoSize = 4_096

    /// SHA-256 of the Apple chip dumps (Apple II Documentation Project), so the
    /// Settings window can say which Apple parts a file matches. Fingerprints
    /// only: no ROM bytes are stored here.
    static let knownChips: [RomSlot: [String: String]] = [
        .iiPlus: ["fc3e9d41e9428534a883df5aa10eb55b73ea53d2fcbb3ee4f39bed1b07a82905":
                    "Apple 341-0011 to 341-0015 and 341-0020"],
        .iieEnhanced: ["aab38a03ca8deabbb2f868733148c2efd6f655a59cd9c5d058ef3e0b7aa86a1a":
                        "Apple 342-0304-A and 342-0303-A (same as 342-0349-B)"],
        .iieVideo: ["52c3b87900ac939f6525402cab1ccfd8f8259290fc6df54da48fb4c98ae3ed0f":
                    "Apple 342-0265-A"],
    ]

    /// The image to install for `slot`, taken from `data`: the whole file, or
    /// the right part of a larger file that holds one. Throws if it isn't one.
    public static func image(from data: Data, for slot: RomSlot) throws -> Data {
        let bytes = [UInt8](data)
        switch slot {
        case .iiPlus:
            guard bytes.count == iiPlusSize || bytes.count == iiPlusWithIntegerSize else {
                throw RomError.wrongSize(slot, bytes.count)
            }
            let image = Array(bytes.suffix(iiPlusSize))
            let id = image[0xFBB3 - 0xD000]
            guard id == 0xEA else {
                throw RomError.wrongMachine(slot, id == 0x06 ? "an Apple //e ROM" : "an original Apple II ROM (no Autostart)")
            }
            return Data(image)
        case .iieEnhanced:
            guard bytes.count == iieSize || bytes.count == iieDoubleSize else {
                throw RomError.wrongSize(slot, bytes.count)
            }
            let halves = bytes.count == iieSize ? [bytes[...]] : [bytes[iieSize...], bytes[..<iieSize]]
            var found = "not an Apple //e ROM"
            for half in halves {
                let image = Array(half)
                let family = image[0xFBB3 - 0xC000]
                let version = image[0xFBC0 - 0xC000]
                if family == 0x06 && version == 0xE0 { return Data(image) }
                if family == 0x06 { found = iieName(version) }
            }
            throw RomError.wrongMachine(slot, found)
        case .iieVideo:
            guard bytes.count == videoSize else { throw RomError.wrongSize(slot, bytes.count) }
            return data
        }
    }

    private static func iieName(_ version: UInt8) -> String {
        switch version {
        case 0xEA: "an original (unenhanced) Apple //e ROM"
        case 0x00: "an Apple //c ROM"
        default: "an Apple //e-family ROM this emulator doesn't support"
        }
    }

    public static func knownChip(_ data: Data, for slot: RomSlot) -> String? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return knownChips[slot]?[digest]
    }

    /// Guesses which ROM slot a file belongs to, for the first-run file picker.
    public static func detectSlot(_ data: Data) -> RomSlot? {
        if data.count == videoSize { return .iieVideo }
        if (try? image(from: data, for: .iiPlus)) != nil { return .iiPlus }
        if (try? image(from: data, for: .iieEnhanced)) != nil { return .iieEnhanced }
        return nil
    }

    public static func missingSlots(in romDirectory: URL) -> [RomSlot] {
        RomSlot.allCases.filter {
            switch status(of: $0, in: romDirectory) {
            case .installed: false
            default: true
            }
        }
    }

    public static func status(of slot: RomSlot, in romDirectory: URL) -> RomStatus {
        let file = romDirectory.appending(path: slot.fileName)
        guard let data = try? Data(contentsOf: file) else { return .missing }
        do {
            let image = try image(from: data, for: slot)
            return .installed(chip: knownChip(image, for: slot))
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    /// Checks `source` and copies it into `romDirectory` as `slot`'s file. An
    /// existing file is first moved to `backup-<time>/` in the same folder.
    /// Returns the backup folder, if a file was backed up.
    @discardableResult
    public static func install(_ source: URL, as slot: RomSlot, into romDirectory: URL,
                               now: Date = Date(), fileManager: FileManager = .default) throws -> URL? {
        guard let data = try? Data(contentsOf: source) else { throw RomError.unreadable(source.path) }
        let image = try image(from: data, for: slot)
        try fileManager.createDirectory(at: romDirectory, withIntermediateDirectories: true)
        let target = romDirectory.appending(path: slot.fileName)
        var backup: URL?
        if fileManager.fileExists(atPath: target.path) {
            let folder = romDirectory.appending(path: "backup-\(timestamp(now))", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: target, to: folder.appending(path: slot.fileName))
            backup = folder
        }
        try image.write(to: target, options: .atomic)
        return backup
    }

    /// The newest backup of `slot`'s file, if any.
    public static func latestBackup(of slot: RomSlot, in romDirectory: URL,
                                    fileManager: FileManager = .default) -> URL? {
        let folders = (try? fileManager.contentsOfDirectory(atPath: romDirectory.path)) ?? []
        return folders.filter { $0.hasPrefix("backup-") }.sorted().reversed()
            .map { romDirectory.appending(path: $0).appending(path: slot.fileName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Puts the newest backup back, backing up the current file first.
    public static func restoreLatestBackup(of slot: RomSlot, in romDirectory: URL, now: Date = Date(),
                                           fileManager: FileManager = .default) throws {
        guard let previous = latestBackup(of: slot, in: romDirectory, fileManager: fileManager) else { return }
        let data = try Data(contentsOf: previous)
        let staged = fileManager.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(slot.fileName)")
        try data.write(to: staged)
        defer { try? fileManager.removeItem(at: staged) }
        try install(staged, as: slot, into: romDirectory, now: now, fileManager: fileManager)
        try fileManager.removeItem(at: previous)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
