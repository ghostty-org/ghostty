import Foundation

/// Runs short-lived commands that enrich sidebar metadata (`git`, `gh`,
/// `ps`, `lsof`).
enum ShellCommand {
    /// Collects stdout off the polling thread. Draining has to happen
    /// concurrently with the wait: a command whose output overflows the
    /// pipe buffer blocks writing until someone reads, so waiting first
    /// would hang, and reading first would ignore the timeout.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var data: Data {
            lock.withLock { storage }
        }

        func store(_ data: Data) {
            lock.withLock { storage = data }
        }
    }

    /// Returns the command's stdout, or nil when it can't be launched,
    /// exits non-zero, or outlives `timeout`.
    ///
    /// This blocks the calling thread while it waits, so it belongs on a
    /// background task — never the main actor.
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let output = Output()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.store(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        // The process has exited, so the read side is at EOF and the drain
        // is about to finish; the bound only guards against a stuck reader.
        guard drained.wait(timeout: .now() + 2) == .success,
              process.terminationStatus == 0
        else { return nil }

        return String(data: output.data, encoding: .utf8)
    }

    /// What a command actually did.
    struct Result {
        /// The process exit status, or nil when it never ran to completion
        /// (failed to launch, or was killed at the timeout).
        var status: Int32?
        var stdout: String
        var stderr: String

        var succeeded: Bool { status == 0 }

        /// The best line to put in front of a user. Git says useful things
        /// on both streams depending on the subcommand.
        var message: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { return out }
            return status == nil ? "The command timed out." : "The command failed."
        }
    }

    /// Runs a command and reports everything about how it went.
    ///
    /// `run` above answers "what did this print", which is all a status
    /// query needs. Anything that *changes* something needs more than that,
    /// and `run` structurally can't give it: it discards the exit status,
    /// never drains stderr, and collapses launch failure, timeout and
    /// non-zero exit into the same `nil`. Git in particular communicates
    /// through all three — `diff --quiet` answers only in the exit code,
    /// and a failed `push` explains itself only on stderr.
    ///
    /// Both pipes are drained concurrently. Draining only stdout is a
    /// deadlock waiting to happen: a command that writes more than a pipe
    /// buffer (~64KB) to stderr blocks forever, and git is chatty there.
    ///
    /// Blocks the calling thread — background tasks only, never the main
    /// actor.
    static func runResult(
        _ launchPath: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Nothing sensible can be read from a GUI app's stdin, and a child
        // that blocks reading it would hang until the timeout.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: nil, stdout: "", stderr: error.localizedDescription)
        }

        let outData = Output()
        let errData = Output()
        let group = DispatchGroup()

        for (pipe, sink) in [(outPipe, outData), (errPipe, errData)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.store(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
        }

        _ = group.wait(timeout: .now() + 2)

        return Result(
            status: timedOut ? nil : process.terminationStatus,
            stdout: String(data: outData.data, encoding: .utf8) ?? "",
            stderr: String(data: errData.data, encoding: .utf8) ?? ""
        )
    }
}
