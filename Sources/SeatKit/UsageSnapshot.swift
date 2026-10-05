import Foundation

/// Rate-limit usage for one account, fetched from the Anthropic OAuth usage
/// endpoint.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    /// Per-model limits (e.g. Opus) from the `limits` array.
    public var scoped: [ScopedUsage]
    public var fetchedAt: Date
    /// The claude.ai account the numbers belong to. A seat can be logged in
    /// to a different account later; its old numbers must not carry over.
    public var accountEmail: String?

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, scoped: [ScopedUsage], fetchedAt: Date, accountEmail: String? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.fetchedAt = fetchedAt
        self.accountEmail = accountEmail
    }

    /// False when the snapshot was taken for another account than `email`.
    public func belongs(to email: String?) -> Bool {
        // Snapshots from before this field existed can't be attributed.
        guard let accountEmail, let email else { return false }
        return accountEmail.caseInsensitiveCompare(email) == .orderedSame
    }

    /// The usage endpoint allows ~28–30 requests/hour per token, so snapshots
    /// younger than 3 minutes are always served from cache.
    public var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 180
    }
}

public struct ScopedUsage: Codable, Equatable, Sendable {
    public var name: String
    public var window: UsageWindow
}

public struct UsageWindow: Codable, Equatable, Sendable {
    /// 0–100.
    public var utilization: Double
    public var resetsAt: Date?

    public var fraction: Double { min(max(utilization / 100, 0), 1) }

    public var resetText: String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return "resets in \(days)d \(hours % 24)h"
        }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }
}

/// Why usage could not be shown for an account — surfaced in the UI instead
/// of a bare "usage unavailable".
public enum UsageProblem: Codable, Equatable, Error, Sendable {
    /// The account has no login yet.
    case notLoggedIn
    /// The access token expired and nothing is using the account. Refreshing
    /// it from outside would consume Claude Code's refresh token, so the
    /// meters wait until the account is used again.
    case idle
    case unauthorized
    case rateLimited(retryAt: Date?)
    case network(String)

    public var shortText: String {
        switch self {
        case .notLoggedIn: return "not logged in yet"
        case .idle: return "idle — updates the next time this account runs"
        case .unauthorized: return "login no longer valid — log in again"
        case .rateLimited: return "usage API rate-limited, retrying later"
        case .network: return "offline — will retry"
        }
    }
}
