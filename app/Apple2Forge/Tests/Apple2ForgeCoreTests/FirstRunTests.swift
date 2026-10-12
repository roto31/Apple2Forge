import Apple2ForgeCore
import Foundation
import Testing

private func fakeROM(size: Int, base: Int, bytes: [Int: UInt8]) -> Data {
    var data = Data(count: size)
    for (address, value) in bytes { data[address - base] = value }
    return data
}

private let iiPlus = fakeROM(size: 12_288, base: 0xD000, bytes: [0xFBB3: 0xEA])
private let enhancedIIe = fakeROM(size: 16_384, base: 0xC000, bytes: [0xFBB3: 0x06, 0xFBC0: 0xE0])

@Suite struct FirstRunTests {
    @Test func detectSlotRecognisesEachRomType() {
        #expect(RomCatalog.detectSlot(iiPlus) == .iiPlus)
        #expect(RomCatalog.detectSlot(enhancedIIe) == .iieEnhanced)
        #expect(RomCatalog.detectSlot(Data(count: 4_096)) == .iieVideo)
        #expect(RomCatalog.detectSlot(Data(count: 100)) == nil)
    }

    @Test func installPickedInstallsRecognisedFiles() throws {
        let roms = FileManager.default.temporaryDirectory
            .appending(path: "FirstRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: roms) }

        let plusFile = roms.appending(path: "plus.bin")
        try iiPlus.write(to: plusFile)
        let summary = RomInstaller.installPicked([plusFile], into: roms)
        #expect(summary.results.count == 1)
        #expect(summary.missingSlots.contains(.iiPlus) == false)
        #expect(RomCatalog.status(of: .iiPlus, in: roms) == .installed(chip: nil))
    }

    @Test func firstRunStateSkipsWhenCompletedOrAutomation() {
        let suite = "FirstRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var state = FirstRunState(defaults: defaults)
        #expect(state.shouldRun(skipExplicit: false, skipForAutomation: false))
        state.markCompleted()
        #expect(!state.shouldRun(skipExplicit: false, skipForAutomation: false))
        defaults.removeObject(forKey: FirstRunState.completedKey)
        state = FirstRunState(defaults: defaults)
        #expect(!state.shouldRun(skipExplicit: true, skipForAutomation: false))
        #expect(!state.shouldRun(skipExplicit: false, skipForAutomation: true))
    }
}
