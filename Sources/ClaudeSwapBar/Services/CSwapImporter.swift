import Foundation

/// One-time import of accounts from an existing cswap installation
/// (`~/.claude-swap-backup`), so nobody has to re-login after moving to the
/// native client.
struct CSwapImporter {

    static var backupRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-swap-backup")
    }

    struct ImportedAccount {
        let account: Account
        let credentials: OAuthCredentials
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.backupRoot.appendingPathComponent("sequence.json").path)
    }

    /// Reads every OAuth account cswap manages. API-key slots are skipped —
    /// they have no subscription quota and can't be refreshed.
    func importAccounts() -> [ImportedAccount] {
        let sequenceURL = Self.backupRoot.appendingPathComponent("sequence.json")
        guard let data = try? Data(contentsOf: sequenceURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = root["accounts"] as? [String: [String: Any]] else {
            return []
        }

        var imported: [ImportedAccount] = []
        for (number, slot) in slots.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }) {
            guard let email = slot["email"] as? String, !email.isEmpty else { continue }
            if (slot["kind"] as? String) == "api_key" { continue }

            guard let raw = readSlotCredential(number: number, email: email),
                  let rawData = raw.data(using: .utf8),
                  let wrapper = try? JSONDecoder().decode(Wrapper.self, from: rawData) else {
                continue
            }

            let profileJSON = readSlotProfile(number: number, email: email)
            let account = Account(
                id: UUID(),
                email: email,
                organizationName: (slot["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                accountUuid: (slot["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                subscriptionType: wrapper.claudeAiOauth.subscriptionType,
                addedAt: Date(),
                oauthAccountJSON: profileJSON
            )
            imported.append(ImportedAccount(account: account, credentials: wrapper.claudeAiOauth))
        }
        return imported
    }

    // MARK: - Slot readers

    /// cswap keeps per-slot credentials in Keychain service "claude-swap",
    /// account "account-<num>-<email>", with base64 `.enc` files as fallback.
    private func readSlotCredential(number: String, email: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", "claude-swap",
            "-a", "account-\(number)-\(email)", "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                if !value.isEmpty { return value }
            }
        }

        let encURL = Self.backupRoot
            .appendingPathComponent("credentials")
            .appendingPathComponent(".creds-\(number)-\(email).enc")
        guard let base64 = try? String(contentsOf: encURL, encoding: .utf8),
              let decoded = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// The slot's backed-up ~/.claude.json holds the oauthAccount profile.
    private func readSlotProfile(number: String, email: String) -> String? {
        let configURL = Self.backupRoot
            .appendingPathComponent("configs")
            .appendingPathComponent(".claude-config-\(number)-\(email).json")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["oauthAccount"] as? [String: Any],
              let profileData = try? JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: profileData, as: UTF8.self)
    }

    private struct Wrapper: Codable {
        let claudeAiOauth: OAuthCredentials
    }
}
