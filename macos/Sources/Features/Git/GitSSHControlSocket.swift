import CryptoKit
import Darwin
import Foundation
import os

/// OpenSSH owns connection/channel lifetimes and expires idle masters after
/// 60 seconds. A private socket namespace prevents sharing an interactive
/// terminal's master or reusing a connection with different routing options.
enum GitSSHControlSocket {
    private static let session = UUID().uuidString

    static func path(for connection: GitSSHConnection, executablePath: String) throws -> String {
        // Darwin's Unix socket paths are limited to 104 bytes; the normal
        // per-user temporary directory can consume almost all of that space.
        let directory = "/tmp/omg-git-\(getuid())"
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else {
            throw GitExecutionError.executionFailed(GitL10n.text("Cannot create the SSH connection directory."))
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw GitExecutionError.executionFailed(GitL10n.text("The SSH connection directory must be private and owned by this user."))
        }
        let identity = session + "\0" + executablePath + "\0" + connection.identity
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(20)
            .map { String(format: "%02x", $0) }.joined()
        let path = directory + "/" + digest
        issued.withLock { $0[path] = executablePath }
        return path
    }

    private static let issued = OSAllocatedUnfairLock(initialState: [String: String]())

    /// Masters persist 60 seconds after their last channel. Their sockets are
    /// unique to this launch, so nothing can reuse them after quit; leaving
    /// them (and their ProxyJump helpers) running keeps the quit app listed
    /// as running in the background. Ask each live master to exit.
    static func closeAll(timeout: TimeInterval = 1) {
        let sockets = issued.withLock { current -> [String: String] in
            defer { current.removeAll() }
            return current
        }
        let processes: [Process] = sockets.compactMap { path, executable in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-S", path, "-O", "exit", "omg-git"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return (try? process.run()) == nil ? nil : process
        }
        let deadline = Date().addingTimeInterval(timeout)
        for process in processes {
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { process.terminate() }
        }
    }
}
