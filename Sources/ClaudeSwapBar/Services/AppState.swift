import Foundation
import SeatKit
import SwiftUI

/// What the menu shows for one seat.
struct SeatInfo: Identifiable, Equatable {
    let seat: Seat
    var email: String?
    var organizationName: String?
    var planLabel: String?
    var isLoggedIn: Bool
    var sessions: [RunningSession]

    var runningSessions: Int { sessions.count }

    var id: String { seat.slug }
    var title: String { seat.isMain ? "main" : seat.slug }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var seats: [SeatInfo] = []
    @Published private(set) var defaultSlug = Seat.mainSlug
    @Published private(set) var usage: [String: UsageSnapshot] = [:]
    @Published private(set) var usageProblems: [String: UsageProblem] = [:]
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var isShellIntegrationInstalled = false
    @Published var errorMessage: String?
    @Published var lastAction: String?

    @AppStorage("refreshIntervalMinutes") var refreshIntervalMinutes = 5
    @AppStorage("autoSwitchDefault") var autoSwitchDefault = true

    private let store = SeatStore()
    private let reader = SeatCredentialReader()
    private let fetcher = SeatUsageFetcher()
    private var refreshTimer: Timer?
    private var watcher: SeatWatcher?

    /// Per-seat "do not fetch before" gate. Respected even by forced
    /// refreshes — the usage endpoint budget (~30/hour/account) is precious.
    private var backoffUntil: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]

    var defaultSeat: SeatInfo? {
        seats.first { $0.id == defaultSlug }
    }

    /// Another seat logged in to the same claude.ai account, usually after a
    /// `/login` inside the wrong seat. Both then share one quota.
    func duplicate(of info: SeatInfo) -> SeatInfo? {
        guard let email = info.email else { return nil }
        return seats.first { $0.id != info.id && $0.email?.caseInsensitiveCompare(email) == .orderedSame }
    }

    init() {
        usage = UsageCache.load()
        reload()
        refreshShellIntegration()
        restartUsageTimer()
        startWatching()
    }

    /// Follows what `cseat` and Claude Code change on disk.
    private func startWatching() {
        let watcher = SeatWatcher(
            seatsRoot: store.root,
            paths: [store.mainSeat.configDir.appendingPathComponent("sessions"), UsageCache.url.deletingLastPathComponent()],
            usageFile: UsageCache.url
        ) { [weak self] changes in
            Task { @MainActor [weak self] in self?.apply(changes) }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func apply(_ changes: Set<SeatWatcher.Change>) {
        if changes.contains(.seats) {
            reload()
        } else if changes.contains(.sessions) {
            reloadSessions()
        }
        if changes.contains(.usage) {
            mergeCachedUsage()
        }
    }

    /// Session records change on every reply; refresh them without asking
    /// the Keychain about every login again.
    private func reloadSessions() {
        for index in seats.indices {
            let fresh = store.runningSessions(of: seats[index].seat)
            if fresh != seats[index].sessions { seats[index].sessions = fresh }
        }
    }

    /// Picks up usage `cseat` fetched, when it is newer than ours.
    private func mergeCachedUsage() {
        for (slug, snapshot) in UsageCache.load() where (usage[slug]?.fetchedAt ?? .distantPast) < snapshot.fetchedAt {
            guard let info = seats.first(where: { $0.id == slug }), snapshot.belongs(to: info.email) else { continue }
            usage[slug] = snapshot
            usageProblems[slug] = nil
        }
    }

    /// Rewrites the zsh snippet and `/swap` when they are installed, so an
    /// app update also updates them.
    private func refreshShellIntegration() {
        guard isShellIntegrationInstalled else { return }
        let linked = store.home.appendingPathComponent(".local/bin/cseat").path
        try? store.writeShellInit(cseatPath: linked)
        _ = try? store.installSwapCommand()
    }

    // MARK: - Loading

    func reload() {
        seats = store.seats().map { seat in
            let profile = store.profile(of: seat)
            let credentials = reader.credentials(for: seat)
            return SeatInfo(
                seat: seat,
                // A profile without a stored login is a leftover from an
                // unfinished login; don't present it as this seat's account.
                email: credentials == nil ? nil : profile?.email,
                organizationName: credentials == nil ? nil : profile?.organizationName,
                planLabel: credentials?.planLabel,
                isLoggedIn: credentials != nil && profile != nil,
                sessions: store.runningSessions(of: seat)
            )
        }
        // Numbers cached for another login of the same seat are wrong now.
        for info in seats where usage[info.id]?.belongs(to: info.email) == false {
            usage[info.id] = nil
        }
        defaultSlug = store.defaultSeat().slug
        isShellIntegrationInstalled = Self.zshrcSourcesIntegration(home: store.home)
            && FileManager.default.fileExists(atPath: store.shellInitURL.path)
    }

    // MARK: - Usage

    func refreshUsage(force: Bool = false) async {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }

        mergeCachedUsage()

        let now = Date()
        let work = seats.map(\.seat).filter { seat in
            if let gate = backoffUntil[seat.slug], gate > now { return false }
            return force || usage[seat.slug]?.isStale != false
        }

        await withTaskGroup(of: (String, UsageSnapshot?, UsageProblem?).self) { group in
            for seat in work {
                let cached = usage[seat.slug]
                group.addTask { [fetcher] in
                    let (snapshot, problem) = await fetcher.fetch(seat, cached: cached, force: force)
                    return (seat.slug, snapshot, problem)
                }
            }
            for await (slug, snapshot, problem) in group {
                usage[slug] = snapshot
                usageProblems[slug] = problem
                if let problem {
                    scheduleBackoff(for: slug, after: problem)
                } else {
                    failureCounts[slug] = 0
                    backoffUntil[slug] = nil
                }
            }
        }

        UsageCache.save(usage)
        switchDefaultIfExhausted()
    }

    /// When the default account's 5h or weekly window is full, new sessions would
    /// start blocked. Hand the default to the account with the most room.
    private func switchDefaultIfExhausted() {
        guard autoSwitchDefault, let current = defaultSeat,
              let room = usage[current.id]?.headroom, room <= 1 else { return }
        let candidates = seats.filter { info in
            guard info.id != current.id, info.isLoggedIn, duplicate(of: info)?.id != current.id else { return false }
            return headroom(info) > 5
        }
        guard let best = candidates.max(by: { headroom($0) < headroom($1) }) else { return }
        makeDefault(best)
        lastAction = "\(current.title) is at its limit — new sessions now use \(best.email ?? best.title). Move running ones: /swap"
    }

    private func scheduleBackoff(for slug: String, after problem: UsageProblem) {
        let failures = (failureCounts[slug] ?? 0) + 1
        failureCounts[slug] = failures

        switch problem {
        case let .rateLimited(retryAt):
            // 429: honor Retry-After (capped), else hold off for a full
            // 5 minutes minimum — the hourly budget is already gone.
            let holdOff = retryAt?.timeIntervalSinceNow ?? 0
            backoffUntil[slug] = Date().addingTimeInterval(min(max(holdOff, 300), 900))
        case .notLoggedIn, .idle:
            // Cheap local checks; look again on the next timer tick.
            backoffUntil[slug] = nil
        case .unauthorized:
            backoffUntil[slug] = Date().addingTimeInterval(300)
        case .network:
            let delay = min(60 * pow(2, Double(failures - 1)), 600)
            backoffUntil[slug] = Date().addingTimeInterval(delay)
        }
    }

    func restartUsageTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(3, refreshIntervalMinutes)) * 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
                await self?.refreshUsage()
            }
        }
    }

    // MARK: - Default seat

    /// Makes `seat` the account plain `claude` starts. Running sessions keep
    /// their account; nothing about any login changes.
    func makeDefault(_ info: SeatInfo) {
        do {
            try store.setDefault(info.seat)
            defaultSlug = info.id
            lastAction = "New sessions use \(info.email ?? info.title). Move a running session: /swap"
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Makes the logged-in seat with the most quota left the default.
    func makeBestDefault() {
        let candidates = seats.filter { $0.isLoggedIn && usage[$0.id]?.fiveHour != nil }
        guard let best = candidates.max(by: { headroom($0) < headroom($1) }) else {
            errorMessage = "No account has usage data yet."
            return
        }
        makeDefault(best)
    }

    private func headroom(_ info: SeatInfo) -> Double {
        usage[info.id]?.headroom ?? -1
    }

    // MARK: - Seat management

    func addSeat(named slug: String, email: String?) -> Bool {
        do {
            let seat = try store.create(slug: slug)
            reload()
            logIn(seat, email: email)
            return true
        } catch {
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    /// Opens a terminal running the browser login for `seat`. Claude Code
    /// creates and owns the credential; the app only watches for it.
    func logIn(_ seat: Seat, email: String? = nil) {
        var arguments = ["login", seat.slug]
        if let email, !email.isEmpty { arguments += ["--email", email] }
        runCSeatInTerminal(arguments)
    }

    /// Starts the seat through the shell integration when it's installed,
    /// so `/swap` in that window restarts in the same tab.
    func openSession(_ info: SeatInfo) {
        let slug = TerminalLauncher.shellQuoted(info.id)
        let fallback = cseatCommand([info.id])
        guard let fallback else { return }
        let command = "if typeset -f _cseat_session >/dev/null; then _cseat_session \(slug) --; else \(fallback); fi"
        do {
            try TerminalLauncher.run(command)
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Moves a running session to `target`, the same way `/swap` does.
    func move(_ session: RunningSession, to target: SeatInfo) {
        let cseatPath = store.home.appendingPathComponent(".local/bin/cseat").path
        let cli = FileManager.default.isExecutableFile(atPath: cseatPath) ? cseatPath : (Self.bundledCLI?.path ?? cseatPath)
        do {
            let handoff = try SessionMover(store: store).move(session, to: target.seat, cseatPath: cli)
            let place = handoff == .sameTab ? "in its tab" : "in a new terminal window"
            lastAction = "\(session.title) continues with \(target.email ?? target.title) \(place)"
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    /// Accounts a session in `info` can move to: logged in, another login.
    func moveTargets(from info: SeatInfo) -> [SeatInfo] {
        seats.filter { other in
            guard other.id != info.id, other.isLoggedIn else { return false }
            guard let mine = info.email, let theirs = other.email else { return true }
            return mine.caseInsensitiveCompare(theirs) != .orderedSame
        }
    }

    func remove(_ info: SeatInfo) {
        do {
            try store.remove(info.seat)
            usage[info.id] = nil
            usageProblems[info.id] = nil
            UsageCache.save(usage)
            reload()
            lastAction = "Removed \(info.title)"
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    func revealInFinder(_ info: SeatInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([info.seat.configDir])
    }

    // MARK: - Command-line tool

    /// The `cseat` binary shipped inside the app bundle.
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cseat")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Links `~/.local/bin/cseat`, writes the zsh snippet and sources it from
    /// `~/.zshrc`, by running the bundled `cseat setup`.
    func installShellIntegration() {
        guard let cli = Self.bundledCLI else {
            errorMessage = "The cseat tool is missing from the app bundle."
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["setup"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                lastAction = "Shell integration installed — open a new terminal"
                errorMessage = nil
            } else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                errorMessage = message.isEmpty ? "cseat setup failed." : message
            }
        } catch {
            errorMessage = friendlyMessage(error)
        }
        reload()
    }

    /// Shell command running `cseat` with `arguments`; prefers the stable
    /// link so terminals show a short command.
    private func cseatCommand(_ arguments: [String]) -> String? {
        let linked = store.home.appendingPathComponent(".local/bin/cseat").path
        guard let cli = FileManager.default.isExecutableFile(atPath: linked) ? linked : Self.bundledCLI?.path else {
            errorMessage = "The cseat tool is missing from the app bundle."
            return nil
        }
        return ([cli] + arguments).map(TerminalLauncher.shellQuoted).joined(separator: " ")
    }

    private func runCSeatInTerminal(_ arguments: [String]) {
        guard let command = cseatCommand(arguments) else { return }
        do {
            try TerminalLauncher.run(command)
        } catch {
            errorMessage = friendlyMessage(error)
        }
    }

    private static func zshrcSourcesIntegration(home: URL) -> Bool {
        let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
        return zshrc.contains(SeatStore.shellSourceLine)
    }

    // MARK: - Helpers

    private func friendlyMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
