import Foundation

/// Runs `git` for the Git panel.
///
/// Everything goes through `Process.arguments`, which is an `execve` argv
/// array — no shell, so a commit message with newlines, quotes or `$` is
/// one argument that arrives exactly as typed, and there is no quoting to
/// get wrong.
///
/// Blocking; every call belongs on a background task.
enum GitCommand {
    /// Where to find `git`, preferring a real installation over the Xcode
    /// Command Line Tools shim at `/usr/bin/git`. The shim works, but it's
    /// the wrong `git` when the user installed a newer one, and on a Mac
    /// that never had the tools accepted it pops the install dialog instead
    /// of running.
    ///
    /// Same probe-a-known-list approach as `GitStatusCenter.ghPath`, with
    /// the login shell's `PATH` as a last resort so a `git` somewhere
    /// unusual is still found.
    nonisolated static let path: String? = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        let fm = FileManager.default
        if let known = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return known
        }

        guard let loginPath = LoginEnvironment.loginPath() else { return nil }
        for dir in loginPath.split(separator: ":") {
            let candidate = "\(dir)/git"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    /// Read-only queries. Short timeout — these run on a timer and must not
    /// pile up.
    static let queryTimeout: TimeInterval = 10

    /// Anything that changes the repository. Generous, because this is
    /// where the user's own hooks run: a `lint-staged` pre-commit on a
    /// real project passes 30s without being stuck.
    static let mutateTimeout: TimeInterval = 120

    /// Network operations, which are bounded by someone else's server.
    static let networkTimeout: TimeInterval = 180

    static func run(
        _ arguments: [String],
        in root: String,
        timeout: TimeInterval = queryTimeout
    ) -> ShellCommand.Result {
        guard let git = path else {
            return ShellCommand.Result(
                status: nil,
                stdout: "",
                stderr: "Couldn't find git. Install the Xcode Command Line Tools or Homebrew git."
            )
        }

        return ShellCommand.runResult(
            git,
            ["-C", root] + arguments,
            environment: LoginEnvironment.environment(),
            timeout: timeout
        )
    }

    /// Convenience for queries whose answer is stdout and where failure
    /// just means "nothing to show".
    static func output(_ arguments: [String], in root: String) -> String? {
        let result = run(arguments, in: root)
        return result.succeeded ? result.stdout : nil
    }
}
