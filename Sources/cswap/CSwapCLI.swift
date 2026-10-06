import CSwapKit
import Foundation

/// `cswap` — run several Claude Code accounts side by side.
@main
struct CSwapCLI {
    static let store = SeatStore()

    static var usage: String {
        func section(_ title: String, _ rows: [(String, String)]) -> String {
            let width = 32
            let lines = rows.map { command, text in
                "  " + Style.bold(command.padding(toLength: width, withPad: " ", startingAt: 0)) + text
            }
            return Style.dim(title) + "\n" + lines.joined(separator: "\n")
        }
        return [
            "\(Style.bold("cswap")) — run several Claude Code accounts side by side",
            section("START", [
                ("cswap", "Show every account with its usage"),
                ("cswap <account> [args…]", "Start Claude Code with that account"),
                ("claude [args…]", "Start the default account (after setup)"),
            ]),
            section("ACCOUNTS", [
                ("cswap add <name> [--email a]", "Create an account and log it in"),
                ("cswap login <name> [--email a]", "Log an account in again"),
                ("cswap use <name>", "Make it the default for new sessions"),
                ("cswap best", "Make the account with the most quota left the default"),
                ("cswap remove <name> [--yes]", "Delete an account and its login"),
            ]),
            section("SESSIONS", [
                ("/swap [account]", "Inside a session: continue with another account"),
                ("cswap sessions", "List running sessions per account"),
                ("cswap move <name> --pid <pid>", "Move a running session to another account"),
            ]),
            section("SETUP", [
                ("cswap setup [--yes]", "One-time guided setup"),
                ("cswap doctor", "Check the setup and every account"),
                ("cswap sync", "Re-link shared settings, skills and memory"),
                ("cswap version", "Print the version"),
            ]),
            Style.dim("""
            The main account is your normal ~/.claude. Every other account lives in
            \(abbreviate(store.root.path))/<name>, keeps its own login and shares settings,
            skills, plugins, hooks, memory and transcripts with main.
            """),
        ].joined(separator: "\n\n")
    }

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
                let name = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
                if let pid = option("--pid", in: args) {
                    try move(pid: pid, to: name)
                } else {
                    try move(name)
                }
            case "sessions":
                sessions()
            case "add":
                try add(args)
            case "login":
                try login(try requireSeat(args.first), email: option("--email", in: args))
            case "remove", "rm":
                try remove(try requireSeat(args.first), confirmed: args.contains("--yes") || args.contains("-y"))
            case "sync":
                sync()
            case "setup":
                try await setup(interactive: !(args.contains("--yes") || args.contains("-y")) && isatty(STDIN_FILENO) == 1)
            case "doctor":
                doctor()
            case "run":
                try run(args)
            case "version", "--version", "-v":
                print("cswap \(version)")
            case "help", "-h", "--help":
                print(usage)
            default:
                guard let seat = store.seat(named: command) else {
                    fail("No account or command named \u{201C}\(command)\u{201D}. Accounts: \(store.seats().map(\.slug).joined(separator: ", ")). See: cswap help")
                }
                try launch(seat, arguments: args)
            }
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: - Accounts

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
        let indent = String(repeating: " ", count: nameWidth + 4)
        for seat in seats {
            let isDefault = seat.slug == defaultSlug
            let marker = isDefault ? Style.green("●") : " "
            let name = seat.slug.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let credentials = reader.credentials(for: seat)
            let email = credentials == nil ? Style.dim("not logged in") : store.profile(of: seat)?.email ?? Style.dim("not logged in")
            let plan = credentials?.planLabel.map { " " + Style.cyan($0) } ?? ""
            let sessions = store.runningSessions(of: seat).count
            let running = sessions > 0 ? Style.dim("  \(sessions) running") : ""
            let badge = isDefault ? Style.dim("  default") : ""
            print("\(marker) \(Style.bold(name))  \(email)\(plan)\(badge)\(running)")

            let (snapshot, problem) = results[seat.slug] ?? (nil, nil)
            if let five = snapshot?.fiveHour { print(indent + bar("5h", five)) }
            if let seven = snapshot?.sevenDay { print(indent + bar("7d", seven)) }
            if let problem { print(indent + Style.dim(problem.shortText)) }
        }
        if seats.count == 1 {
            print(Style.dim("\nOnly the main account so far. Add one with: cswap add <name>"))
        } else if !ShellIntegration(store: store).isInstalled {
            print(Style.dim("\nTip: run cswap setup once so plain `claude` follows the default and /swap works."))
        }
    }

    static func use(_ seat: Seat) throws {
        try store.setDefault(seat)
        let who = store.profile(of: seat)?.email ?? "not logged in yet"
        print(Style.green("✓ ") + "New sessions use \(Style.bold(seat.slug)) (\(who)).")
        print(Style.dim("  Running sessions keep their account; move one with /swap inside it. Don't use /login there."))
    }

    static func best() async throws {
        let cache = UsageCache.load()
        let fetcher = SeatUsageFetcher()
        var bestSeat: Seat?
        var bestHeadroom = -1.0
        for seat in store.seats() where store.profile(of: seat) != nil {
            let (snapshot, _) = await fetcher.fetch(seat, cached: cache[seat.slug])
            UsageCache.update(seat.slug, snapshot)
            guard let headroom = snapshot?.headroom else { continue }
            if headroom > bestHeadroom {
                bestHeadroom = headroom
                bestSeat = seat
            }
        }
        guard let bestSeat else { fail("No account has usage data yet.") }
        try use(bestSeat)
    }

    static func add(_ args: [String]) throws {
        guard let slug = args.first, !slug.hasPrefix("-") else { fail("Usage: cswap add <name> [--email address]") }
        let seat = try store.create(slug: slug)
        print(Style.green("✓ ") + "Created \(Style.bold(slug)) in \(abbreviate(seat.configDir.path))")
        try login(seat, email: option("--email", in: args))
    }

    static func login(_ seat: Seat, email: String?) throws {
        guard loginFlow(seat, email: email) else {
            fail("Login didn't finish. Try again with: cswap login \(seat.slug)")
        }
        print("  Start it with \(Style.bold("cswap \(seat.slug)")), or make it the default with \(Style.bold("cswap use \(seat.slug)")).")
    }

    /// Opens Claude Code's own login screen in `seat` and checks the result.
    /// Returns whether the seat ended up logged in.
    @discardableResult
    static func loginFlow(_ seat: Seat, email: String?) -> Bool {
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
        do {
            try ClaudeLauncher.run(seat: seat, arguments: ["/login"])
        } catch {
            print(Style.yellow("! ") + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return false
        }

        guard let profile = store.profile(of: seat), SeatCredentialReader().credentials(for: seat) != nil else {
            return false
        }
        print(Style.green("✓ ") + "\(seat.slug) is logged in as \(profile.email).")

        // The browser authorizes whichever claude.ai account it is signed in
        // to, which is easy to get wrong with several accounts.
        if let email, email.caseInsensitiveCompare(profile.email) != .orderedSame {
            print(Style.yellow("! Expected \(email). Switch the account in your browser (or use a private window), then run: cswap login \(seat.slug)"))
        }
        for other in store.seats() where other != seat && store.profile(of: other)?.email.caseInsensitiveCompare(profile.email) == .orderedSame
            && SeatCredentialReader().credentials(for: other) != nil {
            print(Style.yellow("! \(other.slug) uses the same account. Log in with a different account: cswap login \(seat.slug)"))
        }
        return true
    }

    static func remove(_ seat: Seat, confirmed: Bool) throws {
        if !confirmed {
            let who = store.profile(of: seat)?.email ?? "no login"
            guard ask("Remove \(seat.slug) (\(who)) and its login? Shared memory and settings stay.", default: false) else {
                print("Kept.")
                return
            }
        }
        try store.remove(seat)
        UsageCache.update(seat.slug, nil)
        print(Style.green("✓ ") + "Removed \(seat.slug).")
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

    // MARK: - Sessions

    /// Ends the calling Claude Code session and resumes the same
    /// conversation in another seat — in the same terminal tab when the
    /// shell integration started it, otherwise in a new window.
    static func move(_ slug: String?) throws {
        let mover = SessionMover(store: store)
        let target = try mover.target(named: slug, usage: UsageCache.load())
        let who = store.profile(of: target)?.email ?? target.slug
        let handoff = try mover.move(to: target, cliPath: stableCLIPath())
        switch handoff {
        case .sameTab:
            print("Continuing this conversation with \(who) (\(target.slug))…")
        case .newWindow:
            print("Continuing this conversation with \(who) (\(target.slug)) in a new terminal window…")
        }
    }

    /// Moves a session from outside it, like the menu bar's Move action.
    static func move(pid: String, to slug: String?) throws {
        guard let slug else { fail("Usage: cswap move <name> --pid <pid>") }
        let target = try requireSeat(slug)
        guard let session = store.seats().lazy.flatMap(store.runningSessions(of:)).first(where: { String($0.pid) == pid }) else {
            fail("No running Claude Code session with PID \(pid). See: cswap sessions")
        }
        let who = store.profile(of: target)?.email ?? target.slug
        switch try SessionMover(store: store).move(session, to: target, cliPath: stableCLIPath()) {
        case .sameTab:
            print(Style.green("✓ ") + "Moved \(session.title) to \(who) (\(target.slug)); it restarts in its own tab.")
        case .newWindow:
            print(Style.green("✓ ") + "Moved \(session.title) to \(who) (\(target.slug)) in a new terminal window.")
        }
    }

    static func sessions() {
        let mover = SessionMover(store: store)
        var any = false
        for seat in store.seats() {
            for session in store.runningSessions(of: seat) {
                any = true
                let state = session.isBusy ? Style.yellow("busy") : Style.dim(session.status ?? "")
                let place = mover.handoffKind(for: session) == .sameTab ? "" : Style.dim("  (moves to a new window)")
                print("\(Style.bold(seat.slug))  \(session.pid)  \(session.title)  \(state)\(place)")
                if let cwd = session.cwd { print("  " + Style.dim(abbreviate(cwd))) }
            }
        }
        if !any { print(Style.dim("No Claude Code sessions running.")) }
    }

    // MARK: - Setup

    /// One-time setup: links the command, loads the shell integration,
    /// installs /swap, then offers to log accounts in. Without a terminal
    /// (the menu bar app runs it) or with --yes it asks nothing.
    static func setup(interactive: Bool) async throws {
        print(Style.bold("cswap setup") + "\n")
        func row(_ ok: Bool, _ label: String, _ detail: String) {
            let mark = ok ? Style.green("✓") : Style.yellow("!")
            print("  \(mark) \(label.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)")
        }

        // Claude Code itself.
        if let claude = ClaudeLauncher.claudeExecutable() {
            row(true, "Claude Code", abbreviate(claude))
        } else {
            row(false, "Claude Code", "not found — install it first: curl -fsSL https://claude.ai/install.sh | bash")
        }

        // A stable command path that survives app updates.
        let linkPath = try linkCommand()
        row(true, "Command", "\(abbreviate(linkPath)) → \(abbreviate(ownPath))")

        // Shell integration.
        let shell = ShellIntegration(store: store)
        let report = try shell.install(cliPath: linkPath)
        let startupFiles = (report.changedFiles + report.unchangedFiles).map(abbreviate)
        let files = startupFiles.joined(separator: ", ")
        if let unsupported = report.unsupportedShell {
            row(false, "Shell", "\(unsupported) isn't supported; `cswap <account>` works, plain `claude` stays on main")
        }
        if !files.isEmpty {
            row(true, "Shell", "\(files) \(startupFiles.count == 1 ? "loads" : "load") \(abbreviate(shell.scriptURL.path))")
        }

        // /swap.
        if try store.installSwapCommand() {
            row(true, "/swap", abbreviate(store.swapCommandURL.path))
        } else {
            row(false, "/swap", "left your own \(abbreviate(store.swapCommandURL.path)) alone")
        }

        // Accounts.
        let reader = SeatCredentialReader()
        for seat in store.seats() {
            let email = reader.credentials(for: seat) == nil ? nil : store.profile(of: seat)?.email
            row(email != nil, seat.slug, email ?? "not logged in — cswap login \(seat.slug)")
        }

        if interactive {
            print()
            let main = store.mainSeat
            if reader.credentials(for: main) == nil, ask("Log in your main account now?", default: true) {
                loginFlow(main, email: nil)
            }
            while ask(store.seats().count == 1 ? "Add a second account now?" : "Add another account?", default: store.seats().count == 1) {
                guard let name = prompt("  Short name (e.g. work)"), !name.isEmpty else { break }
                let email = prompt("  Email (optional)")
                do {
                    let seat = try store.create(slug: name.lowercased())
                    loginFlow(seat, email: email?.isEmpty == false ? email : nil)
                } catch {
                    print(Style.yellow("  ! ") + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
            }
            if let app = appBundlePath {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-g", app]
                try? open.run()
                open.waitUntilExit()
                print(Style.green("\n✓ ") + "The menu bar app is running.")
            }
        }

        print("""

        \(Style.bold("Done.")) Open a new terminal tab, then:
          \(Style.bold("claude"))            starts the default account (\(store.defaultSeat().slug))
          \(Style.bold("cswap <account>"))   starts a specific one
          \(Style.bold("/swap"))             inside a session continues it with another account
        """)
    }

    /// Links `~/.local/bin/cswap` to this binary. Also points a `cseat` link
    /// from before the rename here, so terminals opened earlier keep working.
    static func linkCommand() throws -> String {
        let binDir = store.home.appendingPathComponent(".local/bin").path
        let linkPath = "\(binDir)/cswap"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        for path in [linkPath, "\(binDir)/cseat"] {
            let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
            let isLegacy = path.hasSuffix("/cseat")
            if isLegacy && existing == nil { continue }
            guard ownPath != path, existing != ownPath else { continue }
            if existing != nil { try FileManager.default.removeItem(atPath: path) }
            if FileManager.default.fileExists(atPath: path) {
                fail("\(path) exists and isn't a link — probably another tool named cswap. Move it away and run cswap setup again.")
            }
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: ownPath)
        }
        return linkPath
    }

    static func doctor() {
        var ok = true
        func check(_ passed: Bool, _ text: String) {
            print((passed ? Style.green("✓ ") : Style.yellow("! ")) + text)
            if !passed { ok = false }
        }

        let claude = ClaudeLauncher.claudeExecutable()
        check(claude != nil, "claude: \(claude.map(abbreviate) ?? "not found")")
        let shell = ShellIntegration(store: store)
        check(shell.isInstalled, "shell integration " + (shell.isInstalled ? "installed (\(shell.loginShellName))" : "missing — run: cswap setup"))
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let binDir = store.home.appendingPathComponent(".local/bin").path
        check(path.split(separator: ":").contains { $0 == binDir }, "~/.local/bin " + (path.contains(binDir) ? "is on PATH" : "isn't on PATH — open a new terminal after cswap setup"))
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
                state = "no login in Keychain item \u{201C}\(seat.keychainService)\u{201D} — cswap login \(seat.slug)"
            case (nil, _):
                state = "login present but no profile in \(abbreviate(seat.claudeJSONURL.path))"
            }
            check(profile != nil && credentials != nil, "\(seat.slug): \(state)")
            if credentials != nil, let email = profile?.email {
                if let other = emails[email.lowercased()] {
                    check(false, "\(seat.slug) and \(other) use the same account \(email). Log the wrong one in again: cswap login <name> --email <address>")
                }
                emails[email.lowercased()] = seat.slug
            }
            if !seat.isMain, let report = try? store.sync(seat), !report.conflicts.isEmpty {
                check(false, "\(seat.slug): has its own copy of \(report.conflicts.joined(separator: ", ")) instead of the shared one")
            }
        }
        exit(ok ? 0 : 1)
    }

    // MARK: - Launching

    /// Entry point for the shell integration: `cswap run --default -- args`
    /// or `cswap run <name> -- args`.
    static func run(_ args: [String]) throws {
        guard let selector = args.first else { fail("Usage: cswap run --default|<name> [-- claude args…]") }
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
                FileHandle.standardError.write(Data("cswap: couldn't sync \(seat.slug): \(error.localizedDescription)\n".utf8))
            }
        }
        try ClaudeLauncher.exec(seat: seat, arguments: arguments)
    }

    // MARK: - Helpers

    /// This binary, with symlinks resolved — also when started through PATH.
    static var ownPath: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The app bundle this binary ships in, if any.
    static var appBundlePath: String? {
        let url = URL(fileURLWithPath: ownPath)
        let contents = url.deletingLastPathComponent().deletingLastPathComponent()
        guard url.deletingLastPathComponent().lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" else { return nil }
        return contents.deletingLastPathComponent().path
    }

    static var version: String {
        guard let app = appBundlePath,
              let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
              let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return version
    }

    /// `~/.local/bin/cswap` when it exists, else this binary.
    static func stableCLIPath() -> String {
        let linked = store.home.appendingPathComponent(".local/bin/cswap").path
        if FileManager.default.isExecutableFile(atPath: linked) { return linked }
        return ownPath
    }

    static func requireSeat(_ slug: String?) throws -> Seat {
        guard let slug else { fail("Name an account. Accounts: \(store.seats().map(\.slug).joined(separator: ", "))") }
        guard let seat = store.seat(named: slug) else { throw SeatStore.SeatError.notFound(slug) }
        return seat
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func ask(_ question: String, default yes: Bool) -> Bool {
        print("\(question) \(Style.dim(yes ? "[Y/n]" : "[y/N]")) ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        if answer.isEmpty { return yes }
        return answer.hasPrefix("y") || answer.hasPrefix("j")
    }

    static func prompt(_ label: String) -> String? {
        print("\(label): ", terminator: "")
        fflush(stdout)
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }

    static func abbreviate(_ path: String) -> String {
        let home = store.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func bar(_ label: String, _ window: UsageWindow) -> String {
        let width = 20
        let filled = Int((window.fraction * Double(width)).rounded())
        let blocks = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        let percent = String(format: "%3d%%", Int(window.currentUtilization.rounded()))
        let colored = window.currentUtilization >= 90 ? Style.red(blocks) : window.currentUtilization >= 70 ? Style.yellow(blocks) : Style.green(blocks)
        return "\(Style.dim(label)) \(colored) \(percent)  \(Style.dim(window.resetText ?? ""))"
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("cswap: \(message)\n".utf8))
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
    static func cyan(_ text: String) -> String { wrap("36", text) }
}
