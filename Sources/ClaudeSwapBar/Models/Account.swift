import Foundation

/// Mirrors the JSON emitted by `cswap --list --json`.
struct AccountList: Codable {
    let schemaVersion: Int
    let activeAccountNumber: Int?
    let accounts: [Account]
}

struct Account: Codable, Identifiable {
    let number: Int
    let email: String
    let organizationName: String?
    let isOrganization: Bool?
    let active: Bool
    let usageStatus: String
    let usage: Usage?

    var id: Int { number }

    /// Short display name: the local part of the email, capitalised.
    var shortName: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }
}

struct Usage: Codable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
}

struct UsageWindow: Codable {
    let pct: Double
    let resetsAt: String?
    let countdown: String?
    let clock: String?
}
