import Foundation

/// Uses the unified OMG command installed by +ssh. Never installs an editor or
/// sends keys to an unprepared remote session from an auxiliary SSH connection.
enum QuickInputRemoteDraftBridge {
    struct Target: Decodable {
        let session: String
        let tty: String
        var root: String?
        var commands: String?
        var generation: String?
    }

    static func command(_ action: String, session: String, request: String, tty: String? = nil, root: String? = nil,
                        generation: String? = nil) -> String {
        let arguments = [action, session, request] + (tty.map { [$0] } ?? []) + (generation.map { [$0] } ?? [])
        let prefix = root.map {
            "exec env OMG_REMOTE_ROOT=" + Ghostty.Shell.quote($0) + " python3 " + Ghostty.Shell.quote($0 + "/omg")
        } ?? "exec python3 \"$HOME/.local/share/oh-my-ghostty/remote/omg\""
        let script = prefix + " " +
            arguments.map(Ghostty.Shell.quote).joined(separator: " ")
        return SSHSessionTransport.shellCommand(script)
    }

    static func runtimeTarget(connection: GitSSHConnection, revision: String, pane: UUID) async throws -> Target {
        let command = "exec python3 - " + [revision, pane.uuidString].map(Ghostty.Shell.quote).joined(separator: " ")
        let result = try await SSHSessionTransport.run(connection: connection, command: command,
            stdin: Data(runtimeProbe.utf8), limit: 65_536, timeout: 10)
        guard result.isSuccess else {
            throw NSError(domain: "OMGRemoteDraft", code: result.stderrString.contains("OMG_RUNTIME_DRAFT_UNAVAILABLE") ? 1 : 2)
        }
        return try JSONDecoder().decode(Target.self, from: result.stdout)
    }

    static let runtimeProbe = #"""
    import hashlib, json, os, pathlib, re, subprocess, sys, uuid
    revision, pane = sys.argv[1:]
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', revision):
        raise ValueError('Invalid runtime revision')
    pane = str(uuid.UUID(pane))
    state = pathlib.Path.home() / '.omg/run' / hashlib.sha256(revision.encode()).hexdigest()[:12]
    def read(path):
        data = path.read_bytes()
        if len(data) > 65536: raise ValueError('Invalid runtime metadata')
        return json.loads(data)
    paths = [state / 'sessions' / (value + '.json') for value in (pane, pane.upper())]
    record = read(next(path for path in paths if path.exists()))
    if str(record.get('id', '')).lower() != pane or record.get('ended') is not None:
        raise ValueError('Runtime session is not active')
    session = 'omg-runtime-' + pane
    root = state / 'draft'
    metadata_path = root / 'sessions' / hashlib.sha256(session.encode()).hexdigest() / 'session.json'
    if not metadata_path.exists() or not (root / 'omg').is_file():
        raise ValueError('OMG_RUNTIME_DRAFT_UNAVAILABLE')
    metadata = read(metadata_path)
    if (metadata.get('protocol') != 1 or str(metadata.get('runtime_id', '')).lower() != pane
            or metadata.get('runtime_generation') != record.get('generation')):
        raise ValueError('Runtime session generation changed')
    pid = record.get('pid')
    if not isinstance(pid, int) or pid <= 1: raise ValueError('Invalid runtime process')
    tty = subprocess.run(['ps', '-o', 'tty=', '-p', str(pid)],
                         capture_output=True, text=True, check=True, timeout=3).stdout.strip()
    tty = tty if tty.startswith('/dev/') else '/dev/' + tty
    if tty != metadata.get('tty'): raise ValueError('Runtime TTY changed')
    result = subprocess.run(['ps', '-t', tty[5:], '-o', 'pgid=,tpgid=,args='],
                            capture_output=True, text=True, check=True, timeout=3)
    commands = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0] == fields[1] and int(fields[0]) > 0:
            tokens = fields[2].split()
            executable = os.path.basename(tokens[0])
            identity = tokens[:5] if executable in ('node', 'bun', 'deno') else tokens[:1]
            commands.append(' '.join(identity)[:4096])
            if len(commands) >= 8: break
    print(json.dumps(dict(session=session, tty=tty, root=str(root), commands='\n'.join(commands),
                         generation=record['generation'])))
    """#

    /// Probe the actual foreground process group, including agents launched by
    /// user aliases/functions which deliberately bypass our startup wrappers.
    static func foregroundAgent(connection: GitSSHConnection, session: String, tty: String) async throws -> SupportedAgent? {
        let arguments = [session, tty].map(Ghostty.Shell.quote).joined(separator: " ")
        let result = try await SSHSessionTransport.run(
            connection: connection, command: "exec python3 - " + arguments,
            stdin: Data(foregroundProbe.utf8), limit: 65_536, timeout: 10
        )
        guard result.isSuccess else { throw CocoaError(.fileReadUnknown) }
        return LocalAgentProcessDetector.detect(in: result.stdoutString)
    }

    static let foregroundProbe = #"""
    import hashlib, json, os, pathlib, subprocess, sys
    session, tty = sys.argv[1:]
    directory = pathlib.Path.home() / '.local/share/oh-my-ghostty/remote/sessions' / hashlib.sha256(session.encode()).hexdigest()
    metadata = json.loads((directory / 'session.json').read_text())
    if metadata.get('protocol') != 1 or metadata.get('tty') != tty:
        raise ValueError('Remote session mismatch')
    result = subprocess.run(['ps', '-t', tty[5:] if tty.startswith('/dev/') else tty, '-o', 'pgid=,tpgid=,args='],
                            capture_output=True, text=True, check=True, timeout=3)
    count = 0
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0] == fields[1] and int(fields[0]) > 0:
            # Only executable/runtime identity is needed; never return prompt args.
            tokens = fields[2].split()
            executable = os.path.basename(tokens[0])
            identity = tokens[:5] if executable in ('node', 'bun', 'deno') else tokens[:1]
            print(' '.join(identity)[:4096])
            count += 1
            if count >= 8:
                break
    """#

    static func begin(connection: GitSSHConnection, session: String, request: String, tty: String, root: String? = nil,
                      generation: String? = nil, replacement: String? = nil) async throws {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command(replacement == nil ? "draft-begin" : "draft-replace",
                session: session, request: request, tty: tty, root: root, generation: generation),
            stdin: replacement.map { Data($0.utf8) },
            limit: 8_192, timeout: 10
        )
        guard result.isSuccess,
              result.stdoutString.split(separator: "\n").contains("OMG_REMOTE_READY_V1") else {
            throw CocoaError(.fileReadUnknown)
        }
    }

    static func receive(connection: GitSSHConnection, session: String, request: String, root: String? = nil) async throws -> String {
        let result = try await SSHSessionTransport.run(
            connection: connection, command: command("draft-read", session: session, request: request, root: root),
            limit: 1_048_576 + 8_192, timeout: 10
        )
        return try decode(result)
    }

    static func decode(_ result: GitExecutionResult) throws -> String {
        let marker = Data("OMG_REMOTE_DRAFT_V1\n".utf8)
        guard result.isSuccess, let range = result.stdout.range(of: marker) else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = result.stdout[range.upperBound...]
        guard data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    static func finish(connection: GitSSHConnection, session: String, request: String, root: String? = nil) async {
        _ = try? await SSHSessionTransport.run(
            connection: connection, command: command("draft-finish", session: session, request: request, root: root),
            limit: 8_192, timeout: 5
        )
    }
}
