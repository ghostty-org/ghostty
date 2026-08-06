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
}
