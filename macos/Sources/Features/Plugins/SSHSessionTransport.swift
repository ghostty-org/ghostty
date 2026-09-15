import Foundation

/// Shared bounded IO and exact-connection multiplexing for Git, files and inventory.
enum SSHSessionTransport {
    static func shellCommand(_ script: String) -> String {
        // Keep nested quotes/newlines out of the user's login shell (including
        // fish). SSH stdin remains available for the actual command payload.
        let encoded = Data(script.utf8).base64EncodedString()
        return "exec /bin/sh -c 'exec /bin/sh -c \"$(printf %s " + encoded + " | base64 -d)\"'"
    }
    static func run(connection: GitSSHConnection, command: String, stdin: Data? = nil,
                    limit: Int? = 1_048_576, timeout: TimeInterval = 60,
                    executable: String? = nil, multiplexing: Bool = true) async throws -> GitExecutionResult {
        let executable = executable ?? connection.executablePath
        let socket = multiplexing ? try GitSSHControlSocket.path(for: connection, executablePath: executable) : nil
        return try await GitProcessRunner().run(executablePath: executable,
            arguments: connection.arguments(controlSocket: socket) + [command],
            workingDirectory: connection.localWorkingDirectory, stdin: stdin, maxOutputBytes: limit, timeout: timeout)
    }

    static func python(_ script: String, connection: GitSSHConnection, loginShell: Bool = false) async throws -> Data {
        let remote = loginShell
            ? shellCommand("exec \"${SHELL:-/bin/sh}\" -lic 'exec python3 -'")
            : "exec python3 -"
        let result = try await run(connection: connection, command: remote,
            stdin: Data(("print('OMG_AGENT_RESULT_BEGIN', flush=True)\n" + script).utf8), timeout: 360)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        guard let marker = result.stdoutString.range(of: "OMG_AGENT_RESULT_BEGIN\n") else {
            throw AgentHistoryRemoteError.unavailable
        }
        return Data(result.stdoutString[marker.upperBound...].utf8)
    }

    static func sftp(batch: String, connection: GitSSHConnection) async throws -> String {
        let socket = try GitSSHControlSocket.path(for: connection, executablePath: connection.executablePath)
        // sftp's -S adapter preserves SSH options without confusing ssh -p/-l
        // with sftp's unrelated flags. Each call owns its temporary adapter.
        let adapter = URL(fileURLWithPath: socket + ".\(UUID().uuidString).sh")
        let arguments = connection.arguments(controlSocket: socket).dropLast(2)
            .map { $0 == "SessionType=default" ? "SessionType=subsystem" : $0 }
        // OpenSSH rejects an explicit SessionType together with sftp's -s.
        // Select the subsystem ourselves and remove just that generated flag.
        let filter = """
        #!/bin/sh
        omg_count=$#
        while [ "$omg_count" -gt 0 ]; do
          omg_arg=$1
          shift
          [ "$omg_arg" = '-s' ] || set -- "$@" "$omg_arg"
          omg_count=$((omg_count - 1))
        done
        """
        let script = filter + "\nexec " + ([connection.executablePath] + arguments)
            .map(Ghostty.Shell.quote).joined(separator: " ") + " \"$@\"\n"
        guard FileManager.default.createFile(atPath: adapter.path, contents: Data(script.utf8),
                                            attributes: [.posixPermissions: 0o700]) else {
            throw WorkspaceFilesystemError.unavailable
        }
        defer { try? FileManager.default.removeItem(at: adapter) }
        let result = try await GitProcessRunner().run(executablePath: "/usr/bin/sftp",
            arguments: ["-q", "-S", adapter.path, "-b", "-", "--", connection.destination],
            workingDirectory: connection.localWorkingDirectory,
            environment: ProcessInfo.processInfo.environment.merging(["LC_ALL": "en_US.UTF-8"], uniquingKeysWith: { _, value in value }),
            stdin: Data((batch + "\n").utf8), timeout: 60)
        guard result.isSuccess else { throw WorkspaceFilesystemError.commandFailed(result.exitCode, result.stderrString) }
        return result.stdoutString
    }

    static func close(_ connection: GitSSHConnection) async {
        guard let socket = try? GitSSHControlSocket.path(for: connection, executablePath: connection.executablePath) else { return }
        _ = try? await GitProcessRunner().run(executablePath: connection.executablePath,
            arguments: ["-S", socket, "-O", "exit", "--", connection.destination],
            workingDirectory: connection.localWorkingDirectory, timeout: 3)
    }
}
