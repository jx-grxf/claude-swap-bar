import AppKit
import Foundation

/// Runs a shell command in a new terminal window: Ghostty when installed,
/// Terminal.app otherwise. The window stays open as a normal shell after the
/// command exits.
enum TerminalLauncher {

    static func run(_ command: String) throws {
        let script = "\(command); exec /bin/zsh -il"
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        if FileManager.default.fileExists(atPath: ghostty.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", ghostty.path, "--args", "-e", "/bin/zsh", "-ilc", script]
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

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
