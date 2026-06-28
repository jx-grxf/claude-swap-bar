import Foundation

/// Thin wrapper around the `cswap` CLI. Everything goes through the JSON
/// interface so we never scrape human-readable output.
struct CSwapClient {

    enum CSwapError: LocalizedError {
        case binaryNotFound
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the `cswap` executable. Install it with `uv tool install claude-swap`."
            case let .nonZeroExit(code, stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "cswap exited with code \(code)\(detail.isEmpty ? "" : ": \(detail)")"
            case let .decodeFailed(message):
                return "Could not parse cswap output: \(message)"
            }
        }
    }

    enum Strategy: String {
        case best
        case nextAvailable = "next-available"
    }

    // MARK: - Public API

    func list() throws -> AccountList {
        let result = try run(["--list", "--json"])
        guard result.exitCode == 0 else {
            throw CSwapError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
        return try decode(result.stdout)
    }

    func switchTo(number: Int) throws {
        try runExpectingSuccess(["--switch-to", String(number), "--json"])
    }

    func rotate(strategy: Strategy?) throws {
        var args = ["--switch", "--json"]
        if let strategy {
            args += ["--strategy", strategy.rawValue]
        }
        try runExpectingSuccess(args)
    }

    // MARK: - Process plumbing

    private struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runExpectingSuccess(_ args: [String]) throws {
        let result = try run(args)
        guard result.exitCode == 0 else {
            throw CSwapError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }
    }

    private func decode(_ json: String) throws -> AccountList {
        guard let data = json.data(using: .utf8) else {
            throw CSwapError.decodeFailed("empty output")
        }
        do {
            return try JSONDecoder().decode(AccountList.self, from: data)
        } catch {
            throw CSwapError.decodeFailed(error.localizedDescription)
        }
    }

    private func run(_ args: [String]) throws -> CommandResult {
        let process = Process()
        let binary = Self.resolveBinaryPath()

        var finalArgs = args
        if binary.hasSuffix("/env") {
            // No absolute cswap found — let `env` resolve it from PATH.
            finalArgs = ["cswap"] + args
        }

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = finalArgs

        // GUI apps inherit a minimal PATH, so widen it to the usual install dirs.
        var env = ProcessInfo.processInfo.environment
        let extras = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        env["PATH"] = (extras + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CSwapError.binaryNotFound
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private static func resolveBinaryPath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/cswap",
            "/opt/homebrew/bin/cswap",
            "/usr/local/bin/cswap",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/env"
    }
}
