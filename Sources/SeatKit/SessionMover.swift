import Darwin
import Foundation

/// Moves a running Claude Code session to another seat: the running process
/// ends and the same conversation resumes in the target seat.
///
/// No credential is touched. Transcripts are shared between seats, so
/// `claude --resume <id>` in the target seat picks up the conversation.
public struct SessionMover {

    public enum MoveError: LocalizedError {
        case notInSession
        case noClaudeProcess
        case sameSeat(String)
        case notLoggedIn(String)
        case sameAccount(String, String)
        case noOtherSeat

        public var errorDescription: String? {
            switch self {
            case .notInSession:
                return "Run this inside a Claude Code session: type /swap there (or !cseat move <name>)."
            case .noClaudeProcess:
                return "Couldn't find the Claude Code process of this session."
            case let .sameSeat(slug):
                return "This session already runs with \(slug)."
            case let .sameAccount(slug, email):
            return "\(slug) is logged in to the same account (\(email)), so there's nothing to switch to. Log it in with its own account: cseat login \(slug) --email <address>"
        case let .notLoggedIn(slug):
                return "\(slug) isn't logged in yet. Run: cseat login \(slug)"
            case .noOtherSeat:
                return "There's no other logged-in account to move to. Add one with: cseat add <name>"
            }
        }
    }

    /// How the session continues after the old process ends.
    public enum Handoff {
        /// The zsh `claude()` wrapper in the same terminal tab restarts it.
        case sameTab
        /// A new terminal window resumes it (sessions started without the wrapper).
        case newWindow
    }

    public let store: SeatStore
    public let environment: [String: String]

    public init(store: SeatStore = SeatStore(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        self.environment = environment
    }

    /// The seat the calling session runs in, from its inherited environment.
    public func currentSeat() -> Seat {
        guard let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty else { return store.mainSeat }
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        return store.seats().first { $0.configDir.path == path } ?? store.mainSeat
    }

    /// The named seat, or else the default seat, or else the logged-in seat
    /// with the most room left — never the current one.
    public func target(named slug: String?, usage: [String: UsageSnapshot]) throws -> Seat {
        let current = currentSeat()
        let reader = SeatCredentialReader()
        if let slug {
            guard let seat = store.seat(named: slug) else { throw SeatStore.SeatError.notFound(slug) }
            guard seat != current else { throw MoveError.sameSeat(slug) }
            guard reader.credentials(for: seat) != nil else { throw MoveError.notLoggedIn(slug) }
            return seat
        }
        let currentEmail = store.profile(of: current)?.email
        let candidates = store.seats().filter { seat in
            guard seat != current, reader.credentials(for: seat) != nil else { return false }
            guard let currentEmail, let email = store.profile(of: seat)?.email else { return true }
            return email.caseInsensitiveCompare(currentEmail) != .orderedSame
        }
        let defaultSeat = store.defaultSeat()
        if candidates.contains(defaultSeat) { return defaultSeat }
        let best = candidates.max { headroom(usage[$0.slug]) < headroom(usage[$1.slug]) }
        guard let best else { throw MoveError.noOtherSeat }
        return best
    }

    private func headroom(_ snapshot: UsageSnapshot?) -> Double {
        snapshot?.headroom ?? -1
    }

    /// Refuses a move between two seats logged in to the same claude.ai
    /// account — it would restart the session on the same quota.
    public func checkDifferentAccount(_ target: Seat, from source: Seat? = nil) throws {
        let current = source ?? currentSeat()
        guard let mine = store.profile(of: current)?.email,
              let theirs = store.profile(of: target)?.email,
              mine.caseInsensitiveCompare(theirs) == .orderedSame else { return }
        throw MoveError.sameAccount(target.slug, theirs)
    }

    /// Ends this session's Claude Code process and resumes the conversation
    /// in `target`. `cseatPath` is used for the new-window fallback.
    public func move(to target: Seat, cseatPath: String) throws -> Handoff {
        try checkDifferentAccount(target)
        guard let sessionID = environment["CLAUDE_CODE_SESSION_ID"], !sessionID.isEmpty else {
            throw MoveError.notInSession
        }
        guard let claude = ProcessTable.current().claudeAncestor(of: getpid()) else {
            throw MoveError.noClaudeProcess
        }
        return try handOff(
            claude: claude, sessionID: sessionID,
            shellPID: environment["CSEAT_SHELL_PID"].flatMap(Int32.init),
            workingDirectory: ProcessTable.workingDirectory(of: claude.pid),
            to: target, cseatPath: cseatPath
        )
    }

    /// Moves a session from outside it, as the menu bar app does. The
    /// handoff is the same as `/swap`: the tab's `claude()` wrapper restarts
    /// it when the wrapper started it, otherwise a new window resumes it.
    public func move(_ session: RunningSession, to target: Seat, cseatPath: String) throws -> Handoff {
        guard let source = store.seat(named: session.seatSlug) else {
            throw SeatStore.SeatError.notFound(session.seatSlug)
        }
        guard source != target else { throw MoveError.sameSeat(target.slug) }
        guard SeatCredentialReader().credentials(for: target) != nil else { throw MoveError.notLoggedIn(target.slug) }
        try checkDifferentAccount(target, from: source)
        // The record can outlive its process and the PID can be reused;
        // only ever signal a Claude Code process.
        guard let claude = ProcessTable.current().entries[session.pid], claude.isClaude else {
            throw MoveError.noClaudeProcess
        }
        return try handOff(
            claude: claude, sessionID: session.sessionId,
            shellPID: ProcessTable.environment(of: claude.pid)["CSEAT_SHELL_PID"].flatMap(Int32.init),
            workingDirectory: session.cwd ?? ProcessTable.workingDirectory(of: claude.pid),
            to: target, cseatPath: cseatPath
        )
    }

    /// How `move(_:to:cseatPath:)` would continue `session`.
    public func handoffKind(for session: RunningSession) -> Handoff {
        guard let claude = ProcessTable.current().entries[session.pid],
              let shellPID = ProcessTable.environment(of: session.pid)["CSEAT_SHELL_PID"].flatMap(Int32.init),
              claude.ppid == shellPID else { return .newWindow }
        return .sameTab
    }

    private func handOff(
        claude: ProcessTable.Entry, sessionID: String, shellPID: Int32?,
        workingDirectory: String?, to target: Seat, cseatPath: String
    ) throws -> Handoff {
        let resume = ["--resume", sessionID]

        let handoff: Handoff
        if let shellPID, claude.ppid == shellPID {
            try store.writeHandoff(shellPID: shellPID, arguments: [target.slug, "--"] + resume)
            handoff = .sameTab
        } else {
            // Give the old process a moment to exit before the transcript is
            // reopened. Run through the shell integration when it exists, so
            // a later /swap in that window stays in the same tab.
            let next = ([target.slug, "--"] + resume).map(TerminalLauncher.shellQuoted).joined(separator: " ")
            let command = "sleep 2; if typeset -f _cseat_session >/dev/null; then _cseat_session \(next); "
                + "else \(TerminalLauncher.shellQuoted(cseatPath)) run \(next); fi"
            try TerminalLauncher.run(command, workingDirectory: workingDirectory)
            handoff = .newWindow
        }

        kill(claude.pid, SIGTERM)
        return handoff
    }
}

/// A snapshot of `ps`, enough to walk up from this process to its Claude Code.
struct ProcessTable {
    struct Entry {
        let pid: Int32
        let ppid: Int32
        let argv0: String

        var isClaude: Bool {
            (argv0 as NSString).lastPathComponent == "claude" || argv0.contains("/claude/versions/")
        }
    }

    let entries: [Int32: Entry]

    static func current() -> ProcessTable {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,args="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ProcessTable(entries: [:]) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var entries: [Int32: Entry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            let argv0 = fields[2].split(separator: " ").first.map(String.init) ?? ""
            entries[pid] = Entry(pid: pid, ppid: ppid, argv0: argv0)
        }
        return ProcessTable(entries: entries)
    }

    /// Current directory of `pid`, or nil when macOS won't say.
    static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Environment of another process of this user, from `KERN_PROCARGS2`:
    /// argc, the executable path, padding, argv, then the environment.
    static func environment(of pid: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func skipString() { while index < size, buffer[index] != 0 { index += 1 } }
        func skipNULs() { while index < size, buffer[index] == 0 { index += 1 } }

        skipString()
        skipNULs()
        for _ in 0..<max(argc, 0) {
            skipString()
            index += 1
        }

        var env: [String: String] = [:]
        while index < size, buffer[index] != 0 {
            let start = index
            skipString()
            let entry = String(decoding: buffer[start..<index], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index += 1
        }
        return env
    }

    /// Nearest ancestor that is a Claude Code CLI process.
    func claudeAncestor(of pid: Int32) -> Entry? {
        var current = entries[pid]?.ppid
        var hops = 0
        while let pid = current, pid > 1, hops < 32 {
            guard let entry = entries[pid] else { return nil }
            if entry.isClaude { return entry }
            current = entry.ppid
            hops += 1
        }
        return nil
    }
}
