import Foundation

/// The first-run checklist: the Stage 0 gates (from tools/00_setup.sh's
/// summary table) plus the files the build stages need.
public struct SetupCheckItem: Sendable, Equatable, Identifiable {
    public let name: String
    public let passed: Bool
    public let detail: String

    public var id: String { name }

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

public enum SetupCheck {
    static let romBytes = 12288

    /// Rows like "Gate 1: Toolchain   PASSED   3s" from print_summary.
    public static func gates(fromSummary lines: [String]) -> [SetupCheckItem] {
        lines.compactMap { line in
            guard let match = line.firstMatch(of: /^(Gate .+?)\s+(PASSED|FAILED|SKIPPED)\s+\d+s$/) else { return nil }
            let status = String(match.2)
            return SetupCheckItem(name: String(match.1), passed: status != "FAILED", detail: status)
        }
    }

    public static func files(project: ProjectTools, romDirectory: URL) -> [SetupCheckItem] {
        let fileManager = FileManager.default
        func romItem(_ name: String, _ url: URL, _ fix: String) -> SetupCheckItem {
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            let passed = size == romBytes
            let detail = passed ? url.path : (size.map { "\(url.path) is \($0) bytes, expected \(romBytes)" } ?? "missing: \(fix)")
            return SetupCheckItem(name: name, passed: passed, detail: detail)
        }
        let emulatorReady = fileManager.isExecutableFile(atPath: project.emulator.path)
        return [
            SetupCheckItem(name: "ROM-free emulator", passed: emulatorReady,
                           detail: emulatorReady ? project.emulator.path : "missing: run tools/15_build_a2emu_norom.sh"),
            romItem("Apple II+ ROM for builds", project.romFile, "run tools/05_fetch_rom.sh"),
            romItem("Apple II+ ROM for T1 apps", romDirectory.appending(path: "apple2plus.rom"),
                    "run tools/05_fetch_rom.sh --install"),
        ]
    }
}
