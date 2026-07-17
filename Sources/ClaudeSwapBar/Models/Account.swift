import Foundation

/// A managed Claude account. Profile data lives in the vault JSON; OAuth
/// tokens live in the macOS Keychain, keyed by `id`.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    var organizationName: String?
    var accountUuid: String?
    var subscriptionType: String?
    var addedAt: Date

    /// Snapshot of the `oauthAccount` object from ~/.claude.json captured when
    /// the account was added; restored verbatim on switch so Claude Code sees
    /// a consistent profile.
    var oauthAccountJSON: String?

    var displayName: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }

    var planLabel: String? {
        switch subscriptionType {
        case "max": return "Max"
        case "pro": return "Pro"
        case "enterprise": return "Enterprise"
        case "team": return "Team"
        default: return subscriptionType?.capitalized
        }
    }
}

/// OAuth credential set, mirroring the `claudeAiOauth` payload Claude Code
/// stores in the Keychain.
struct OAuthCredentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Milliseconds since epoch.
    var expiresAt: Double
    var refreshTokenExpiresAt: Double?
    var scopes: [String]
    var subscriptionType: String?
    var rateLimitTier: String?

    var isAccessTokenExpired: Bool {
        Date(timeIntervalSince1970: expiresAt / 1000) <= Date().addingTimeInterval(120)
    }
}
