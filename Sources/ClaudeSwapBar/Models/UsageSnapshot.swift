import Foundation

/// Rate-limit usage for one account, fetched from the Anthropic OAuth usage
/// endpoint.
struct UsageSnapshot: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    /// Per-model limits (e.g. Opus) from the `limits` array.
    var scoped: [ScopedUsage]
    var fetchedAt: Date

    /// The usage endpoint allows ~28–30 requests/hour per token, so snapshots
    /// younger than 3 minutes are always served from cache.
    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 180
    }
}

struct ScopedUsage: Codable, Equatable {
    var name: String
    var window: UsageWindow
}

struct UsageWindow: Codable, Equatable {
    /// 0–100.
    var utilization: Double
    var resetsAt: Date?

    var fraction: Double { min(max(utilization / 100, 0), 1) }

    var resetText: String? {
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
enum UsageProblem: Codable, Equatable, Error {
    case tokenExpired
    case unauthorized
    case rateLimited(retryAt: Date?)
    case network(String)

    var shortText: String {
        switch self {
        case .tokenExpired: return "session expired — re-add account"
        case .unauthorized: return "no usage access for this account"
        case .rateLimited: return "usage API rate-limited, retrying later"
        case .network: return "offline — will retry"
        }
    }
}
