import Foundation

/// Starts the real `claude` binary inside a seat.
public enum ClaudeLauncher {

    public struct NotFound: LocalizedError {
        public init() {}

        public var errorDescription: String? {
            "Couldn't find the `claude` command. Install Claude Code or add it to PATH."
        }
    }

    /// First `claude` executable on PATH, plus the native installer's
    /// default location for shells that don't have it on PATH.
    public static func claudeExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        // Tests point this at a stand-in so they never start a real login.
        if let override = environment["CSEAT_CLAUDE"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = NSHomeDirectory()
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in candidates where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Environment for a process running in `seat`.
    public static func environment(for seat: Seat, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        if let dir = seat.configDirEnvironmentValue {
            env["CLAUDE_CONFIG_DIR"] = dir
        } else {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        return env
    }

    /// Runs `claude` in `seat` as a child that shares this process's
    /// terminal, and waits for it. Foundation's `Process` would start it in
    /// its own process group, where an interactive TUI can't read the
    /// terminal and stalls. Returns the exit status.
    @discardableResult
    public static func run(seat: Seat, arguments: [String]) throws -> Int32 {
        guard let claude = claudeExecutable() else { throw NotFound() }
        let env = environment(for: seat).map { "\($0.key)=\($0.value)" }
        let argv = ([claude] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid = pid_t()
        let spawnStatus = posix_spawn(&pid, claude, nil, nil, argv, envp)
        guard spawnStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .ENOEXEC)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return (status >> 8) & 0xff
    }

    /// Replaces the current process with `claude` running in `seat`.
    public static func exec(seat: Seat, arguments: [String]) throws -> Never {
        guard let claude = claudeExecutable() else { throw NotFound() }
        let env = environment(for: seat).map { "\($0.key)=\($0.value)" }

        let argv = ([claude] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup($0) } + [nil]
        execve(claude, argv, envp)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOEXEC)
    }
}
