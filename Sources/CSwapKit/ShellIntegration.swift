import Foundation

/// The shell side of cswap: a script that makes plain `claude` start the
/// default account and lets `/swap` restart a session in the same tab, plus
/// the one line in the shell's startup file that loads it.
///
/// The script is plain POSIX-ish shell that zsh and bash (including the
/// bash 3.2 macOS ships) both run.
public struct ShellIntegration {

    public enum Shell: String, CaseIterable, Sendable {
        case zsh, bash
    }

    public struct Report: Sendable {
        public var changedFiles: [String] = []
        public var unchangedFiles: [String] = []
        /// The login shell isn't zsh or bash (fish, for example).
        public var unsupportedShell: String?
    }

    public let store: SeatStore
    public let environment: [String: String]

    public init(store: SeatStore = SeatStore(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        self.environment = environment
    }

    public var scriptURL: URL { store.root.appendingPathComponent("shell.sh") }
    /// zsh-only script written before the rename; still sourced by old lines.
    var legacyScriptURL: URL { store.root.appendingPathComponent("shell.zsh") }

    static let marker = "# cswap: plain `claude` starts the default account"
    static let legacyLines = [
        "# Claude Swap Bar: plain `claude` starts the default account",
        "[[ -r ~/.claude-seats/shell.zsh ]] && source ~/.claude-seats/shell.zsh",
    ]

    /// The line added to a startup file. `$HOME`-relative so a synced
    /// dotfile works on another Mac.
    var sourceLine: String {
        let path = scriptURL.path
        let home = store.home.path
        let shown = path.hasPrefix(home + "/") ? "$HOME" + path.dropFirst(home.count) : path
        return "[ -r \"\(shown)\" ] && . \"\(shown)\""
    }

    // MARK: - Detection

    /// The user's login shell, when cswap supports it.
    public var loginShell: Shell? {
        let name = (environment["SHELL"].map { ($0 as NSString).lastPathComponent }) ?? "zsh"
        return Shell(rawValue: name)
    }

    public var loginShellName: String {
        environment["SHELL"].map { ($0 as NSString).lastPathComponent } ?? "zsh"
    }

    /// Startup files for `shell`, in the order they're written.
    func startupFiles(for shell: Shell) -> [URL] {
        let home = store.home
        switch shell {
        case .zsh:
            let dir = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home
            return [dir.appendingPathComponent(".zshrc")]
        case .bash:
            // Terminal windows on macOS start login shells, which skip
            // ~/.bashrc and read the first of these that exists.
            let login = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
            let loginFile = login.first { FileManager.default.fileExists(atPath: $0.path) } ?? login[0]
            return [home.appendingPathComponent(".bashrc"), loginFile]
        }
    }

    /// Shells to set up: the login shell, plus any other supported shell
    /// the user already has a startup file for.
    var targetShells: [Shell] {
        Shell.allCases.filter { shell in
            shell == loginShell || startupFiles(for: shell).contains { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    public var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path)
            || FileManager.default.fileExists(atPath: legacyScriptURL.path) else { return false }
        return Shell.allCases.flatMap(startupFiles(for:)).contains { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.contains(sourceLine) || text.contains(Self.legacyLines[1])
        }
    }

    // MARK: - Install

    /// Writes the script and makes every target shell load it. Lines from
    /// before the rename are replaced in place. Safe to run repeatedly.
    @discardableResult
    public func install(cliPath: String) throws -> Report {
        try writeScript(cliPath: cliPath)
        var report = Report()
        if loginShell == nil { report.unsupportedShell = loginShellName }

        for shell in targetShells {
            for file in startupFiles(for: shell) {
                if try addSourceLine(to: file) {
                    report.changedFiles.append(file.path)
                } else {
                    report.unchangedFiles.append(file.path)
                }
            }
        }
        return report
    }

    /// Returns whether `file` changed. Writes through a symlink, so a
    /// startup file kept in a dotfiles repo stays a link.
    private func addSourceLine(to link: URL) throws -> Bool {
        let file = link.resolvingSymlinksInPath()
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = current.components(separatedBy: "\n")
        if lines.contains(sourceLine) && !lines.contains(where: Self.legacyLines.contains) { return false }

        lines.removeAll { Self.legacyLines.contains($0) || $0 == Self.marker || $0 == sourceLine }
        while lines.last == "" { lines.removeLast() }
        let block = [Self.marker, sourceLine]
        let updated = (lines.isEmpty ? block : lines + [""] + block).joined(separator: "\n") + "\n"
        try Data(updated.utf8).write(to: file, options: .atomic)
        return true
    }

    /// (Re)writes the script only. The app does this on every launch so an
    /// update also updates the script.
    public func writeScript(cliPath: String) throws {
        try store.ensureRoot()
        let script = Self.script(cliPath: cliPath, handoffDirectory: store.handoffDirectory.path, legacyAlias: store.usesLegacyRoot)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        // Startup files from before the rename source shell.zsh.
        if FileManager.default.fileExists(atPath: legacyScriptURL.path) {
            try Data(script.utf8).write(to: legacyScriptURL, options: .atomic)
        }
    }

    static func script(cliPath: String, handoffDirectory: String, legacyAlias: Bool) -> String {
        let cli = TerminalLauncher.shellQuoted(cliPath)
        let handoff = TerminalLauncher.shellQuoted(handoffDirectory) + "/$$"
        let leaked = (ClaudeLauncher.sessionMarkers + ["CLAUDE_CONFIG_DIR", "CSWAP_SHELL_PID", "CSEAT_SHELL_PID"])
            .joined(separator: " ")
        let subcommands = CLICommands.names.joined(separator: "|")
        // `rc`, not `status`: zsh reserves `status` as a read-only variable.
        var script = """
        # Generated by cswap; rewritten on every update, don't edit.
        # Makes `claude` start the default account, and lets /swap restart a
        # session with another account in the same terminal tab.

        case ":$PATH:" in
          *":$HOME/.local/bin:"*) ;;
          *) export PATH="$HOME/.local/bin:$PATH" ;;
        esac

        # A terminal opened from inside Claude Code can inherit its session
        # variables. In an interactive shell they are always leftovers, and
        # CLAUDE_CODE_CHILD_SESSION would switch transcript saving off.
        case $- in
          *i*) if [ -n "$CLAUDECODE" ]; then unset \(leaked); fi ;;
        esac

        _cswap_session() {
          local handoff=\(handoff) rc line
          local -a next
          CSWAP_SHELL_PID=$$ \(cli) run "$@"
          rc=$?
          while [ -f "$handoff" ]; do
            next=()
            while IFS= read -r line || [ -n "$line" ]; do next+=("$line"); done < "$handoff"
            command rm -f "$handoff"
            CSWAP_SHELL_PID=$$ \(cli) run "${next[@]}"
            rc=$?
          done
          return $rc
        }

        claude() {
          if [ -n "$CLAUDE_CONFIG_DIR" ] || [ ! -x \(cli) ]; then
            command claude "$@"
            return
          fi
          _cswap_session --default -- "$@"
        }

        # `cswap <account>` starts through the same wrapper, so /swap and the
        # menu bar's Move restart those sessions in their own tab too.
        cswap() {
          if [ ! -x \(cli) ]; then
            command cswap "$@"
            return
          fi
          case "$1" in
            ""|-*|\(subcommands))
              \(cli) "$@" ;;
            *)
              local name=$1
              shift
              _cswap_session "$name" -- "$@" ;;
          esac
        }

        """
        if legacyAlias {
            script += """

            # The command used to be called cseat.
            cseat() { cswap "$@"; }

            """
        }
        return script
    }
}

/// Subcommands of `cswap`; anything else is an account name.
public enum CLICommands {
    public static let names = [
        "list", "ls", "status", "use", "best", "move", "swap", "sessions", "add", "login",
        "remove", "rm", "sync", "setup", "doctor", "run", "help", "version",
    ]
}
