import CryptoKit
import Foundation

/// One Claude Code account, isolated in its own configuration directory.
///
/// The `main` seat is the plain `~/.claude` setup Claude Code uses without
/// `CLAUDE_CONFIG_DIR`. Every other seat lives in `~/.claude-seats/<slug>` and
/// is launched with `CLAUDE_CONFIG_DIR` pointing there, which gives it its own
/// login, its own `.claude.json` and its own Keychain item.
public struct Seat: Identifiable, Hashable, Sendable {
    public static let mainSlug = "main"

    public let slug: String
    public let configDir: URL

    public var id: String { slug }
    public var isMain: Bool { slug == Self.mainSlug }

    public init(slug: String, configDir: URL) {
        self.slug = slug
        self.configDir = configDir.standardizedFileURL
    }

    /// `CLAUDE_CONFIG_DIR` value for this seat, or nil for `main`.
    public var configDirEnvironmentValue: String? {
        isMain ? nil : configDir.path
    }

    /// Without `CLAUDE_CONFIG_DIR`, `.claude.json` sits in $HOME rather than
    /// inside `~/.claude`.
    public var claudeJSONURL: URL {
        if isMain {
            return configDir.deletingLastPathComponent().appendingPathComponent(".claude.json")
        }
        return configDir.appendingPathComponent(".claude.json")
    }

    public var credentialsFileURL: URL {
        configDir.appendingPathComponent(".credentials.json")
    }

    /// Claude Code keys its macOS Keychain item to the config directory:
    /// `Claude Code-credentials` by default, plus `-<first 8 hex chars of
    /// sha256(dir)>` when `CLAUDE_CONFIG_DIR` is set.
    public var keychainService: String {
        guard let dir = configDirEnvironmentValue else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Slugs become directory names and CLI arguments, so keep them boring.
    public static func isValidSlug(_ slug: String) -> Bool {
        guard (1...32).contains(slug.count), slug != mainSlug else { return false }
        guard let first = slug.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// The claude.ai identity a seat is logged in with, read from the seat's
/// `.claude.json`.
public struct SeatProfile: Equatable, Sendable {
    public var email: String
    public var organizationName: String?
}

/// Read-only view of a seat's OAuth credential. SeatKit never refreshes or
/// writes these — Claude Code owns the refresh-token lineage of every seat.
public struct SeatCredentials: Sendable {
    public var accessToken: String
    /// Milliseconds since epoch.
    public var expiresAt: Double
    public var subscriptionType: String?

    public var isAccessTokenExpired: Bool {
        Date(timeIntervalSince1970: expiresAt / 1000) <= Date().addingTimeInterval(60)
    }

    public var planLabel: String? {
        switch subscriptionType {
        case "max": return "Max"
        case "pro": return "Pro"
        case "enterprise": return "Enterprise"
        case "team": return "Team"
        default: return subscriptionType?.capitalized
        }
    }
}
