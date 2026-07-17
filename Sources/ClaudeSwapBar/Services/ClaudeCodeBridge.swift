import Foundation

/// Reads and writes the credential surfaces Claude Code itself uses on macOS:
/// the `Claude Code-credentials` Keychain item and the `oauthAccount` block in
/// `~/.claude.json`. This is what makes switching work without any CLI.
///
/// The Claude Code Keychain item is accessed through `/usr/bin/security`
/// rather than Security.framework: the item was created by that binary's
/// identity, and touching it in-process from a differently-signed app triggers
/// "wants to access your keychain" prompts on every rebuild.
struct ClaudeCodeBridge {

    static let keychainService = "Claude Code-credentials"

    static var configHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// `.claude.json` sits in $HOME by default, not inside ~/.claude — unless
    /// CLAUDE_CONFIG_DIR redirects everything.
    static var claudeJSONURL: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    static var credentialsFileURL: URL {
        configHome.appendingPathComponent(".credentials.json")
    }

    enum BridgeError: LocalizedError {
        case noCredentials
        case malformedCredentials
        case claudeJSONUnreadable
        case lockTimeout
        case keychainWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No Claude Code login found. Run `claude` and log in first."
            case .malformedCredentials:
                return "The Claude Code Keychain entry has an unexpected format."
            case .claudeJSONUnreadable:
                return "~/.claude.json could not be read."
            case .lockTimeout:
                return "Claude Code is busy updating its credentials — try again in a few seconds."
            case let .keychainWriteFailed(detail):
                return "Could not write the Claude Code Keychain item: \(detail)"
            }
        }
    }

    // MARK: - Read current login

    func currentCredentials() throws -> OAuthCredentials {
        let raw: String
        if let fromKeychain = try? securityRead() {
            raw = fromKeychain
        } else if let fromFile = try? String(contentsOf: Self.credentialsFileURL, encoding: .utf8) {
            raw = fromFile
        } else {
            throw BridgeError.noCredentials
        }
        guard let data = raw.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(CredentialsWrapper.self, from: data) else {
            throw BridgeError.malformedCredentials
        }
        return wrapper.claudeAiOauth
    }

    func currentProfileJSON() throws -> (json: String, email: String, organizationName: String?, accountUuid: String?) {
        guard let data = try? Data(contentsOf: Self.claudeJSONURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["oauthAccount"] as? [String: Any] else {
            throw BridgeError.claudeJSONUnreadable
        }
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        return (
            json: String(decoding: profileData, as: UTF8.self),
            email: profile["emailAddress"] as? String ?? "unknown",
            organizationName: profile["organizationName"] as? String,
            accountUuid: profile["accountUuid"] as? String
        )
    }

    /// True when a Claude Code process appears to be actively using the login
    /// (session PID files under ~/.claude/sessions). While one is live, the
    /// active credential belongs to it — never refresh it from outside.
    func isClaudeCodeRunning() -> Bool {
        let sessionsDir = Self.configHome.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return false
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = session["pid"] as? Int else { continue }
            if kill(pid_t(pid), 0) == 0 { return true }
        }
        return false
    }

    // MARK: - Activate an account

    /// Writes an account's credentials + profile so Claude Code runs as that
    /// account. Takes Claude Code's own advisory locks for the duration.
    func activate(credentials: OAuthCredentials, profileJSON: String?) throws {
        let credentialsLock = DirectoryLock(url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.lock"))
        let configLock = DirectoryLock(url: URL(fileURLWithPath: Self.claudeJSONURL.path + ".lock"))

        try credentialsLock.acquire()
        defer { credentialsLock.release() }
        try configLock.acquire()
        defer { configLock.release() }

        try writeActiveCredentials(credentials)
        if let profileJSON {
            try writeProfile(profileJSON)
        }
    }

    /// Updates only the tokens (after a refresh), leaving the profile as-is.
    func updateActiveCredentials(_ credentials: OAuthCredentials) throws {
        let lock = DirectoryLock(url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.lock"))
        try lock.acquire()
        defer { lock.release() }
        try writeActiveCredentials(credentials)
    }

    // MARK: - Internals

    private func writeActiveCredentials(_ credentials: OAuthCredentials) throws {
        let wrapper = CredentialsWrapper(claudeAiOauth: credentials)
        let payload = String(decoding: try JSONEncoder().encode(wrapper), as: UTF8.self)
        try securityWrite(payload)

        // If a plaintext credentials file exists, rewrite it with the same
        // bytes: Claude Code invalidates its in-memory token cache on mtime
        // change, making the switch apply without a restart.
        let fileURL = Self.credentialsFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try payload.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func writeProfile(_ profileJSON: String) throws {
        guard let data = try? Data(contentsOf: Self.claudeJSONURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileData = profileJSON.data(using: .utf8),
              let profile = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any] else {
            throw BridgeError.claudeJSONUnreadable
        }
        root["oauthAccount"] = profile

        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try out.write(to: Self.claudeJSONURL, options: .atomic)
    }

    // MARK: - security(1) plumbing

    private static var keychainAccount: String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    private func securityRead() throws -> String {
        let result = try runSecurity([
            "find-generic-password", "-s", Self.keychainService,
            "-a", Self.keychainAccount, "-w",
        ])
        guard result.exitCode == 0 else { throw BridgeError.noCredentials }
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    private func securityWrite(_ value: String) throws {
        let result = try runSecurity([
            "add-generic-password", "-U", "-s", Self.keychainService,
            "-a", Self.keychainAccount, "-w", value,
        ])
        guard result.exitCode == 0 else {
            throw BridgeError.keychainWriteFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runSecurity(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private struct CredentialsWrapper: Codable {
        let claudeAiOauth: OAuthCredentials
    }
}

/// Claude Code's advisory lock protocol: the lock is a *directory*, mkdir is
/// the mutex primitive, and a holder older than 10 seconds (by mtime) is
/// considered stale and taken over.
struct DirectoryLock {
    let url: URL
    var timeout: TimeInterval = 9
    var staleAfter: TimeInterval = 10

    func acquire() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if mkdir(url.path, 0o755) == 0 { return }

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > staleAfter {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            if Date() >= deadline {
                throw ClaudeCodeBridge.BridgeError.lockTimeout
            }
            usleep(200_000)
        }
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
