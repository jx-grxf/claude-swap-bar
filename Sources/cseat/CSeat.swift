import Foundation
import SeatKit

/// `cseat` — run Claude Code with several accounts side by side.
@main
struct CSeat {
    static let store = SeatStore()

    static let usage = """
    Usage:
      cseat                          List accounts, usage and the default
      cseat <name> [claude args…]    Start Claude Code with that account
      cseat use <name>               Make <name> the default for plain `claude`
      cseat best                     Make the account with the most 5h headroom the default
      cseat move [name]              Inside a session (/swap): continue it with another account
      cseat add <name> [--email e]   Create an account and log it in
      cseat login <name> [--email e] Log an account in again
      cseat remove <name> [--yes]    Delete an account and its login
      cseat sync                     Re-link shared settings, skills and memory
      cseat setup                    Install the shell integration for `claude`
      cseat doctor                   Check every account

    The main account is your normal ~/.claude. Other accounts live in
    ~/.claude-seats/<name> and share settings, skills, plugins, hooks, memory
    and transcripts with it. Each keeps its own login.
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "list" : args.removeFirst()

        do {
            switch command {
            case "list", "ls", "status":
                await list(force: args.contains("--refresh"))
            case "use":
                try use(try requireSeat(args.first))
            case "best":
                try await best()
            case "move", "swap":
                try move(args.first.flatMap { $0.hasPrefix("-") ? nil : $0 })
            case "add":
                try add(args)
            case "login":
                try login(try requireSeat(args.first), email: option("--email", in: args))
            case "remove", "rm":
                try remove(try requireSeat(args.first), confirmed: args.contains("--yes") || args.contains("-y"))
            case "sync":
                sync()
            case "setup":
                try setup()
            case "doctor":
                doctor()
            case "run":
                try run(args)
            case "help", "-h", "--help":
                print(usage)
            default:
                guard let seat = store.seat(named: command) else {
                    fail("Unknown command or account \u{201C}\(command)\u{201D}.\n\n\(usage)")
                }
                try launch(seat, arguments: args)
            }
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: - Commands

    static func list(force: Bool) async {
        let seats = store.seats()
        let defaultSlug = store.defaultSeat().slug
        var cache = UsageCache.load()
        let fetcher = SeatUsageFetcher()

        let results = await withTaskGroup(of: (String, UsageSnapshot?, UsageProblem?).self) { group in
            for seat in seats {
                let cached = cache[seat.slug]
                group.addTask {
                    let (snapshot, problem) = await fetcher.fetch(seat, cached: cached, force: force)
                    return (seat.slug, snapshot, problem)
                }
            }
            var out: [String: (UsageSnapshot?, UsageProblem?)] = [:]
            for await (slug, snapshot, problem) in group { out[slug] = (snapshot, problem) }
            return out
        }
        for (slug, result) in results { cache[slug] = result.0 }
        UsageCache.save(cache)

        let reader = SeatCredentialReader()
        let nameWidth = max(seats.map(\.slug.count).max() ?? 4, 4)
        for seat in seats {
            let isDefault = seat.slug == defaultSlug
            let marker = isDefault ? Style.green("●") : " "
            let name = seat.slug.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let credentials = reader.credentials(for: seat)
            let email = credentials == nil ? Style.dim("not logged in") : store.profile(of: seat)?.email ?? Style.dim("not logged in")
            let plan = credentials?.planLabel.map { Style.dim(" \($0)") } ?? ""
            let sessions = store.runningSessionCount(of: seat)
            let running = sessions > 0 ? Style.dim("  \(sessions) running") : ""
            print("\(marker) \(Style.bold(name))  \(email)\(plan)\(running)")

            let (snapshot, problem) = results[seat.slug] ?? (nil, nil)
            let indent = String(repeating: " ", count: nameWidth + 4)
            if let five = snapshot?.fiveHour { print(indent + bar("5h", five)) }
            if let seven = snapshot?.sevenDay { print(indent + bar("7d", seven)) }
            if let problem { print(indent + Style.dim(problem.shortText)) }
        }
        if store.seats().count == 1 {
            print(Style.dim("\nOnly the main account so far. Add one with: cseat add <name>"))
        }
    }

    static func use(_ seat: Seat) throws {
        try store.setDefault(seat)
        let who = store.profile(of: seat)?.email ?? "not logged in yet"
        print("Default is now \(Style.bold(seat.slug)) (\(who)). New `claude` sessions use it.")
        print("  To move a running session, type \(Style.bold("/swap")) in it. Don't use /login there: that replaces the login of the session's own account.")
    }

    static func best() async throws {
        let cache = UsageCache.load()
        let fetcher = SeatUsageFetcher()
        var bestSeat: Seat?
        var bestHeadroom = -1.0
        for seat in store.seats() where store.profile(of: seat) != nil {
            let (snapshot, _) = await fetcher.fetch(seat, cached: cache[seat.slug])
            UsageCache.update(seat.slug, snapshot)
            guard let five = snapshot?.fiveHour else { continue }
            let headroom = 100 - five.utilization
            if headroom > bestHeadroom {
                bestHeadroom = headroom
                bestSeat = seat
            }
        }
        guard let bestSeat else { fail("No account has usage data yet.") }
        try use(bestSeat)
    }

    /// Ends the calling Claude Code session and resumes the same
    /// conversation in another seat — in the same terminal tab when the
    /// shell integration started it, otherwise in a new window.
    static func move(_ slug: String?) throws {
        let mover = SessionMover(store: store)
        let target = try mover.target(named: slug, usage: UsageCache.load())
        let who = store.profile(of: target)?.email ?? target.slug
        let handoff = try mover.move(to: target, cseatPath: stableCLIPath())
        switch handoff {
        case .sameTab:
            print("Continuing this conversation with \(who) (\(target.slug))…")
        case .newWindow:
            print("Continuing this conversation with \(who) (\(target.slug)) in a new terminal window…")
        }
    }

    /// `~/.local/bin/cseat` when it exists, else this binary.
    static func stableCLIPath() -> String {
        let linked = store.home.appendingPathComponent(".local/bin/cseat").path
        if FileManager.default.isExecutableFile(atPath: linked) { return linked }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    static func add(_ args: [String]) throws {
        guard let slug = args.first, !slug.hasPrefix("-") else { fail("Usage: cseat add <name> [--email address]") }
        let seat = try store.create(slug: slug)
        print("Created \(Style.bold(slug)) in \(seat.configDir.path)")
        try login(seat, email: option("--email", in: args))
    }

    static func login(_ seat: Seat, email: String?) throws {
        _ = try? store.sync(seat)

        // `claude auth login` waits silently for the browser when a login
        // already exists; the interactive /login screen always shows the link.
        print("Starting Claude Code for \(Style.bold(seat.slug)) on its login screen.")
        print("  1. Choose \u{201C}Claude account with subscription\u{201D}.")
        print("  2. In the browser, sign in as \(Style.bold(email ?? "the account you want")). Wrong account there? Use a private window.")
        print("  3. When it says Login successful, quit with /exit.")
        fflush(stdout)

        // Ctrl-C belongs to Claude Code while it runs.
        signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, SIG_DFL) }
        try ClaudeLauncher.run(seat: seat, arguments: ["/login"])

        guard let profile = store.profile(of: seat), SeatCredentialReader().credentials(for: seat) != nil else {
            fail("Login didn't finish. Try again with: cseat login \(seat.slug)")
        }
        print(Style.green("✓ ") + "\(seat.slug) is logged in as \(profile.email).")

        // The browser authorizes whichever claude.ai account it is signed in
        // to, which is easy to get wrong with several accounts.
        if let email, email.caseInsensitiveCompare(profile.email) != .orderedSame {
            print(Style.yellow("! Expected \(email). Switch the claude.ai account in your browser (or use a private window), then run: cseat login \(seat.slug)"))
        }
        for other in store.seats() where other != seat && store.profile(of: other)?.email.caseInsensitiveCompare(profile.email) == .orderedSame
            && SeatCredentialReader().credentials(for: other) != nil {
            print(Style.yellow("! \(other.slug) uses the same account. Log in with a different claude.ai account: cseat login \(seat.slug)"))
        }
        print("  Start it with \(Style.bold("cseat \(seat.slug)")), or make it the default with \(Style.bold("cseat use \(seat.slug)")).")
    }

    static func remove(_ seat: Seat, confirmed: Bool) throws {
        if !confirmed {
            let who = store.profile(of: seat)?.email ?? "no login"
            print("Remove \(seat.slug) (\(who)) and its login? Shared memory and settings stay. [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("Kept.")
                return
            }
        }
        try store.remove(seat)
        UsageCache.update(seat.slug, nil)
        print("Removed \(seat.slug).")
    }

    static func sync() {
        for seat in store.seats() where !seat.isMain {
            do {
                let report = try store.sync(seat)
                var parts: [String] = []
                if !report.linked.isEmpty { parts.append("linked \(report.linked.joined(separator: ", "))") }
                if report.updatedConfig { parts.append("updated MCP servers and project trust") }
                if !report.conflicts.isEmpty {
                    parts.append(Style.yellow("kept own copy of \(report.conflicts.joined(separator: ", "))"))
                }
                print("\(seat.slug): \(parts.isEmpty ? "up to date" : parts.joined(separator: "; "))")
            } catch {
                print("\(seat.slug): \(Style.yellow((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
            }
        }
    }

    static func setup() throws {
        let home = store.home.path
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let binDir = "\(home)/.local/bin"
        let linkPath = "\(binDir)/cseat"

        // A stable path survives app updates; point it at this binary.
        let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        if ownPath != linkPath, existing != ownPath {
            try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            if existing != nil { try FileManager.default.removeItem(atPath: linkPath) }
            if FileManager.default.fileExists(atPath: linkPath) {
                print(Style.yellow("Left the existing \(linkPath) alone; it isn't a link."))
            } else {
                try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: ownPath)
                print("Linked \(linkPath) → \(ownPath)")
            }
        }

        try store.writeShellInit(cseatPath: linkPath)
        print("Wrote \(store.shellInitURL.path)")
        if try store.installSwapCommand() {
            print("Installed /swap (\(store.swapCommandURL.path))")
        } else {
            print(Style.yellow("Left your own \(store.swapCommandURL.path) alone; /swap isn't managed by cseat."))
        }

        let zshrc = URL(fileURLWithPath: "\(home)/.zshrc")
        let current = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        if current.contains(SeatStore.shellSourceLine) {
            print("~/.zshrc already sources it.")
        } else {
            let addition = (current.hasSuffix("\n") || current.isEmpty ? "" : "\n")
                + "\n# Claude Swap Bar: plain `claude` starts the default account\n"
                + SeatStore.shellSourceLine + "\n"
            let handle = try FileHandle(forWritingTo: zshrc)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(addition.utf8))
            try handle.close()
            print("Added the integration to ~/.zshrc. Open a new terminal to use it.")
        }
    }

    static func doctor() {
        var ok = true
        func check(_ passed: Bool, _ text: String) {
            print((passed ? Style.green("✓ ") : Style.yellow("! ")) + text)
            if !passed { ok = false }
        }

        let claude = ClaudeLauncher.claudeExecutable()
        check(claude != nil, "claude: \(claude ?? "not found")")
        let zshrc = (try? String(contentsOfFile: store.home.path + "/.zshrc", encoding: .utf8)) ?? ""
        check(zshrc.contains(SeatStore.shellSourceLine) && FileManager.default.fileExists(atPath: store.shellInitURL.path),
              "shell integration " + (zshrc.contains(SeatStore.shellSourceLine) ? "installed" : "missing — run: cseat setup"))
        check(ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
              "CLAUDE_CODE_OAUTH_TOKEN " + (ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil
                  ? "not set" : "is set and overrides every account login — remove it"))
        print("  default: \(store.defaultSeat().slug)")

        let reader = SeatCredentialReader()
        var emails: [String: String] = [:]
        for seat in store.seats() {
            let profile = store.profile(of: seat)
            let credentials = reader.credentials(for: seat)
            let state: String
            switch (profile, credentials) {
            case let (profile?, credentials?):
                state = "\(profile.email)\(credentials.planLabel.map { " (\($0))" } ?? "")"
            case (_, nil):
                state = "no login in Keychain item \u{201C}\(seat.keychainService)\u{201D}"
            case (nil, _):
                state = "login present but no profile in \(seat.claudeJSONURL.path)"
            }
            check(profile != nil && credentials != nil, "\(seat.slug): \(state)")
            if credentials != nil, let email = profile?.email {
                if let other = emails[email.lowercased()] {
                    check(false, "\(seat.slug) and \(other) use the same account \(email). Log the wrong one in again: cseat login <name> --email <address>")
                }
                emails[email.lowercased()] = seat.slug
            }
            if !seat.isMain, let report = try? store.sync(seat), !report.conflicts.isEmpty {
                check(false, "\(seat.slug): has its own copy of \(report.conflicts.joined(separator: ", ")) instead of the shared one")
            }
        }
        exit(ok ? 0 : 1)
    }

    /// Entry point for the shell integration: `cseat run --default -- args`
    /// or `cseat run <name> -- args`.
    static func run(_ args: [String]) throws {
        guard let selector = args.first else { fail("Usage: cseat run --default|<name> [-- claude args…]") }
        var rest = Array(args.dropFirst())
        if rest.first == "--" { rest.removeFirst() }
        let seat = selector == "--default" ? store.defaultSeat() : try requireSeat(selector)
        try launch(seat, arguments: rest)
    }

    static func launch(_ seat: Seat, arguments: [String]) throws -> Never {
        if !seat.isMain {
            do {
                _ = try store.sync(seat)
            } catch {
                FileHandle.standardError.write(Data("cseat: couldn't sync \(seat.slug): \(error.localizedDescription)\n".utf8))
            }
        }
        try ClaudeLauncher.exec(seat: seat, arguments: arguments)
    }

    // MARK: - Helpers

    static func requireSeat(_ slug: String?) throws -> Seat {
        guard let slug else { fail("Name an account. Accounts: \(store.seats().map(\.slug).joined(separator: ", "))") }
        guard let seat = store.seat(named: slug) else { throw SeatStore.SeatError.notFound(slug) }
        return seat
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func bar(_ label: String, _ window: UsageWindow) -> String {
        let width = 20
        let filled = Int((window.fraction * Double(width)).rounded())
        let blocks = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let percent = String(format: "%3d%%", Int(window.utilization.rounded()))
        let colored = window.utilization >= 90 ? Style.red(blocks) : window.utilization >= 70 ? Style.yellow(blocks) : Style.green(blocks)
        return "\(label) \(colored) \(percent)  \(Style.dim(window.resetText ?? ""))"
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("cseat: \(message)\n".utf8))
        exit(1)
    }
}

enum Style {
    static let enabled = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap("1", text) }
    static func dim(_ text: String) -> String { wrap("2", text) }
    static func green(_ text: String) -> String { wrap("32", text) }
    static func yellow(_ text: String) -> String { wrap("33", text) }
    static func red(_ text: String) -> String { wrap("31", text) }
}
