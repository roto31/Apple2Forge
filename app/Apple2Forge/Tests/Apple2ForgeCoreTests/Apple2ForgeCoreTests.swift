import Apple2ForgeCore
import Foundation
import Testing

private func makeTitle(id: String, title: String, subject: String?, hidden: Bool = false,
                       requirement: Requirement = .iiPlus, drive2: String? = nil) -> LibraryTitle {
    let catalogJSON = """
    {"id": "\(id)", "title": "\(title)", "subject": \(subject.map { "\"\($0)\"" } ?? "null"),
     "hidden": \(hidden), "requirement": "\(requirement.rawValue)", "requirementDetail": "",
     "disks": [{"number": 1, "label": "", "sides": [
        {"side": "A", "path": "\(id) A.dsk", "file": "\(id) A"},
        {"side": "B", "path": "\(id) B.dsk", "file": "\(id) B"}]}],
     "boot": {"drive1": "\(id) A.dsk", "drive2": \(drive2.map { "\"\($0)\"" } ?? "null")}}
    """
    return try! JSONDecoder().decode(LibraryTitle.self, from: Data(catalogJSON.utf8))
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "a2forge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct CatalogTests {
    @Test func menuKeepsSubjectOrderSortsTitlesAndSkipsHidden() throws {
        let titles = [makeTitle(id: "b", title: "Number 10", subject: "Math"),
                      makeTitle(id: "a", title: "Number 9", subject: "Math"),
                      makeTitle(id: "h", title: "Hidden", subject: "Math", hidden: true),
                      makeTitle(id: "r", title: "Reader", subject: "Reading")]
        let catalog = LibraryCatalog(schemaVersion: 1, dataRevision: "x",
                                     subjects: ["Reading", "Math", "Arts"], titles: titles)
        #expect(catalog.menu.map(\.subject) == ["Reading", "Math"])
        #expect(catalog.menu[1].titles.map(\.title) == ["Number 9", "Number 10"])
        #expect(catalog.menuOutline == "Reading\n  Reader\nMath\n  Number 9\n  Number 10\n")
    }

    @Test func diskMenuListsEverySide() {
        let labels = makeTitle(id: "q", title: "Quest", subject: "Math").sideChoices.map(\.label)
        #expect(labels == ["Disk 1 Side A", "Disk 1 Side B"])
    }

    @Test func missingCatalogExplainsWhatToDo() throws {
        let folder = try temporaryFolder()
        #expect(throws: LibraryCatalog.LoadError.self) { try LibraryCatalog.load(fromLibrary: folder) }
    }
}

@Suite struct LocationTests {
    @Test func foldersInsideAnAppAreRefused() {
        let inside = URL(filePath: "/Applications/Apple2Forge.app/Contents/library")
        #expect(throws: LibraryLocation.ValidationError.insideAppBundle(inside.path)) {
            try LibraryLocation.validate(inside)
        }
    }

    @Test func chosenFolderIsRemembered() throws {
        let suite = "Apple2ForgeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try temporaryFolder()
        try LibraryLocationStore(defaults: defaults).save(folder)
        let reread = LibraryLocationStore(defaults: try #require(UserDefaults(suiteName: suite))).saved
        #expect(reread?.standardizedFileURL.resolvingSymlinksInPath()
                == folder.standardizedFileURL.resolvingSymlinksInPath())
    }
}

@Suite struct LaunchTests {
    private func fixture(roms: [String]) throws -> (library: URL, roms: URL) {
        let library = try temporaryFolder()
        let disks = library.appending(path: "disks")
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        for name in ["q A.dsk", "q B.dsk"] {
            FileManager.default.createFile(atPath: disks.appending(path: name).path, contents: Data())
        }
        let romFolder = try temporaryFolder()
        for rom in roms {
            FileManager.default.createFile(atPath: romFolder.appending(path: rom).path, contents: Data())
        }
        return (library, romFolder)
    }

    @Test func iiPlusTitleMountsBothBootSides() throws {
        let (library, roms) = try fixture(roms: Machine.iiPlus.romFiles)
        let title = makeTitle(id: "q", title: "Quest: Part 1/2", subject: "Math", drive2: "q B.dsk")
        let launch = try EmulatorLaunch(title: title, libraryDirectory: library, romDirectory: roms)
        #expect(launch.machine == .iiPlus)
        #expect(launch.windowTitle == "Quest- Part 1-2")
        #expect(launch.arguments.first == "--control-fd=0")
        #expect(launch.arguments.contains("--disk1=\(library.appending(path: "disks/q A.dsk").path)"))
        #expect(launch.arguments.contains("--disk2=\(library.appending(path: "disks/q B.dsk").path)"))
        #expect(!launch.arguments.contains("--model=iie"))
    }

    @Test func iieTitleNeedsBothIIeRoms() throws {
        let title = makeTitle(id: "q", title: "Quest", subject: "Math", requirement: .iie)
        let (library, roms) = try fixture(roms: ["apple2e-enhanced.rom"])
        #expect(throws: LaunchError.missingRoms(.iie, ["apple2e-video.rom"])) {
            try EmulatorLaunch(title: title, libraryDirectory: library, romDirectory: roms)
        }
        FileManager.default.createFile(atPath: roms.appending(path: "apple2e-video.rom").path, contents: Data())
        let launch = try EmulatorLaunch(title: title, libraryDirectory: library, romDirectory: roms)
        #expect(launch.arguments.contains("--model=iie"))
    }

    @Test func noBootTitleIsNotStarted() throws {
        let (library, roms) = try fixture(roms: Machine.iiPlus.romFiles)
        let title = makeTitle(id: "q", title: "Data", subject: "Math", requirement: .noBoot)
        #expect(throws: LaunchError.cannotStart("Data")) {
            try EmulatorLaunch(title: title, libraryDirectory: library, romDirectory: roms)
        }
    }

    @Test func driveCommandsAreSingleLines() throws {
        #expect(try DriveCommand.mount(drive: 2, path: "/a b/c.dsk").line() == "mount 2 /a b/c.dsk\n")
        #expect(try DriveCommand.eject(drive: 1).line() == "eject 1\n")
        #expect(throws: DriveCommand.CommandError.badDrive(3)) { try DriveCommand.eject(drive: 3).line() }
        #expect(throws: DriveCommand.CommandError.badPath("a\nb")) {
            try DriveCommand.mount(drive: 1, path: "a\nb").line()
        }
    }
}

@Suite struct ProgressTests {
    @Test func fileEventsBecomeProgress() throws {
        let line = #"{"event": "file", "path": "x.dsk", "outcome": "downloaded", "done_files": 3, "total_files": 10, "done_bytes": 430080, "total_bytes": 1433600, "eta_seconds": 12}"#
        let progress = try #require(DownloadPipeline.progress(fromJSONLine: line))
        #expect(progress.doneFiles == 3 && progress.totalFiles == 10 && progress.etaSeconds == 12)
        #expect(abs(progress.fraction - 0.3) < 0.0001)
        #expect(DownloadPipeline.progress(fromJSONLine: #"{"event": "hashing"}"#) == nil)
        #expect(DownloadPipeline.progress(fromJSONLine: "Gate 1 PASSED") == nil)
    }
}
