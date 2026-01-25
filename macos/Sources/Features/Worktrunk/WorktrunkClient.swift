import Foundation

enum WorktrunkClientError: LocalizedError {
    case executableNotFound
    case nonZeroExit(code: Int32, stderr: String)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Worktrunk binary not found. Install worktrunk (provides `wt`) or set GHOSTTY_WORKTRUNK_BIN."
        case .nonZeroExit(let code, let stderr):
            if stderr.isEmpty { return "Worktrunk failed (exit \(code))." }
            return "Worktrunk failed (exit \(code)): \(stderr)"
        case .invalidUTF8:
            return "Worktrunk returned invalid UTF-8 output."
        }
    }
}

struct WorktrunkClient {
    struct CommandResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private struct Invocation {
        var executableURL: URL
        var arguments: [String]
        var environment: [String: String]
    }

    static func run(_ args: [String]) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runSync(args)
        }.value
    }

    private static func runSync(_ args: [String]) throws -> CommandResult {
        let invocation = try makeInvocation(args)

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment

        // Ensure we never hang waiting for stdin in a GUI process.
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw WorktrunkClientError.invalidUTF8
        }

        let result = CommandResult(stdout: stdout, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines), exitCode: process.terminationStatus)
        if result.exitCode != 0 {
            throw WorktrunkClientError.nonZeroExit(code: result.exitCode, stderr: result.stderr)
        }

        return result
    }

    private static func makeInvocation(_ args: [String]) throws -> Invocation {
        var env = ProcessInfo.processInfo.environment

        // GUI apps often have a minimal PATH; prepend common install locations.
        let prefix = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existingPath = env["PATH"] ?? ""
        if existingPath.isEmpty {
            env["PATH"] = prefix.joined(separator: ":")
        } else {
            let existingComponents = Set(existingPath.split(separator: ":").map(String.init))
            let missingPaths = prefix.filter { !existingComponents.contains($0) }
            if !missingPaths.isEmpty {
                env["PATH"] = (missingPaths + [existingPath]).joined(separator: ":")
            }
        }

        if let explicit = env["GHOSTTY_WORKTRUNK_BIN"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw WorktrunkClientError.executableNotFound
            }
            return Invocation(executableURL: url, arguments: args, environment: env)
        }

        for path in ["/opt/homebrew/bin/wt", "/usr/local/bin/wt", "/usr/bin/wt"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return Invocation(executableURL: URL(fileURLWithPath: path), arguments: args, environment: env)
            }
        }

        // Last resort: rely on PATH resolution.
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        guard FileManager.default.isExecutableFile(atPath: envURL.path) else {
            throw WorktrunkClientError.executableNotFound
        }

        return Invocation(executableURL: envURL, arguments: ["wt"] + args, environment: env)
    }
}
