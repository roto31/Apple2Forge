import Foundation

/// The analyzer's verdict on a disk (analysis.json "summary").
public struct AnalysisSummary: Codable, Sendable, Equatable {
    public let supported: Bool
    public let loaderID: String?
    public let customLoader: Bool?
    public let entryPoint: String?
    public let protectionStatus: String?
    public let headline: String

    enum CodingKeys: String, CodingKey {
        case supported, headline
        case loaderID = "loader_id"
        case customLoader = "custom_loader"
        case entryPoint = "entry_point"
        case protectionStatus = "protection_status"
    }

    public init(supported: Bool, loaderID: String?, customLoader: Bool?, entryPoint: String?,
                protectionStatus: String?, headline: String) {
        self.supported = supported
        self.loaderID = loaderID
        self.customLoader = customLoader
        self.entryPoint = entryPoint
        self.protectionStatus = protectionStatus
        self.headline = headline
    }

    public static func load(fromAnalysis url: URL) throws -> AnalysisSummary {
        struct File: Codable { let summary: AnalysisSummary }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).summary
    }
}

/// Per disk: the tier reached, why it is not higher, and what to do next.
public struct CompatibilityReport: Codable, Sendable, Equatable {
    public enum Tier: String, Codable, Sendable {
        case t2Hybrid = "T2-hybrid"
        case t1 = "T1"
        case none = "None"
    }

    public let tier: Tier
    public let headline: String
    public let reasons: [String]
    public let t2Possible: String
    public let nextSteps: [String]

    public static let romPath = "~/Library/Application Support/Apple2Forge/roms/apple2plus.rom"

    public static func make(analysis: AnalysisSummary?, stages: [BuildStage: StageStatus],
                            profile: BuildProfile?, attemptedT2: Bool) -> CompatibilityReport {
        let t1Built = stages[.wrapT1] == .passed
        let t2Built = stages[.recompile] == .passed
        let tier: Tier = t2Built ? .t2Hybrid : (t1Built ? .t1 : .none)
        var reasons = analysisReasons(analysis)
        var nextSteps: [String] = []
        let t2Possible: String

        guard let analysis else {
            return CompatibilityReport(tier: tier, headline: "The analyzer did not finish.",
                                       reasons: ["Analyze failed; its log has the error."],
                                       t2Possible: "Unknown until the disk is analyzed.",
                                       nextSteps: ["Open the Analyze log, fix the problem it names, and drop the disk again."])
        }
        if !analysis.supported {
            t2Possible = "No: this disk format is not supported."
            nextSteps.append("Convert the image to a 140K sector image (.dsk, .do or .po), then drop it again.")
        } else if t2Built {
            t2Possible = "Yes. The T2-hybrid app was built and matched the emulator frame for frame on every recorded and random-key session (see the equivalence reports)."
            nextSteps.append("Open the T2-hybrid app. It needs no ROM.")
        } else if let profile {
            if !attemptedT2 {
                t2Possible = "Yes, for this disk (\(profile.name)): choose Try T2. It takes about 9 minutes."
                reasons.append("T2 was not attempted in this build.")
                nextSteps.append("Choose Try T2 to recompile.")
            } else {
                let failure = [BuildStage.capture, .coverage, .recompile].lazy
                    .compactMap { stage -> String? in
                        if case .failed(let message) = stages[stage] { return "\(stage.rawValue): \(message)" }
                        return nil
                    }.first ?? "the T2 stages did not finish"
                t2Possible = "Not this time: \(failure)."
                reasons.append("T2 failed (\(failure)). The T1 app is the deliverable.")
                nextSteps.append("Open the failed stage's log; each gate prints its repair step.")
            }
        } else {
            t2Possible = "Not automatically. T2 needs a game profile; this disk has none."
            reasons.append("No T2 game profile. T2 needs recorded play that reaches every menu and game mode, the address of a stable start screen, and C versions of the Monitor ROM routines the game calls. Only the disks in tools/t2/profiles.json have one.")
            nextSteps.append("Use Record Coverage to play every menu and game mode. The recording and its coverage report are kept with this build as the start of a profile.")
        }
        if t1Built {
            nextSteps.insert("Open the T1 app. It needs your Apple II+ ROM at \(romPath).", at: 0)
        } else if analysis.supported {
            if case .failed = stages[.wrapT1] {
                nextSteps.insert("Open the Wrap (T1) log; the failing gate prints its repair step.", at: 0)
            }
        }
        return CompatibilityReport(tier: tier, headline: analysis.headline, reasons: reasons,
                                   t2Possible: t2Possible, nextSteps: nextSteps)
    }

    private static func analysisReasons(_ analysis: AnalysisSummary?) -> [String] {
        guard let analysis else { return [] }
        guard analysis.supported else { return ["Unsupported format: \(analysis.headline)."] }
        var reasons: [String] = []
        if analysis.customLoader == true {
            reasons.append("Custom loader (\(analysis.loaderID ?? "unidentified")): the game is loaded by the disk's own code, not DOS files, so T2 has to capture the code from memory while it runs.")
        }
        switch analysis.protectionStatus {
        case "protected":
            reasons.append("Copy protection: the disk's read code expects non-standard markers, so this sector image may not boot.")
        case "unknown":
            reasons.append("Copy protection could not be judged from track 0.")
        default:
            break
        }
        return reasons
    }

    public var markdown: String {
        var lines = ["# Compatibility report", "", "- **Tier reached:** \(tier.rawValue)",
                     "- **Disk:** \(headline)", "- **T2 possible:** \(t2Possible)", ""]
        lines.append("## Reasons for the tier")
        lines += reasons.isEmpty ? ["- None: the highest tier was reached."] : reasons.map { "- \($0)" }
        lines += ["", "## Next steps"] + nextSteps.map { "- \($0)" }
        lines += ["", "Use only disks you are entitled to use. Builds are for personal use; distributing them may infringe copyright."]
        return lines.joined(separator: "\n") + "\n"
    }
}
