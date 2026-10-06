import Foundation

/// Fetches usage for a seat using its current access token, read-only.
///
/// An expired token is never refreshed here: the refresh token is single-use,
/// and spending it outside Claude Code is exactly what logged accounts out
/// before. Such a seat reports `.idle` and keeps its last cached snapshot.
public struct SeatUsageFetcher: Sendable {
    private let reader = SeatCredentialReader()
    private let service = UsageService()

    public init() {}

    public func fetch(_ seat: Seat, cached: UsageSnapshot?, force: Bool = false) async -> (UsageSnapshot?, UsageProblem?) {
        guard let credentials = reader.credentials(for: seat) else { return (nil, .notLoggedIn) }
        let email = SeatStore().profile(of: seat)?.email
        let cached = cached?.belongs(to: email) == true ? cached : nil
        if !force, let cached, !cached.isStale { return (cached, nil) }
        guard !credentials.isAccessTokenExpired else { return (cached, .idle) }
        do {
            var snapshot = try await service.fetchUsage(accessToken: credentials.accessToken)
            snapshot.accountEmail = email
            return (snapshot, nil)
        } catch let error as UsageService.UsageError {
            return (cached, error.asProblem)
        } catch {
            return (cached, .network(error.localizedDescription))
        }
    }
}

/// Usage snapshots per seat slug, shared by the menu bar app and `cswap` so
/// neither burns the ~30 requests/hour budget the other already spent.
public enum UsageCache {
    public static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CSwap/usage.json")
    }

    /// Where versions before the rename kept the cache.
    static var legacyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwapBar/seat-usage.json")
    }

    /// Accounts missing from the cache fall back to the pre-rename one, so an
    /// idle account keeps its last numbers across the update.
    public static func load() -> [String: UsageSnapshot] {
        decode(legacyURL).merging(decode(url)) { _, current in current }
    }

    private static func decode(_ file: URL) -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: UsageSnapshot].self, from: data)) ?? [:]
    }

    public static func save(_ cache: [String: UsageSnapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    public static func update(_ slug: String, _ snapshot: UsageSnapshot?) {
        var cache = load()
        cache[slug] = snapshot
        save(cache)
    }
}
