import Foundation

/// Reads a seat's Claude Code login without ever changing it.
///
/// The Keychain item is read through `/usr/bin/security` rather than
/// Security.framework: Claude Code creates the item through that binary, and
/// reading it in-process from a differently signed app triggers a Keychain
/// prompt on every rebuild.
public struct SeatCredentialReader: Sendable {

    public init() {}

    public func credentials(for seat: Seat) -> SeatCredentials? {
        let raw = keychainPayload(for: seat)
            ?? (try? String(contentsOf: seat.credentialsFileURL, encoding: .utf8))
        guard let raw, let data = raw.data(using: .utf8) else { return nil }

        struct Wrapper: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let expiresAt: Double
                let subscriptionType: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Wrapper.self, from: data))?.claudeAiOauth else { return nil }
        return SeatCredentials(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt,
            subscriptionType: oauth.subscriptionType
        )
    }

    /// Only used when the user removes a seat on purpose.
    func deleteKeychainItem(for seat: Seat) {
        guard !seat.isMain else { return }
        // Delete until none is left; capped in case `security` misbehaves.
        for _ in 0..<5 {
            guard runSecurity(["delete-generic-password", "-s", seat.keychainService]).exitCode == 0 else { return }
        }
    }

    private func keychainPayload(for seat: Seat) -> String? {
        let result = runSecurity(["find-generic-password", "-s", seat.keychainService, "-w"])
        guard result.exitCode == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func runSecurity(_ args: [String]) -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
}

/// Claude Code's advisory lock protocol: the lock is a *directory*, mkdir is
/// the mutex primitive, and a holder older than 10 seconds (by mtime) is
/// considered stale and taken over.
public struct DirectoryLock: Sendable {
    public struct Timeout: LocalizedError {
        public var errorDescription: String? {
            "Claude Code is busy writing its config — try again in a few seconds."
        }
    }

    public let url: URL
    public var timeout: TimeInterval = 9
    public var staleAfter: TimeInterval = 10

    public init(url: URL) {
        self.url = url
    }

    public func acquire() throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if mkdir(url.path, 0o755) == 0 { return }

            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > staleAfter {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            if Date() >= deadline { throw Timeout() }
            usleep(200_000)
        }
    }

    public func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
