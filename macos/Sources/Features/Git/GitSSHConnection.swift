import Foundation

struct GitSSHConnection: Hashable, Codable, Sendable {
    let destination: String
    let options: [String]
    let workspaceID: String
    let executablePath: String
    let localWorkingDirectory: String

    private enum CodingKeys: String, CodingKey {
        case destination, options, workspaceID, executablePath, localWorkingDirectory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(destination: values.decode(String.self, forKey: .destination),
                      options: values.decode([String].self, forKey: .options),
                      workspaceID: values.decode(String.self, forKey: .workspaceID),
                      executablePath: values.decode(String.self, forKey: .executablePath),
                      localWorkingDirectory: values.decode(String.self, forKey: .localWorkingDirectory))
    }

    init(destination: String, options: [String] = [], workspaceID: String? = nil,
         executablePath: String = "/usr/bin/ssh", localWorkingDirectory: String = "/") throws {
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              !destination.contains(where: { $0.isWhitespace || $0 == "\0" }),
              options.allSatisfy({ !$0.contains("\0") }),
              !(workspaceID ?? "").contains("\0"), executablePath.hasPrefix("/"),
              !executablePath.contains("\0"), localWorkingDirectory.hasPrefix("/"),
              !localWorkingDirectory.contains("\0") else {
            throw GitExecutionError.executionFailed(GitL10n.text("Invalid SSH connection."))
        }
        self.executablePath = executablePath
        self.destination = destination
        self.options = options
        self.workspaceID = workspaceID ?? "ssh:\(destination)"
        self.localWorkingDirectory = localWorkingDirectory
    }

    init(session: PaneSessionContext) throws {
        let ssh: PaneSessionContext.SSH
        switch session.state {
        case .local:
            throw GitExecutionError.executionFailed(GitL10n.text("The pane has no SSH connection."))
        case .sshConnecting(let connection), .sshReady(let connection, _):
            ssh = connection
        }
        guard let directory = ssh.replay?.localWorkingDirectory ?? session.local.workingDirectory else {
            throw GitExecutionError.executionFailed(GitL10n.text("The original local SSH working directory is unavailable. Reconnect this SSH session."))
        }
        try self.init(session: ssh, localWorkingDirectory: directory)
    }

    init(session: PaneSessionContext.SSH, localWorkingDirectory: String = "/") throws {
        guard let replay = session.replay else {
            throw GitExecutionError.executionFailed(GitL10n.text("Exact SSH options are unavailable. Reconnect this SSH session to capture its original connection parameters."))
        }
        guard replay.version == 1, (replay.ssh as NSString).lastPathComponent == "ssh",
              let parsed = OpenSSHArguments(replay.args),
              parsed.interactiveDestination == session.transferTarget else {
            throw GitExecutionError.executionFailed(GitL10n.text("Git requires a replayable OpenSSH connection with recognized options."))
        }
        let directory = replay.localWorkingDirectory ?? localWorkingDirectory
        guard let executablePath = SSHProcessArguments.executablePath(for: replay.ssh, workingDirectory: directory) else {
            throw GitExecutionError.executionFailed(GitL10n.text("The captured SSH executable was not found on the host application's PATH."))
        }
        let values = "BIPpliFJSbcmo"
        let flags = "46AaCKk"
        let options = parsed.options.filter { $0.value == nil ? flags.contains($0.name) : values.contains($0.name) }
            .flatMap(\.arguments)
        try self.init(destination: session.transferTarget, options: options, workspaceID: "ssh:\(session.alias)",
                      executablePath: executablePath, localWorkingDirectory: directory)
    }

    var identity: String { ([destination, workspaceID, executablePath, localWorkingDirectory] + options).joined(separator: "\0") }
    var displayEndpoint: String {
        let parsed = OpenSSHArguments(options + [destination])
        let port = parsed?.options.first(where: { $0.name == "p" })?.value
        let jump = parsed?.options.first(where: { $0.name == "J" })?.value
        let endpoint = destination + (port.map { ":" + $0 } ?? "")
        return jump.map { $0 + " → " + endpoint } ?? endpoint
    }
    var arguments: [String] { arguments(controlSocket: nil) }

    func arguments(controlSocket: String?) -> [String] {
        // These options precede user config/replay options: OpenSSH uses the first value.
        ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
         "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "SessionType=default",
         "-o", "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "StdinNull=no",
         "-o", controlSocket == nil ? "ControlMaster=no" : "ControlMaster=auto",
         "-o", controlSocket == nil ? "ControlPersist=no" : "ControlPersist=60"] + options +
            (controlSocket.map { ["-S", $0] } ?? []) + ["--", destination]
    }
}

struct SSHGitExecutor: GitExecutor {
    let connection: GitSSHConnection
    var sshPath: String?
    var multiplexing = true
    static let marker = Data("\u{1e}OMG-GIT-v1\u{1f}".utf8)

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func execute(arguments: [String], workingDirectory: String, stdin: Data?, maxOutputBytes: Int?) async throws -> GitExecutionResult {
        guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw GitExecutionError.executionFailed(GitL10n.text("Invalid remote Git path or argument."))
        }
        let command = "cd " + Self.quote(workingDirectory) + " || exit; " +
            "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; " +
            "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; " +
            "exec env LC_ALL=C GIT_TERMINAL_PROMPT=0 git " + arguments.map(Self.quote).joined(separator: " ")
        return try await run(command, stdin: stdin, limit: maxOutputBytes)
    }

    func readWorkingFile(at path: String, root: String, limit: Int) async throws -> Data {
        guard path.hasPrefix("/"), root.hasPrefix("/"), !path.contains("\0"), !root.contains("\0") else {
            throw GitExecutionError.executionFailed(GitL10n.text("Invalid remote file path."))
        }
        let script = """
        file=\(Self.quote(path))
        root=$(cd \(Self.quote(root)) && pwd -P) || exit
        parent=$(cd "${file%/*}" && pwd -P) || exit
        root=${root%/}
        case "$parent" in "$root"|"$root"/*) ;; *) echo 'File is outside this worktree.' >&2; exit 1;; esac
        if [ -L "$file" ] || [ ! -f "$file" ]; then echo 'Use patch view for symlinks or non-regular files.' >&2; exit 1; fi
        exec head -c \(limit + 1) "$file"
        """
        let result = try await run(script, stdin: nil, limit: limit + 1)
        guard result.isSuccess else { throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString) }
        guard result.stdout.count <= limit else { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return result.stdout
    }

    private func run(_ script: String, stdin: Data?, limit: Int?) async throws -> GitExecutionResult {
        let framed = "printf '\\036OMG-GIT-v1\\037'; " + script
        // Only a quote-free base64 alphabet crosses the login shell. The
        // decoded POSIX script is a -c argument, leaving SSH stdin for git commit.
        let command = SSHSessionTransport.shellCommand(framed)
        let executable = sshPath ?? connection.executablePath
        let result = try await SSHSessionTransport.run(connection: connection, command: command,
            stdin: stdin, limit: limit.map { $0 + 64 * 1024 }, executable: executable, multiplexing: multiplexing)
        guard result.exitCode != 255 else {
            throw GitExecutionError.executionFailed(GitL10n.text("SSH connection failed. If a write was in progress, refresh before retrying; its outcome may be unknown.\n") + result.stderrString)
        }
        guard let marker = result.stdout.range(of: Self.marker) else {
            throw GitExecutionError.executionFailed(GitL10n.text("SSH did not start the Git command.\n") + result.stderrString)
        }
        let output = Data(result.stdout[marker.upperBound...])
        if let limit, output.count > limit { throw GitExecutionError.outputLimitExceeded(maxBytes: limit) }
        return GitExecutionResult(exitCode: result.exitCode, stdout: output, stderr: result.stderr)
    }
}
