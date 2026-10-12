import Foundation

/// The machine a title needs, as decided by the compatibility sweep or the file name.
public enum Requirement: String, Codable, Sendable {
    case iiPlus = "IIplus64K"
    case iie = "IIe128K"
    case noBoot = "noboot"
    case unknown

    /// The emulated machine to start; nil when the boot disk cannot start anything.
    /// A title that booted on neither machine is still offered on the II+.
    public var machine: Machine? {
        switch self {
        case .iiPlus, .unknown: .iiPlus
        case .iie: .iie
        case .noBoot: nil
        }
    }
}

public struct DiskSide: Codable, Sendable, Hashable {
    public let side: String
    public let path: String
    public let file: String
}

public struct LibraryDisk: Codable, Sendable, Hashable {
    public let number: Int
    public let label: String
    public let sides: [DiskSide]
}

public struct BootDrives: Codable, Sendable, Hashable {
    public let drive1: String
    public let drive2: String?
}

public struct LibraryTitle: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subject: String?
    public let hidden: Bool
    public let requirement: Requirement
    public let requirementDetail: String
    public let disks: [LibraryDisk]
    public let boot: BootDrives

    /// Every side in disk order, with the label the Disk menu shows for it.
    public var sideChoices: [(label: String, side: DiskSide)] {
        disks.flatMap { disk in
            disk.sides.map { side in
                let label = disk.label.isEmpty ? "" : " (\(disk.label))"
                return (label: "Disk \(disk.number) Side \(side.side)\(label)", side: side)
            }
        }
    }

    public var menuLabel: String {
        switch requirement {
        case .iie: "\(title) — Apple //e"
        case .noBoot: "\(title) — not a startup disk"
        case .iiPlus, .unknown: title
        }
    }
}

public struct SubjectMenu: Sendable, Identifiable {
    public let subject: String
    public let titles: [LibraryTitle]
    public var id: String { subject }
}

public struct LibraryCatalog: Codable, Sendable {
    public static let fileName = "library.json"
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let dataRevision: String
    public let subjects: [String]
    public let titles: [LibraryTitle]

    public init(schemaVersion: Int, dataRevision: String, subjects: [String], titles: [LibraryTitle]) {
        self.schemaVersion = schemaVersion
        self.dataRevision = dataRevision
        self.subjects = subjects
        self.titles = titles
    }

    public enum LoadError: Error, LocalizedError {
        case missing(URL)
        case unsupportedSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .missing(let url):
                "There is no library catalog at \(url.path). Download the educational library first."
            case .unsupportedSchema(let version):
                "The library catalog uses schema \(version); this app reads schema \(LibraryCatalog.supportedSchemaVersion). Rebuild the catalog."
            }
        }
    }

    public static func load(fromLibrary directory: URL) throws -> LibraryCatalog {
        let url = directory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(url) }
        let catalog = try JSONDecoder().decode(LibraryCatalog.self, from: Data(contentsOf: url))
        guard catalog.schemaVersion == supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(catalog.schemaVersion)
        }
        return catalog
    }

    /// Subjects in catalog order, each with its visible titles sorted as Finder sorts names.
    /// Subjects with no visible titles are left out.
    public var menu: [SubjectMenu] {
        subjects.compactMap { subject in
            let titles = self.titles
                .filter { !$0.hidden && $0.subject == subject }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return titles.isEmpty ? nil : SubjectMenu(subject: subject, titles: titles)
        }
    }

    /// The menu as indented text, for `--dump-menu` and the app gate.
    public var menuOutline: String {
        menu.map { subject in
            ([subject.subject] + subject.titles.map { "  \($0.menuLabel)" }).joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }
}
