import Apple2ForgeCore
import Foundation
import Testing

/// Made-up ROM images: zeros apart from the signature bytes the checks read.
private func fakeROM(size: Int, base: Int, bytes: [Int: UInt8]) -> Data {
    var data = Data(count: size)
    for (address, value) in bytes { data[address - base] = value }
    return data
}

private let iiPlus = fakeROM(size: 12_288, base: 0xD000, bytes: [0xFBB3: 0xEA])
private let enhancedIIe = fakeROM(size: 16_384, base: 0xC000, bytes: [0xFBB3: 0x06, 0xFBC0: 0xE0])

private func romFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "Apple2ForgeRomTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ data: Data, named name: String) throws -> URL {
    let url = try romFolder().appending(path: name)
    try data.write(to: url)
    return url
}

@Suite struct RomCatalogTests {
    @Test func acceptsIIPlusAndRejectsOtherMachines() throws {
        #expect(try RomCatalog.image(from: iiPlus, for: .iiPlus) == iiPlus)
        #expect(throws: RomError.wrongSize(.iiPlus, 16_384)) { try RomCatalog.image(from: enhancedIIe, for: .iiPlus) }
        let original = fakeROM(size: 12_288, base: 0xD000, bytes: [0xFBB3: 0x38])
        #expect(throws: RomError.wrongMachine(.iiPlus, "an original Apple II ROM (no Autostart)")) {
            try RomCatalog.image(from: original, for: .iiPlus)
        }
    }

    @Test func takesTheLast12KOfA20KFile() throws {
        let file = Data(count: 8_192) + iiPlus
        #expect(try RomCatalog.image(from: file, for: .iiPlus) == iiPlus)
    }

    @Test func acceptsOnlyTheEnhancedIIe() throws {
        #expect(try RomCatalog.image(from: enhancedIIe, for: .iieEnhanced) == enhancedIIe)
        let unenhanced = fakeROM(size: 16_384, base: 0xC000, bytes: [0xFBB3: 0x06, 0xFBC0: 0xEA])
        #expect(throws: RomError.wrongMachine(.iieEnhanced, "an original (unenhanced) Apple //e ROM")) {
            try RomCatalog.image(from: unenhanced, for: .iieEnhanced)
        }
        let iic = fakeROM(size: 16_384, base: 0xC000, bytes: [0xFBB3: 0x06, 0xFBC0: 0x00])
        #expect(throws: RomError.wrongMachine(.iieEnhanced, "an Apple //c ROM")) {
            try RomCatalog.image(from: iic, for: .iieEnhanced)
        }
    }

    @Test func findsTheIIeHalfOfA32KFile() throws {
        #expect(try RomCatalog.image(from: Data(count: 16_384) + enhancedIIe, for: .iieEnhanced) == enhancedIIe)
        #expect(try RomCatalog.image(from: enhancedIIe + Data(count: 16_384), for: .iieEnhanced) == enhancedIIe)
    }

    @Test func videoRomIsCheckedBySize() throws {
        #expect(try RomCatalog.image(from: Data(count: 4_096), for: .iieVideo).count == 4_096)
        #expect(throws: RomError.wrongSize(.iieVideo, 8_192)) { try RomCatalog.image(from: Data(count: 8_192), for: .iieVideo) }
    }

    @Test func installBacksUpAndRestoreBringsItBack() throws {
        let roms = try romFolder()
        defer { try? FileManager.default.removeItem(at: roms) }
        #expect(RomCatalog.status(of: .iiPlus, in: roms) == .missing)

        let first = try write(iiPlus, named: "first.rom")
        #expect(try RomCatalog.install(first, as: .iiPlus, into: roms) == nil)
        #expect(RomCatalog.status(of: .iiPlus, in: roms) == .installed(chip: nil))

        var second = iiPlus
        second[0] = 0x42
        let secondFile = try write(second, named: "second.rom")
        let backup = try #require(try RomCatalog.install(secondFile, as: .iiPlus, into: roms,
                                                         now: Date(timeIntervalSince1970: 0)))
        #expect(try Data(contentsOf: backup.appending(path: "apple2plus.rom")) == iiPlus)
        #expect(try Data(contentsOf: roms.appending(path: "apple2plus.rom")) == second)

        try RomCatalog.restoreLatestBackup(of: .iiPlus, in: roms, now: Date(timeIntervalSince1970: 60))
        #expect(try Data(contentsOf: roms.appending(path: "apple2plus.rom")) == iiPlus)
        let newestBackup = try #require(RomCatalog.latestBackup(of: .iiPlus, in: roms))
        #expect(try Data(contentsOf: newestBackup) == second)
    }

    @Test func aRefusedFileLeavesTheInstalledOneAlone() throws {
        let roms = try romFolder()
        defer { try? FileManager.default.removeItem(at: roms) }
        try RomCatalog.install(try write(iiPlus, named: "good.rom"), as: .iiPlus, into: roms)
        let bad = try write(Data(count: 100), named: "bad.rom")
        #expect(throws: RomError.wrongSize(.iiPlus, 100)) { try RomCatalog.install(bad, as: .iiPlus, into: roms) }
        #expect(try Data(contentsOf: roms.appending(path: "apple2plus.rom")) == iiPlus)
    }
}
