import Darwin
import Foundation

/// Give SSH its own controlling PTY and translate only the outer UTF-8 byte stream.
/// UTF-8 sessions bypass this relay and keep the existing direct spawn path.
enum SSHEncodingRelay {
    static func run(executable: String, arguments: [String], environment: [String: String],
                    encoding: SSHProfile.Encoding, onSpawn: (pid_t?) -> Void) throws -> Int32 {
        let input = try SSHEncodingConverter(from: "UTF-8", to: encoding.rawValue)
        let output = try SSHEncodingConverter(from: encoding.rawValue, to: "UTF-8")
        var saved = termios()
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else {
            throw SSHError.message("Legacy character encoding requires an interactive terminal.")
        }
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        var slaveSettings = saved
        slaveSettings.c_iflag &= ~tcflag_t(IUTF8)
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, &slaveSettings, &size) == 0 else { throw systemError() }
        defer { close(master) }

        let command = strdup(executable)!
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(command)
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        // Everything used after fork is allocated above. The child only calls libc
        // session/fd operations and execve; it never invokes Foundation or Swift objects.
        let pid = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { variables -> pid_t in
                ghostty_ssh_spawn_pty(command, arguments.baseAddress!, variables.baseAddress!, master, slave)
            }
        }
        close(slave)
        guard pid >= 0 else { throw systemError() }
        onSpawn(pid)
        var reaped = false
        var status: Int32 = 0
        defer {
            if !reaped { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
            onSpawn(nil)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        }
        var raw = saved
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw systemError() }
        let flags = fcntl(master, F_GETFL)
        guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else { throw systemError() }
        var readingInput = true
        var pendingInput = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            // Polling the window size keeps resize handling out of async signal handlers.
            var latest = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &latest) == 0,
               latest.ws_row != size.ws_row || latest.ws_col != size.ws_col {
                size = latest
                _ = ioctl(master, TIOCSWINSZ, &size)
            }
            let masterEvents = Int16(POLLIN) | (pendingInput.isEmpty ? 0 : Int16(POLLOUT))
            // Bound paste buffering and keep draining SSH output while input backs up.
            let acceptInput = readingInput && pendingInput.count < 256 * 1024
            var descriptors = [pollfd(fd: master, events: masterEvents, revents: 0),
                               pollfd(fd: acceptInput ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { try writeAll(output.convert(Data(buffer.prefix(count))), to: STDOUT_FILENO) }
                else if count == 0 || errno == EIO { break }
                else if errno != EINTR && errno != EAGAIN { throw systemError() }
            }
            if descriptors[0].revents & Int16(POLLHUP) != 0 { pendingInput.removeAll() }
            if descriptors[0].revents & Int16(POLLOUT) != 0, !pendingInput.isEmpty {
                let count = pendingInput.withUnsafeBytes { bytes in
                    write(master, bytes.baseAddress!, min(bytes.count, 16 * 1024))
                }
                if count > 0 { pendingInput.removeFirst(count) }
                else if count < 0 && errno != EINTR && errno != EAGAIN { throw systemError() }
            }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 { pendingInput.append(input.convert(Data(buffer.prefix(count)))) }
                else if count == 0 {
                    readingInput = false
                    kill(pid, SIGHUP)
                } else if errno != EINTR { throw systemError() }
            }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
                else if result < 0 && errno != EINTR { throw systemError() }
            }
            if reaped && ready == 0 { break }
        }
        try writeAll(output.finish(), to: STDOUT_FILENO)
        if !reaped {
            while waitpid(pid, &status, 0) < 0 { if errno != EINTR { throw systemError() } }
            reaped = true
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw systemError() }
            }
        }
    }

    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
