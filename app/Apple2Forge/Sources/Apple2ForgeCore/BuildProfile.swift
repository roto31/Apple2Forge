import CryptoKit
import Foundation

/// A disk the T2 pipeline knows how to drive without a human: its capture
/// walk, scripted coverage sessions and recompile settings are in the
/// project. Listed in tools/t2/profiles.json, matched by the disk's SHA-256.
public struct BuildProfile: Codable, Sendable, Equatable {
    public let name: String
    public let diskSHA256: String
    /// Session folders, relative to the project, for tools/40_coverage.sh.
    public let coverageSessions: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case diskSHA256 = "disk_sha256"
        case coverageSessions = "coverage_sessions"
    }

    private struct File: Codable {
        let profiles: [BuildProfile]
    }

    public static func load(from url: URL) throws -> [BuildProfile] {
        try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).profiles
    }

    public static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
