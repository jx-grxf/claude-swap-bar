import AppKit
import Foundation

/// Runs a shell command in a new terminal window: Ghostty when installed,
/// Terminal.app otherwise. The window stays open as a normal shell after the
/// command exits.
public enum TerminalLauncher {

    /// - Parameter workingDirectory: folder the window starts in; Claude
    ///   Code keys project memory and instructions to it.
    public static func run(_ command: String, workingDirectory: String? = nil) throws {
        // The window inherits the caller's environment. When that caller runs
        // inside Claude Code, drop its session markers first.
        var parts = ["unset " + ClaudeLauncher.sessionMarkers.joined(separator: " ")]
        if let workingDirectory { parts.append("cd \(shellQuoted(workingDirectory))") }
        parts.append(command)
        let script = parts.joined(separator: "; ") + "; exec /bin/zsh -il"
        // Tests run the script in place instead of opening a window.
        if let dryRun = ProcessInfo.processInfo.environment["CSEAT_TERMINAL_SCRIPT"], !dryRun.isEmpty {
            try Data(script.utf8).write(to: URL(fileURLWithPath: dryRun))
            return
        }
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        if FileManager.default.fileExists(atPath: ghostty.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", ghostty.path, "--args", "-e", "/bin/zsh", "-ilc", script]
            // `open` hands its environment to the new Ghostty process, and
            // every later tab in it inherits that. Start it clean.
            process.environment = cleanEnvironment()
            try process.run()
            return
        }

        // Terminal.app runs `.command` files in a new window.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-\(UUID().uuidString).command")
        let contents = "#!/bin/zsh -il\nrm -f \(shellQuoted(file.path))\n\(script)\n"
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    static func cleanEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in ClaudeLauncher.sessionMarkers + ["CLAUDE_CONFIG_DIR", "CSEAT_SHELL_PID"] {
            env.removeValue(forKey: key)
        }
        return env
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
