import Foundation

/// Creates, lists and maintains seats on disk.
///
/// Invariant: nothing in here writes, refreshes or copies an OAuth credential.
/// Each seat's login is created by `claude` itself and only ever touched by
/// Claude Code processes running in that seat. Swapping one shared credential
/// slot is what made every earlier switcher log people out.
public struct SeatStore: Sendable {

    public enum SeatError: LocalizedError {
        case invalidSlug(String)
        case alreadyExists(String)
        case notFound(String)
        case cannotRemoveMain

        public var errorDescription: String? {
            switch self {
            case let .invalidSlug(slug):
                return "\u{201C}\(slug)\u{201D} is not a valid account name. Use 1–32 lowercase letters, digits or dashes, starting with a letter."
            case let .alreadyExists(slug):
                return "An account named \u{201C}\(slug)\u{201D} already exists."
            case let .notFound(slug):
                return "No account named \u{201C}\(slug)\u{201D}."
            case .cannotRemoveMain:
                return "The main account is your normal ~/.claude setup and can't be removed."
            }
        }
    }

    /// Items in `~/.claude` that every seat shares through a symlink: memory,
    /// transcripts, settings, skills, plugins, hooks. Everything else — login,
    /// `.claude.json`, prompt history, live session records — stays per seat.
    public static let sharedDirectories = [
        "agents", "commands", "file-history", "hooks", "output-styles", "plans",
        "plugins", "projects", "security-skills", "skills", "tasks", "themes", "todos",
    ]
    public static let sharedFiles = ["settings.json", "keybindings.json", "statusline.sh"]

    /// `.claude.json` keys copied from the main account into each seat, so
    /// user-scoped MCP servers follow every account.
    public static let sharedTopLevelKeys = ["mcpServers"]
    /// Per-project keys copied the same way: trust, permissions and
    /// project-scoped MCP servers.
    public static let sharedProjectKeys = [
        "allowedTools", "disabledMcpjsonServers", "enabledMcpjsonServers",
        "hasCompletedProjectOnboarding", "hasTrustDialogAccepted", "mcpContextUris", "mcpServers",
    ]

    public let home: URL

    /// `CSWAP_HOME` relocates every seat path for tests. It deliberately
    /// isn't `HOME`: `security` resolves the login Keychain through `HOME`.
    public init(home: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["CSWAP_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        self.home = home ?? URL(fileURLWithPath: override ?? NSHomeDirectory())
    }

    /// `~/.cswap`. Installs from before the rename keep `~/.claude-seats`:
    /// moving a seat folder would change its Keychain item and log it out.
    public var root: URL {
        let current = home.appendingPathComponent(".cswap")
        let legacy = home.appendingPathComponent(".claude-seats")
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }

    public var usesLegacyRoot: Bool { root.lastPathComponent == ".claude-seats" }
    public var mainSeat: Seat { Seat(slug: Seat.mainSlug, configDir: home.appendingPathComponent(".claude")) }
    private var defaultFileURL: URL { root.appendingPathComponent(".default") }

    private var fileManager: FileManager { .default }

    // MARK: - Listing

    /// `main` first, then the other seats alphabetically.
    public func seats() -> [Seat] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let others = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter(Seat.isValidSlug)
            .sorted()
            .map { Seat(slug: $0, configDir: root.appendingPathComponent($0)) }
        return [mainSeat] + others
    }

    public func seat(named slug: String) -> Seat? {
        seats().first { $0.slug == slug }
    }

    // MARK: - Default seat

    /// The seat plain `claude` starts when the shell integration is active.
    public func defaultSeat() -> Seat {
        readDefaultSlug().flatMap(seat(named:)) ?? mainSeat
    }

    private func readDefaultSlug() -> String? {
        (try? String(contentsOf: defaultFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setDefault(_ seat: Seat) throws {
        try ensureRoot()
        try Data((seat.slug + "\n").utf8).write(to: defaultFileURL, options: .atomic)
    }

    // MARK: - Create / remove

    @discardableResult
    public func create(slug: String) throws -> Seat {
        guard Seat.isValidSlug(slug) else { throw SeatError.invalidSlug(slug) }
        let seat = Seat(slug: slug, configDir: root.appendingPathComponent(slug))
        guard !fileManager.fileExists(atPath: seat.configDir.path) else { throw SeatError.alreadyExists(slug) }
        try ensureRoot()
        try fileManager.createDirectory(
            at: seat.configDir, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try sync(seat)
        return seat
    }

    /// Deletes the seat directory and the seat's own Keychain item. Shared
    /// data (projects, memory, settings) lives in `~/.claude` and is kept.
    public func remove(_ seat: Seat) throws {
        guard !seat.isMain else { throw SeatError.cannotRemoveMain }
        guard fileManager.fileExists(atPath: seat.configDir.path) else { throw SeatError.notFound(seat.slug) }
        SeatCredentialReader().deleteKeychainItem(for: seat)
        try fileManager.removeItem(at: seat.configDir)
        if readDefaultSlug() == seat.slug {
            try? fileManager.removeItem(at: defaultFileURL)
        }
    }


    func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Sync shared state into a seat

    public struct SyncReport: Sendable {
        public var linked: [String] = []
        /// Shared items the seat already has as a real file or folder; left
        /// alone so nothing is ever deleted.
        public var conflicts: [String] = []
        public var updatedConfig = false
    }

    /// Links new shared items from `~/.claude` and copies MCP servers and
    /// project trust from the main `.claude.json`. Safe to run on every launch.
    public func sync(_ seat: Seat) throws -> SyncReport {
        var report = SyncReport()
        guard !seat.isMain else { return report }

        for name in sharedItemNames() {
            let target = mainSeat.configDir.appendingPathComponent(name)
            let link = seat.configDir.appendingPathComponent(name)

            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if destination == target.path { continue }
                report.conflicts.append(name)
                continue
            }
            if fileManager.fileExists(atPath: link.path) {
                // Claude Code may create an empty folder before the link
                // exists; that one is safe to replace.
                if isEmptyDirectory(link) {
                    try fileManager.removeItem(at: link)
                } else {
                    report.conflicts.append(name)
                    continue
                }
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            report.linked.append(name)
        }

        report.updatedConfig = try syncClaudeJSON(into: seat)
        return report
    }

    private func sharedItemNames() -> [String] {
        let mainDir = mainSeat.configDir
        let topLevel = (try? fileManager.contentsOfDirectory(atPath: mainDir.path)) ?? []
        let markdown = topLevel.filter { $0.hasSuffix(".md") }
        return (Self.sharedDirectories + Self.sharedFiles + markdown).filter {
            fileManager.fileExists(atPath: mainDir.appendingPathComponent($0).path)
        }
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true
    }

    /// Merges the shared keys into the seat's `.claude.json`, under Claude
    /// Code's own advisory lock. Never touches `oauthAccount`.
    private func syncClaudeJSON(into seat: Seat) throws -> Bool {
        guard let main = readJSON(mainSeat.claudeJSONURL) else { return false }

        let lock = DirectoryLock(url: URL(fileURLWithPath: seat.claudeJSONURL.path + ".lock"))
        try lock.acquire()
        defer { lock.release() }

        let original = readJSON(seat.claudeJSONURL) ?? [:]
        var merged = original

        // Main wins on conflicts, but nothing a seat added itself is dropped.
        for key in Self.sharedTopLevelKeys {
            guard let mainValue = main[key] else { continue }
            if let mainDict = mainValue as? [String: Any], let seatDict = merged[key] as? [String: Any] {
                merged[key] = seatDict.merging(mainDict) { _, fromMain in fromMain }
            } else {
                merged[key] = mainValue
            }
        }
        if let mainProjects = main["projects"] as? [String: Any] {
            var projects = merged["projects"] as? [String: Any] ?? [:]
            for (path, value) in mainProjects {
                guard let mainProject = value as? [String: Any] else { continue }
                var project = projects[path] as? [String: Any] ?? [:]
                for key in Self.sharedProjectKeys {
                    if let mainValue = mainProject[key] { project[key] = mainValue }
                }
                projects[path] = project
            }
            merged["projects"] = projects
        }

        guard !NSDictionary(dictionary: merged).isEqual(to: original) else { return false }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: seat.claudeJSONURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seat.claudeJSONURL.path)
        return true
    }

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Seat state

    public func profile(of seat: Seat) -> SeatProfile? {
        guard let root = readJSON(seat.claudeJSONURL),
              let account = root["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String else { return nil }
        return SeatProfile(email: email, organizationName: account["organizationName"] as? String)
    }

    /// Number of live Claude Code processes in this seat. Claude Code keeps
    /// per-process files under `<config>/sessions` named `<pid>.json` or
    /// `<pid>.<hash>.key`; the PID prefix is what counts.
    public func runningSessionCount(of seat: Seat) -> Int {
        let dir = seat.configDir.appendingPathComponent("sessions")
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        let pids = Set(names.compactMap { name in
            name.split(separator: ".", maxSplits: 1).first.flatMap { Int32($0) }
        })
        return pids.filter { $0 > 1 && kill($0, 0) == 0 }.count
    }

    /// Live Claude Code sessions in this seat, newest first, from the
    /// `<pid>.json` records Claude Code keeps under `<config>/sessions`.
    public func runningSessions(of seat: Seat) -> [RunningSession] {
        let dir = seat.configDir.appendingPathComponent("sessions")
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> RunningSession? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      var session = try? JSONDecoder().decode(RunningSession.self, from: data),
                      session.pid > 1, kill(session.pid, 0) == 0 else { return nil }
                session.seatSlug = seat.slug
                return session
            }
            .sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    // MARK: - Session handoff

    public var handoffDirectory: URL { root.appendingPathComponent(".handoff") }

    /// Leaves the next `cswap run` arguments for the `claude()` wrapper of
    /// the shell `shellPID`, which picks them up once Claude Code exits.
    public func writeHandoff(shellPID: Int32, arguments: [String]) throws {
        try fileManager.createDirectory(at: handoffDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = handoffDirectory.appendingPathComponent(String(shellPID))
        try Data((arguments.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }

    // MARK: - /swap command

    public var swapCommandURL: URL {
        mainSeat.configDir.appendingPathComponent("commands/swap.md")
    }

    private static let swapCommandMarker = "<!-- managed by cswap -->"
    /// Written by versions from before the rename.
    private static let legacySwapCommandMarker = "<!-- managed by cseat -->"

    /// Installs `/swap` as a user command. It runs `cswap move` while the
    /// command expands, before anything is sent to the model, so it works
    /// even when the current account is out of quota. `commands/` is shared,
    /// so every seat gets it. A hand-written swap.md is left alone.
    @discardableResult
    public func installSwapCommand() throws -> Bool {
        let url = swapCommandURL
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.contains(Self.swapCommandMarker), !existing.contains(Self.legacySwapCommandMarker) {
            return false
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let command = """
        ---
        description: Continue this conversation with another account
        argument-hint: "[account]"
        allowed-tools: Bash(cswap move:*)
        ---
        \(Self.swapCommandMarker)
        !`cswap move $ARGUMENTS`

        """
        try Data(command.utf8).write(to: url, options: .atomic)
        return true
    }
}
