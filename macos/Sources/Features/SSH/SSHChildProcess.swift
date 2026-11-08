import Darwin
import Foundation

/// Unlike Foundation.Process on macOS, this preserves the controlling PTY's foreground group.
enum SSHChildProcess {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    onSpawn: (pid_t?) -> Void = { _ in }) throws -> Int32 {
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for value in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE] { sigaddset(&defaults, value) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, nil, &attributes, &argv, &envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        onSpawn(pid)
        defer { onSpawn(nil) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
