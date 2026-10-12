@testable import Apple2ForgeCore
import Foundation
import Testing

private let supported = AnalysisSummary(supported: true, loaderID: "mecc", customLoader: true, entryPoint: "$3000",
                                        protectionStatus: "already-cracked", headline: "custom MECC loader")
private let unsupported = AnalysisSummary(supported: false, loaderID: nil, customLoader: nil, entryPoint: nil,
                                          protectionStatus: nil, headline: "Unsupported input (nib)")

private func profile() throws -> BuildProfile {
    let json = #"{"profiles": [{"name": "Game", "disk_sha256": "abc", "coverage_sessions": ["tests/fixtures/stage4"]}]}"#
    let folder = FileManager.default.temporaryDirectory.appending(path: "a2forge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "profiles.json")
    try Data(json.utf8).write(to: file)
    return try #require(BuildProfile.load(from: file).first)
}

private func stages(_ pairs: [BuildStage: StageStatus]) -> [BuildStage: StageStatus] {
    var all = Dictionary(uniqueKeysWithValues: BuildStage.allCases.map { ($0, StageStatus.pending) })
    all.merge(pairs) { $1 }
    return all
}

@Suite struct BuildToolTests {
    @Test func diskTypesAcceptOnlyDiskImages() {
        #expect(DiskTypes.accepts(URL(filePath: "/a/Game.DSK")))
        #expect(DiskTypes.accepts(URL(filePath: "/a/game.nib")))
        #expect(!DiskTypes.accepts(URL(filePath: "/a/notes.txt")))
        #expect(!DiskTypes.accepts(URL(filePath: "/a/game.2mg")))
    }

    @Test func profileDecodesSnakeCaseKeys() throws {
        let loaded = try profile()
        #expect(loaded.diskSHA256 == "abc")
        #expect(loaded.coverageSessions == ["tests/fixtures/stage4"])
    }

    @Test func t2RunsOnlyForSupportedProfiledDisksWhenAsked() throws {
        let gameProfile = try profile()
        #expect(BuildPipeline.reasonToSkipT2(analysis: unsupported, t1Passed: false, profile: gameProfile,
                                             attemptT2: true) != nil)
        #expect(BuildPipeline.reasonToSkipT2(analysis: supported, t1Passed: false, profile: gameProfile,
                                             attemptT2: true) == "Wrap (T1) did not pass")
        #expect(BuildPipeline.reasonToSkipT2(analysis: supported, t1Passed: true, profile: nil,
                                             attemptT2: true)?.contains("T2 game profile") == true)
        #expect(BuildPipeline.reasonToSkipT2(analysis: supported, t1Passed: true, profile: gameProfile,
                                             attemptT2: false)?.contains("Try T2") == true)
        #expect(BuildPipeline.reasonToSkipT2(analysis: supported, t1Passed: true, profile: gameProfile,
                                             attemptT2: true) == nil)
    }

    @Test func reportTiersAndT2Verdicts() throws {
        let t1 = CompatibilityReport.make(analysis: supported, stages: stages([.wrapT1: .passed]),
                                          profile: nil, attemptedT2: false)
        #expect(t1.tier == .t1)
        #expect(t1.t2Possible.hasPrefix("Not automatically"))
        #expect(t1.nextSteps.first?.contains("apple2plus.rom") == true)
        #expect(t1.reasons.contains { $0.hasPrefix("Custom loader (mecc)") })

        let t2 = CompatibilityReport.make(analysis: supported,
                                          stages: stages([.wrapT1: .passed, .capture: .passed,
                                                          .coverage: .passed, .recompile: .passed]),
                                          profile: try profile(), attemptedT2: true)
        #expect(t2.tier == .t2Hybrid)
        #expect(t2.t2Possible.hasPrefix("Yes. The T2-hybrid app was built"))

        let failed = CompatibilityReport.make(analysis: supported,
                                              stages: stages([.wrapT1: .passed, .coverage: .failed("boom")]),
                                              profile: try profile(), attemptedT2: true)
        #expect(failed.tier == .t1)
        #expect(failed.t2Possible == "Not this time: Coverage: boom.")

        let none = CompatibilityReport.make(analysis: unsupported, stages: stages([:]), profile: nil,
                                            attemptedT2: false)
        #expect(none.tier == .none)
        #expect(none.t2Possible.hasPrefix("No:"))
        #expect(none.markdown.contains("Use only disks you are entitled to use."))

        let missing = CompatibilityReport.make(analysis: nil, stages: stages([.analyze: .failed("x")]),
                                               profile: nil, attemptedT2: false)
        #expect(missing.tier == .none)
        #expect(missing.t2Possible.hasPrefix("Unknown"))
    }

    @Test func setupGatesComeFromTheSummaryTable() {
        let lines = ["  [PASSED] Gate 0: Inputs",
                     "Step                                     Status   Duration",
                     "Gate 0: Toolchain                        PASSED   3s",
                     "Gate 1: apple2tc build                   FAILED   12s",
                     "Gate 2: Smoke test                       SKIPPED  0s",
                     "Overall: FAILED | Total time: 15s"]
        let gates = SetupCheck.gates(fromSummary: lines)
        #expect(gates.map(\.name) == ["Gate 0: Toolchain", "Gate 1: apple2tc build", "Gate 2: Smoke test"])
        #expect(gates.map(\.passed) == [true, false, true])
    }
}
