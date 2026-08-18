//  Running command-line tools.
//
//  Only `xcode-select` and `xcrun simctl` are ever launched from here, both of
//  which are supported public interfaces. Device lifecycle deliberately goes
//  through simctl rather than CoreSimulator's own boot path: it survives Xcode
//  updates, so only rendering and input depend on private API.

import Foundation

enum Shell {

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }

        /// stderr when the tool wrote one, else stdout, else a generic note. What
        /// a user should be shown when the command failed.
        var failureMessage: String {
            let candidates = [stderr, stdout].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return candidates.first { !$0.isEmpty } ?? "exited with status \(status)"
        }
    }

    /// Runs a tool to completion and captures both streams.
    ///
    /// `scrubEnvironment` launches the tool with a minimal environment. This
    /// matters for `simctl`: a process that has loaded CoreSimulator can hand
    /// its children a view of the world in which a device it holds open still
    /// looks booted after it has been shut down elsewhere.
    static func capture(
        _ path: String, _ args: [String], scrubEnvironment: Bool = false
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if scrubEnvironment {
            process.environment = [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "could not launch \(path): \(error)")
        }

        // Read before waiting: a tool that fills a pipe buffer would otherwise
        // block forever on a write while we block forever on the exit.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Trimmed stdout, or nil if the tool could not be launched or exited non-zero.
    static func run(_ path: String, _ args: [String], scrubEnvironment: Bool = false) -> String? {
        let result = capture(path, args, scrubEnvironment: scrubEnvironment)
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
