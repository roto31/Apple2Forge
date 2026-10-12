import Foundation

public struct RomPickResult: Sendable {
    public let url: URL
    public let outcome: Result<RomSlot, Error>
}

public struct RomInstallSummary: Sendable {
    public let results: [RomPickResult]
    public let missingSlots: [RomSlot]
}

public enum RomInstallError: Error, LocalizedError, Equatable {
    case scriptMissing
    case scriptFailed(model: String, status: Int32)
    case missingAfterInstall([RomSlot])

    public var errorDescription: String? {
        switch self {
        case .scriptMissing:
            "The ROM download script is missing. Rebuild Apple2Forge.app."
        case .scriptFailed(let model, let status):
            "Downloading the \(model) ROM failed (exit \(status)). Check ~/Library/Logs/Apple2Forge/rom-install.log."
        case .missingAfterInstall(let slots):
            "These ROMs are still missing: \(slots.map(\.displayName).joined(separator: ", "))."
        }
    }
}

/// Fetches ROMs via the bundled script or installs files the user picked.
public enum RomInstaller {
    private static let models = [("iiplus", "Apple ][+"), ("iie", "enhanced Apple //e")]

    public static func installAutomatically(
        tools: ToolPaths,
        romDirectory: URL,
        workDirectory: URL,
        log: URL,
        runner: ScriptRunner = ScriptRunner(),
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let script = tools.script(ToolPaths.romScript)
        guard FileManager.default.fileExists(atPath: script.path) else { throw RomInstallError.scriptMissing }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: romDirectory, withIntermediateDirectories: true)
        for (model, label) in models {
            let status = try await runner.run(
                script,
                arguments: [
                    "--model=\(model)", "--install",
                    "--work-dir=\(workDirectory.path)",
                    "--install-dir=\(romDirectory.path)",
                ],
                in: tools.root,
                log: log,
                appendToLog: model != "iiplus",
                onLine: onLine
            )
            guard status == 0 else { throw RomInstallError.scriptFailed(model: label, status: status) }
        }
        let missing = RomCatalog.missingSlots(in: romDirectory)
        guard missing.isEmpty else { throw RomInstallError.missingAfterInstall(missing) }
    }

    public static func installPicked(_ urls: [URL], into romDirectory: URL,
                                   fileManager: FileManager = .default) -> RomInstallSummary {
        var results: [RomPickResult] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                results.append(RomPickResult(url: url, outcome: .failure(RomError.unreadable(url.path))))
                continue
            }
            guard let slot = RomCatalog.detectSlot(data) else {
                results.append(RomPickResult(
                    url: url,
                    outcome: .failure(RomError.wrongMachine(.iiPlus, "a file Apple2Forge does not recognise as a ROM"))
                ))
                continue
            }
            do {
                try RomCatalog.install(url, as: slot, into: romDirectory, fileManager: fileManager)
                results.append(RomPickResult(url: url, outcome: .success(slot)))
            } catch {
                results.append(RomPickResult(url: url, outcome: .failure(error)))
            }
        }
        return RomInstallSummary(results: results, missingSlots: RomCatalog.missingSlots(in: romDirectory))
    }
}
