import Foundation
import Darwin

/// Listens on a per-user Unix domain socket for requests from `ghostty` CLI
/// processes (e.g. `ghostty +new-window`) and dispatches them to the running
/// app. The sender lives in the Zig core (`apprt/embedded.zig`, `performIpc`).
///
/// The two ends agree on the socket path and wire format without any shared
/// state:
///   - Path: `<per-user temp dir>/ghostty-ipc-<bundle id>.sock`, where the temp
///     dir is resolved via `confstr(_CS_DARWIN_USER_TEMP_DIR)` on both sides so
///     they match regardless of `$TMPDIR`.
///   - Frame: `[u8 action][u32 argc]` followed by `argc` times `[u32 len][bytes]`,
///     all integers little-endian. The app replies with a single byte: 0 for
///     success, non-zero for failure.
final class IPCServer {
    /// Invoked on the main queue when a new-window request arrives.
    typealias NewWindowHandler = (Ghostty.SurfaceConfiguration) -> Void

    /// Actions, matching `apprt.ipc.Action.Key` on the Zig side.
    private enum Action: UInt8 {
        case newWindow = 0
        case toggleQuickTerminal = 1
    }

    private let socketPath: String
    private let onNewWindow: NewWindowHandler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.ipc")

    init?(onNewWindow: @escaping NewWindowHandler) {
        guard let path = IPCServer.socketPath() else { return nil }
        self.socketPath = path
        self.onNewWindow = onNewWindow
        guard listenOnSocket() else { return nil }
    }

    deinit {
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
    }

    private static func socketPath() -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0, n <= buf.count else { return nil }
        let dir = String(cString: buf)  // already ends in a path separator
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
        return "\(dir)ghostty-ipc-\(bundleID).sock"
    }

    private func listenOnSocket() -> Bool {
        // Remove any stale socket left by a previous (crashed) run.
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is fixed-size and must remain NUL-terminated.
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return false
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
        return true
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        guard let raw = readUInt8(client), let action = Action(rawValue: raw) else {
            writeAck(client, ok: false)
            return
        }

        switch action {
        case .newWindow:
            guard let args = readArguments(client) else {
                writeAck(client, ok: false)
                return
            }
            let config = IPCServer.surfaceConfiguration(from: args)
            writeAck(client, ok: true)
            DispatchQueue.main.async { [onNewWindow] in onNewWindow(config) }

        case .toggleQuickTerminal:
            // Not implemented yet.
            writeAck(client, ok: false)
        }
    }

    /// Parse CLI-style arguments into a surface configuration, mirroring the
    /// GTK receiver (`apprt/gtk/class/application.zig`, `actionNewWindow`).
    static func surfaceConfiguration(from args: [String]) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        var directCommand: [String] = []
        var eSeen = false

        for arg in args {
            if eSeen {
                directCommand.append(arg)
            } else if arg == "-e" {
                eSeen = true
            } else if let v = arg.ipcStripPrefix("--command=") {
                config.command = v
            } else if let v = arg.ipcStripPrefix("--working-directory=") {
                config.workingDirectory = v.trimmingCharacters(in: .whitespaces)
            } else if let v = arg.ipcStripPrefix("--title=") {
                config.title = v.trimmingCharacters(in: .whitespaces)
            }
        }

        // `-e` is a direct command (argv). libghostty's surface command always
        // runs via `/bin/sh -c`, so shell-quote each argument to preserve word
        // boundaries (e.g. arguments that themselves contain spaces).
        if !directCommand.isEmpty {
            config.command = directCommand.map { Ghostty.Shell.quote($0) }.joined(separator: " ")
        }

        return config
    }

    // MARK: - Socket reading helpers

    private func readUInt8(_ fd: Int32) -> UInt8? {
        var v: UInt8 = 0
        let ok = withUnsafeMutableBytes(of: &v) { readFull(fd, into: $0) }
        return ok ? v : nil
    }

    private func readUInt32(_ fd: Int32) -> UInt32? {
        var v: UInt32 = 0
        let ok = withUnsafeMutableBytes(of: &v) { readFull(fd, into: $0) }
        return ok ? UInt32(littleEndian: v) : nil
    }

    private func readArguments(_ fd: Int32) -> [String]? {
        guard let count = readUInt32(fd) else { return nil }
        var result: [String] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let len = readUInt32(fd) else { return nil }
            if len == 0 {
                result.append("")
                continue
            }
            var buf = [UInt8](repeating: 0, count: Int(len))
            let ok = buf.withUnsafeMutableBytes { readFull(fd, into: $0) }
            guard ok, let s = String(bytes: buf, encoding: .utf8) else { return nil }
            result.append(s)
        }
        return result
    }

    /// Read exactly `buffer.count` bytes, looping over short reads.
    private func readFull(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress else { return true }
        var total = 0
        while total < buffer.count {
            let n = read(fd, base.advanced(by: total), buffer.count - total)
            if n <= 0 { return false }
            total += n
        }
        return true
    }

    private func writeAck(_ fd: Int32, ok: Bool) {
        var b: UInt8 = ok ? 0 : 1
        _ = withUnsafeBytes(of: &b) { write(fd, $0.baseAddress, 1) }
    }
}

private extension String {
    /// If the string starts with `prefix`, return the remainder, else nil.
    func ipcStripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
