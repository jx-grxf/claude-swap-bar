import Foundation

/// Our own account store. Profiles live in
/// `~/Library/Application Support/ClaudeSwapBar/accounts.json`; each account's
/// OAuth tokens live in a per-account Keychain item.
final class Vault {

    static let keychainService = "ClaudeSwapBar-account"

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("accounts.json") }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("ClaudeSwapBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Accounts

    func loadAccounts() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(VaultFile.self, from: data) else {
            return []
        }
        return file.accounts
    }

    func saveAccounts(_ accounts: [Account]) throws {
        let file = VaultFile(schemaVersion: 1, accounts: accounts)
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ account: Account, credentials: OAuthCredentials) throws {
        var accounts = loadAccounts()
        if let index = accounts.firstIndex(where: {
            $0.email.caseInsensitiveCompare(account.email) == .orderedSame
        }) {
            var merged = account
            merged.addedAt = accounts[index].addedAt
            accounts[index] = merged
            try storeCredentials(credentials, for: accounts[index].id)
        } else {
            accounts.append(account)
            try storeCredentials(credentials, for: account.id)
        }
        try saveAccounts(accounts)
    }

    func remove(_ account: Account) throws {
        var accounts = loadAccounts()
        accounts.removeAll { $0.id == account.id }
        try saveAccounts(accounts)
        try? Keychain.delete(service: Self.keychainService, account: account.id.uuidString)
    }

    // MARK: - Credentials

    func credentials(for accountID: UUID) throws -> OAuthCredentials {
        let raw = try Keychain.readString(service: Self.keychainService, account: accountID.uuidString)
        guard let data = raw.data(using: .utf8) else {
            throw Keychain.KeychainError.notFound
        }
        return try decoder.decode(OAuthCredentials.self, from: data)
    }

    func storeCredentials(_ credentials: OAuthCredentials, for accountID: UUID) throws {
        let payload = String(decoding: try encoder.encode(credentials), as: UTF8.self)
        try Keychain.writeString(payload, service: Self.keychainService, account: accountID.uuidString)
    }

    // MARK: - Plumbing

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private struct VaultFile: Codable {
        let schemaVersion: Int
        let accounts: [Account]
    }
}
