import Foundation

/// The `PATH` the user's own shell would have, for subprocesses that run
/// the user's tooling.
///
/// A GUI app launched from Finder or the Dock gets `launchd`'s environment,
/// which on this machine means `PATH=/usr/bin:/bin:/usr/sbin:/sbin` —
/// no Homebrew, no nvm, no pnpm. That's fine for `git status`, and quietly
/// fatal for anything that runs a hook: a `git commit` in a repo with husky
/// spawns `.husky/pre-commit`, which calls `npx`, which isn't on that path.
/// The commit fails with `npx: command not found` and no obvious cause.
///
/// So the login shell is asked once, in the background, what its `PATH` is,
/// and git subprocesses inherit that instead.
///
/// Only `PATH` is taken, deliberately. Importing a login shell's entire
/// environment into a long-lived GUI process means inheriting whatever a
/// dotfile happened to export this session — the class of leakage
/// `InheritedEnvironment` exists to clean up in the other direction.
enum LoginEnvironment {
    /// A login shell has to source the user's rc files to build `PATH`, and
    /// people put slow things in those.
    private static let resolveTimeout: TimeInterval = 5

    private static let lock = NSLock()
    private static var cachedPath: String?
    private static var didResolve = false

    /// The environment to hand a subprocess: the current one with `PATH`
    /// replaced, when the login shell's could be resolved.
    ///
    /// Falls back to the process environment unchanged rather than failing
    /// — a wrong `PATH` breaks hooks, but no environment at all breaks
    /// everything.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = loginPath() { env["PATH"] = path }
        return env
    }

    /// Resolves and caches the login shell's `PATH`. Blocking; call from a
    /// background task.
    static func loginPath() -> String? {
        lock.lock()
        if didResolve {
            let cached = cachedPath
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve()

        lock.lock()
        cachedPath = resolved
        didResolve = true
        lock.unlock()

        return resolved
    }

    private static func resolve() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        // Interactive as well as login: plenty of people set PATH in
        // .zshrc rather than .zprofile, and a login-only shell misses it.
        let result = ShellCommand.runResult(
            shell,
            ["-lic", "printf %s \"$PATH\""],
            timeout: resolveTimeout
        )

        guard result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
