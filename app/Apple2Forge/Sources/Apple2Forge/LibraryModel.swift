import Apple2ForgeCore
import Foundation
import Observation

@MainActor
@Observable
final class LibraryModel {
    private(set) var directory: URL
    private(set) var catalog: LibraryCatalog?
    private(set) var menu: [SubjectMenu] = []
    private(set) var loadError: String?

    init() {
        directory = AppSettings.shared.libraryDirectory
        reload()
    }

    func reload() {
        directory = AppSettings.shared.libraryDirectory
        do {
            let loaded = try LibraryCatalog.load(fromLibrary: directory)
            catalog = loaded
            menu = loaded.menu
            loadError = nil
        } catch {
            catalog = nil
            menu = []
            loadError = error.localizedDescription
        }
    }

    var visibleTitleCount: Int {
        menu.reduce(0) { $0 + $1.titles.count }
    }
}
