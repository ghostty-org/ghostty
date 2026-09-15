import Darwin
import Foundation
import Testing
@testable import Ghostty

@MainActor
final class GitSSHTestServer {
    let root: URL
    let process: Process
    let connection: GitSSHConnection

    init() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-ssh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = root
        self.process = Process()
        for key in ["host_key", "client_key"] {
            let result = try await GitProcessRunner().run(executablePath: "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent(key).path],
                workingDirectory: root.path)
            try #require(result.isSuccess)
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GitExecutionError.executionFailed("Cannot allocate test port.") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        Darwin.close(fd)
        try #require(bound == 0 && named == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let hostPublicKey = try String(contentsOf: root.appendingPathComponent("host_key.pub"), encoding: .utf8)
        try ("[127.0.0.1]:\(port) " + hostPublicKey).write(to: root.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.path)/host_key
        PidFile \(root.path)/pid
        AuthorizedKeysFile \(root.path)/client_key.pub
        AllowUsers \(NSUserName())
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        Subsystem sftp internal-sftp
        LogLevel ERROR
        """
        let configURL = root.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        connection = try GitSSHConnection(destination: NSUserName() + "@127.0.0.1",
            options: ["-F", "/dev/null", "-p", String(port), "-i", root.appendingPathComponent("client_key").path,
                      "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=" + root.appendingPathComponent("known_hosts").path,
                      "-o", "StrictHostKeyChecking=yes"], workspaceID: "ssh:test-remote")
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", configURL.path, "-E", root.appendingPathComponent("sshd.log").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            var ready = false
            for _ in 0..<30 {
                if let result = try? await SSHGitExecutor(connection: connection).execute(
                    arguments: ["--version"], workingDirectory: "/", stdin: nil, maxOutputBytes: 4096), result.isSuccess {
                    ready = true; break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(ready, "Isolated loopback OpenSSH server must accept its pinned test key")
        } catch {
            process.terminate()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func disconnect() {
        if process.isRunning {
            // Stopping only the listener leaves authenticated sshd children
            // (and therefore multiplexed transports) alive. Stop this fixture's
            // accepted sessions too, to model an actual server disconnect.
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-TERM", "-P", String(process.processIdentifier)]
            children.standardOutput = FileHandle.nullDevice
            children.standardError = FileHandle.nullDevice
            if (try? children.run()) != nil { children.waitUntilExit() }
            process.terminate()
            process.waitUntilExit()
        }
    }

    func stop() {
        disconnect()
        try? FileManager.default.removeItem(at: root)
    }

    func session(directory: String) -> PaneSessionContext {
        var session = PaneSessionContext(workingDirectory: root.path, terminalTitle: "Test")
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false,
                                         terminfo: false, cache: false, args: connection.options + [connection.destination])
        let hex = directory.utf8.map { String(format: "%02x", $0) }.joined()
        session.apply(.init(action: .start, id: "omg-ssh-test", metadata: "type=remote;targethost=test-remote;cwdhex=" + hex),
                      currentWorkingDirectory: root.path, currentTerminalTitle: "Test", sshReplay: replay)
        return session
    }
}

@MainActor
struct SSHGitExecutorTests {
    @Test func privateMultiplexedConnectionReusesTransportAndKeepsEndpointsIsolated() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let remote = SSHGitExecutor(connection: server.connection)
        let arguments = ["-c", "alias.transport=!printf '%s' \"$SSH_CONNECTION\"", "transport"]
        let first = try await remote.execute(arguments: arguments, workingDirectory: server.root.path)
        try #require(first.isSuccess && !first.stdout.isEmpty)
        let start = Date()
        for _ in 0..<5 {
            let result = try await remote.execute(arguments: arguments, workingDirectory: server.root.path)
            #expect(result.isSuccess && result.stdout == first.stdout)
        }
        let reused = Date().timeIntervalSince(start) / 5
        let cold = SSHGitExecutor(connection: server.connection, multiplexing: false)
        let coldStart = Date()
        for _ in 0..<3 {
            let result = try await cold.execute(arguments: arguments, workingDirectory: server.root.path)
            #expect(result.isSuccess && result.stdout != first.stdout)
        }
        let fresh = Date().timeIntervalSince(coldStart) / 3
        print("SSH transport benchmark: fresh=\(fresh)s reused=\(reused)s per command")
        async let left = remote.execute(arguments: arguments, workingDirectory: server.root.path)
        async let right = remote.execute(arguments: arguments, workingDirectory: server.root.path)
        let pair = try await (left, right)
        #expect(pair.0.stdout == first.stdout && pair.1.stdout == first.stdout)
        let socket = try GitSSHControlSocket.path(for: server.connection, executablePath: "/usr/bin/ssh")
        #expect(socket.utf8.count < 104)
        let other = try GitSSHConnection(destination: server.connection.destination,
            options: server.connection.options, localWorkingDirectory: server.root.path)
        #expect(try GitSSHControlSocket.path(for: other, executablePath: "/usr/bin/ssh") != socket)
        #expect(try GitSSHControlSocket.path(for: server.connection, executablePath: "/different/ssh") != socket)
    }

    @Test func connectionPreservesRoutingOptionsWithoutRepeatingInteractiveSideEffects() throws {
        let ssh = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil,
            replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false,
                          args: ["-tt", "-A", "-p2222", "-J", "jump", "-i", "/key path", "-L", "9000:localhost:80", "user@host"]),
            transferTarget: "user@host", localProcessGroupID: nil)
        let connection = try GitSSHConnection(session: ssh)
        #expect(connection.options == ["-A", "-p", "2222", "-J", "jump", "-i", "/key path"])
        #expect(connection.arguments.contains("ClearAllForwardings=yes"))
        #expect(connection.arguments.contains("RemoteCommand=none"))
        #expect(!connection.arguments.contains("-tt"))
        let other = try GitSSHConnection(destination: "user@host", options: ["-p", "2223"])
        let first = GitRepositoryIdentity(target: .ssh(connection),
                                          worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let second = GitRepositoryIdentity(target: .ssh(other),
                                           worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        #expect(first.stateKey != second.stateKey && first.stateKey != "/repo")
    }

    @Test func sharedSSHParserPreservesCombinedValueOptionsAndRejectsUnknownOptions() throws {
        let arguments = ["-4vp2222", "-Ai", "/key path", "-oProxyCommand=proxy %h %p", "--", "user@host"]
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: arguments)
        let ssh = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil, replay: replay,
                                         transferTarget: "user@host", localProcessGroupID: nil)
        #expect(ForegroundSSHProcessDetector.interactiveDestination(arguments) == "user@host")
        let connection = try GitSSHConnection(session: ssh)
        #expect(connection.options == ["-4", "-p", "2222", "-A", "-i", "/key path", "-o", "ProxyCommand=proxy %h %p"])
        for invalid in [["-Z", "host"], ["-vZ", "host"], ["-p"], ["-vp", "2222"], ["-vN", "host"], ["host", "uptime"]] {
            #expect(ForegroundSSHProcessDetector.interactiveDestination(invalid) == nil)
            let rejected = PaneSessionContext.SSH(connectionID: "test", alias: "host", serverID: nil,
                replay: .init(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false, cache: false, args: invalid),
                transferTarget: "host", localProcessGroupID: nil)
            #expect(throws: (any Error).self) { try GitSSHConnection(session: rejected) }
        }
    }

    @Test func executableResolutionUsesCapturedDirectoryAndExplicitSearchPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("custom-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = bin.appendingPathComponent("ssh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(SSHProcessArguments.executablePath(for: "ssh", workingDirectory: root.path, searchPath: "custom-bin:/usr/bin") == executable.path)
        #expect(SSHProcessArguments.executablePath(for: "custom-bin/ssh", workingDirectory: root.path) == executable.path)
        #expect(SSHProcessArguments.executablePath(for: "ssh", workingDirectory: root.path, searchPath: "missing") == nil)
        #expect(SSHProcessArguments.workingDirectory(pid: getpid()) == FileManager.default.currentDirectoryPath)

        let replay = SSHReplayDescriptor(version: 1, ssh: "custom-bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: ["host"], localWorkingDirectory: root.path)
        var session = PaneSessionContext(workingDirectory: "/stale-local-directory", terminalTitle: "Test")
        session.observeForegroundSSH(alias: "host", transferTarget: "host", processGroupID: 123,
                                     currentWorkingDirectory: nil, currentTerminalTitle: "Test",
                                     remoteWorkingDirectory: "/remote", replay: replay)
        let connection = try GitSSHConnection(session: session)
        #expect(connection.localWorkingDirectory == root.path)
        #expect(connection.executablePath == executable.path)
        let decoded = try JSONDecoder().decode(SSHReplayDescriptor.self, from: JSONEncoder().encode(replay))
        #expect(decoded.localWorkingDirectory == root.path)
    }

    @Test func replayUsesTheCapturedLaunchDirectoryWithoutChangingItsCaller() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-replay-\(UUID().uuidString)")
        let original = root.appendingPathComponent("original ' cwd")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("omg")
        try "#!/bin/sh\npwd -P\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
                                         cache: false, args: ["-F", "./config", "host"], localWorkingDirectory: original.path)
        let command = try #require(replay.command(executablePath: executable.path))
        let result = try await GitProcessRunner().run(executablePath: "/bin/sh", arguments: ["-c", command + "; pwd -P"],
                                                      workingDirectory: root.path)
        #expect(result.isSuccess)
        let observed = result.stdoutString.split(separator: "\n").map(String.init)
        try #require(observed.count == 2)
        for (actual, expected) in zip(observed, [original, root]) {
            let actualAttributes = try FileManager.default.attributesOfItem(atPath: actual)
            let expectedAttributes = try FileManager.default.attributesOfItem(atPath: expected.path)
            #expect(actualAttributes[.systemNumber] as? NSNumber == expectedAttributes[.systemNumber] as? NSNumber)
            #expect(actualAttributes[.systemFileNumber] as? NSNumber == expectedAttributes[.systemFileNumber] as? NSNumber)
        }
    }

    @Test func relativeSSHConfigurationIdentityAndProxyKeepTheOriginalLaunchDirectory() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let portIndex = try #require(server.connection.options.firstIndex(of: "-p"))
        let port = server.connection.options[portIndex + 1]
        let configuration = """
        Host history-review
            HostName 127.0.0.1
            User \(NSUserName())
            Port \(port)
            IdentitiesOnly yes
            UserKnownHostsFile ./known_hosts
            StrictHostKeyChecking yes
        """
        try configuration.write(to: server.root.appendingPathComponent("client_config"), atomically: true, encoding: .utf8)
        let proxy = server.root.appendingPathComponent("proxy")
        try "#!/bin/sh\nexec /usr/bin/nc \"$1\" \"$2\"\n".write(to: proxy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: proxy.path)
        let replay = SSHReplayDescriptor(version: 1, ssh: "/usr/bin/ssh", forwardEnv: false, terminfo: false,
            cache: false, args: ["-F", "./client_config", "-i", "./client_key", "-o", "ProxyCommand=./proxy %h %p", "history-review"])
        var session = PaneSessionContext(workingDirectory: server.root.path, terminalTitle: "Test")
        session.observeForegroundSSH(alias: "history-review", transferTarget: "history-review", processGroupID: 123,
                                     currentWorkingDirectory: server.root.path, currentTerminalTitle: "Test",
                                     remoteWorkingDirectory: "/", replay: replay)
        let connection = try GitSSHConnection(session: session)
        #expect(connection.localWorkingDirectory == server.root.path)
        let result = try await SSHGitExecutor(connection: connection).execute(arguments: ["--version"], workingDirectory: "/")
        #expect(result.isSuccess && result.stdoutString.hasPrefix("git version"))
    }

    @Test func rawProcessArgumentsPreserveBoundariesAndDoNotReadEnvironment() throws {
        let arguments = ["ssh", "-i", "/key path/with'quote", "user@host"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/usr/bin/ssh\0\0".utf8))
        for argument in arguments { bytes.append(Data((argument + "\0").utf8)) }
        bytes.append(Data("PRIVATE_ENV=not-an-argument\0".utf8))
        #expect(SSHProcessArguments.decode(bytes) == arguments)
        #expect(SSHProcessArguments.read(pid: getpid())?.isEmpty == false)
        let unknown = PaneSessionContext.SSH(connectionID: "old", alias: "host", serverID: nil, replay: nil,
                                             transferTarget: "host", localProcessGroupID: 123)
        #expect(throws: (any Error).self) { try GitSSHConnection(session: unknown) }
        let unbound = PaneSessionContext.SSH(connectionID: "omg-ssh-unbound", alias: "host", serverID: nil,
                                             replay: nil, transferTarget: "host", localProcessGroupID: nil)
        #expect(throws: (any Error).self) { try GitSSHConnection(session: unbound) }
        #expect(GitRepositoryService.absolutePath("../.git", relativeTo: "/remote/repo/sub/") == "/remote/repo/.git")
    }

    @Test func rejectedCommandWithLargeStdinDoesNotBlockOrSignalTheApp() async throws {
        let result = try await GitProcessRunner().run(executablePath: "/bin/sh",
            arguments: ["-c", "exit 1"], workingDirectory: "/", stdin: Data(repeating: 42, count: 1024 * 1024))
        #expect(result.exitCode == 1)
    }

    @Test func framedTransportPreservesNULAndStdinAndQuotesPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        printf 'login banner\n'
        for last do :; done
        exec /bin/sh -c "$last"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let connection = try GitSSHConnection(destination: "stub")
        let executor = SSHGitExecutor(connection: connection, sshPath: stub.path)
        let path = root.appendingPathComponent("quotes ' 中文 $(nope)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let initialized = try await executor.execute(arguments: ["init", "-b", "main"], workingDirectory: path.path)
        #expect(initialized.isSuccess)
        let hash = try await executor.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: Data("body ' \n 中文".utf8))
        #expect(hash.isSuccess && hash.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).count == 40)
        try Data("remote text".utf8).write(to: path.appendingPathComponent("new file"))
        let files = try await executor.execute(arguments: ["ls-files", "--others", "-z"], workingDirectory: path.path)
        #expect(files.stdout == Data("new file\0".utf8))
        #expect(try await executor.readWorkingFile(at: path.appendingPathComponent("new file").path, root: path.path, limit: 100) == Data("remote text".utf8))
        await #expect(throws: (any Error).self) {
            try await executor.readWorkingFile(at: path.appendingPathComponent("new file").path, root: path.path, limit: 2)
        }
    }

    @Test func realSSHProvidesReadWriteAndDiffParityWithoutLocalPathFallback() async throws {
        let server = try await GitSSHTestServer()
        defer { server.stop() }
        let path = server.root.appendingPathComponent("repo ' 中文")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let remote = SSHGitExecutor(connection: server.connection)
        for args in [["init", "-b", "main"], ["config", "user.name", "SSH Test"], ["config", "user.email", "ssh@example.com"],
                     ["config", "commit.gpgSign", "false"], ["config", "core.hooksPath", path.path + "/.git/hooks"]] {
            #expect(try await remote.execute(arguments: args, workingDirectory: path.path).isSuccess)
        }
        let payload = Data((0..<200_000).map { UInt8($0 % 256) })
        let remoteHash = try await remote.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        let localHash = try await LocalGitExecutor().execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        #expect(remoteHash.stdout == localHash.stdout)
        let status = await GitRepositoryService().resolveStatus(workingDirectory: path.path, session: server.session(directory: path.path))
        let repository = try #require(status.repository)
        #expect(repository.sshConnection?.options == server.connection.options)
        #expect(repository.stateKey != path.path)
        try Data("let number = 1\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let mutations = GitMutationService()
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.commit("first ' 中文\n\nBody"), in: repository)
        let history = GitHistoryService()
        let snapshot = try await history.captureSnapshot(for: repository, scope: .allBranches)
        let page = try await history.loadPage(snapshot: snapshot, repository: repository, offset: 0)
        #expect(page.commits.first?.subject == "first ' 中文")
        let diff = GitDiffService()
        let commit = try #require(page.commits.first?.id)
        let changed = try await diff.listFiles(for: repository, target: .commit(commit))
        let original = try await diff.sourceVersions(for: changed.files[0], repository: repository, target: .commit(commit))
        #expect(original.before.isEmpty && original.after == "let number = 1\n")
        try Data("let number = 2\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let unstaged = try await diff.listFiles(for: repository, target: .unstaged)
        let source = try await diff.sourceVersions(for: unstaged.files[0], repository: repository, target: .unstaged)
        #expect(source.before == "let number = 1\n" && source.after == "let number = 2\n")
        try await mutations.perform(.discard(unstaged.files[0], staged: false), in: repository)
        #expect(try String(contentsOf: path.appendingPathComponent("file.swift"), encoding: .utf8) == "let number = 1\n")
        try Data("let number = 2\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        let unrelated = path.appendingPathComponent("unrelated [two]*.txt")
        try Data("untracked\n".utf8).write(to: unrelated)
        let scoped = try await diff.workingTreeFiles(for: repository, paths: ["file.swift"])
        #expect(scoped.staged.isEmpty && scoped.unstaged.map(\.path) == ["file.swift"])
        let literal = try await diff.workingTreeFiles(for: repository, paths: [unrelated.lastPathComponent])
        #expect(literal.unstaged.map(\.path) == [unrelated.lastPathComponent])
        try FileManager.default.removeItem(at: unrelated)
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.unstage(["file.swift"]), in: repository)
        #expect(try await diff.listFiles(for: repository, target: .staged).files.isEmpty)
        let statusFiles = try await diff.workingTreeFiles(for: repository)
        #expect(statusFiles.staged.isEmpty && statusFiles.unstaged.map(\.path) == ["file.swift"])
        var checkboxTimings: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            try await mutations.perform(.stage(["file.swift"]), in: repository)
            let stagedFiles = try await diff.workingTreeFiles(for: repository)
            #expect(stagedFiles.staged.map(\.path) == ["file.swift"] && stagedFiles.unstaged.isEmpty)
            checkboxTimings.append(Date().timeIntervalSince(start) * 1000)
            try await mutations.perform(.unstage(["file.swift"]), in: repository)
        }
        print("SSH checkbox benchmark (loopback, mutation + refreshed status): median=\(checkboxTimings.sorted()[2])ms")
        try await mutations.perform(.stage(["file.swift"]), in: repository)
        try await mutations.perform(.commit("second"), in: repository)
        try await mutations.perform(.create(name: "feature/ssh", start: "refs/heads/main"), in: repository)
        try await mutations.perform(.checkout("main"), in: repository)
        let bare = server.root.appendingPathComponent("upstream.git").path
        #expect(try await remote.execute(arguments: ["init", "--bare", bare], workingDirectory: path.path).isSuccess)
        #expect(try await remote.execute(arguments: ["remote", "add", "origin", bare], workingDirectory: path.path).isSuccess)
        try await mutations.perform(.push(branch: "feature/ssh", remote: "origin", destination: "review/ssh"), in: repository)
        try await mutations.perform(.setUpstream(branch: "feature/ssh", upstream: "refs/remotes/origin/review/ssh"), in: repository)
        let branches = try await GitRepositoryService().branches(for: repository)
        #expect(branches.first(where: { $0.name == "feature/ssh" })?.upstream == "origin/review/ssh")
        #expect(branches.first(where: { $0.isCurrent })?.name == "main")

        // The same path on local and SSH surfaces must have independent drafts,
        // selected tabs and expanded commits, while using the same native provider.
        let registry = InspectorRegistry()
        let provider = BuiltInGitInspectorProvider(registry: registry)
        try provider.register()
        let tab = UUID()
        let surface = UUID()
        let localContext = InspectorPaneContext(tabID: tab, surfaceID: surface, title: "Local", workingDirectory: path.path)
        let sshContext = InspectorPaneContext(tabID: tab, surfaceID: surface, title: "SSH", workingDirectory: path.path,
                                              session: server.session(directory: path.path))
        defer { registry.presentationDidChange(to: nil, context: localContext) }
        func send(_ action: InspectorGitAction, in context: InspectorPaneContext) {
            registry.performAction(paneID: BuiltInGitInspectorProvider.paneID, action: .init(context: context, kind: .gitAction(action)))
        }
        func waitFor(_ context: InspectorPaneContext, _ predicate: (InspectorGitContent) -> Bool) async throws -> InspectorGitContent {
            for _ in 0..<400 {
                if case .git(let value) = registry.content(for: BuiltInGitInspectorProvider.paneID, context: context),
                   !value.isLoading, !value.history.isLoading, value.operation == nil, predicate(value) { return value }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw GitExecutionError.executionFailed("SSH provider did not publish expected state.")
        }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: localContext)
        _ = try await waitFor(localContext) { $0.repository != nil }
        send(.updateCommitDraft("local draft"), in: localContext)
        send(.selectTab(.changes), in: localContext)
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: sshContext)
        let remoteState = try await waitFor(sshContext) { $0.repository?.sshConnection != nil }
        #expect(remoteState.commitDraft.isEmpty && remoteState.activeTab == .history)
        #expect(remoteState.connectionLabel == server.connection.destination)
        let remoteCommit = try #require(remoteState.history.commits.first?.id)
        send(.openCommit(remoteCommit), in: sshContext)
        let expanded = try await waitFor(sshContext) { $0.expandedCommits[remoteCommit]?.metadata != nil }
        #expect(expanded.expandedCommits[remoteCommit]?.files.first?.path == "file.swift")
        try Data("let number = 3\n".utf8).write(to: path.appendingPathComponent("file.swift"))
        send(.refresh, in: sshContext)
        let updated = try await waitFor(sshContext) { !$0.workingTree.unstaged.isEmpty }
        send(.setFileStaged(updated.workingTree.unstaged[0], true), in: sshContext)
        _ = try await waitFor(sshContext) { !$0.workingTree.staged.isEmpty }
        send(.updateCommitDraft("remote draft"), in: sshContext)
        send(.commitStaged, in: sshContext)
        _ = try await waitFor(sshContext) { $0.commitDraft.isEmpty && $0.history.commits.count == 3 }
        registry.presentationDidChange(to: BuiltInGitInspectorProvider.paneID, context: localContext)
        let restored = try await waitFor(localContext) { $0.repository?.target == .local }
        #expect(restored.commitDraft == "local draft" && restored.activeTab == .changes)
        #expect(restored.expandedCommits.isEmpty)
        registry.presentationDidChange(to: nil, context: localContext)
        server.disconnect()
        await #expect(throws: (any Error).self) {
            try await remote.execute(arguments: ["hash-object", "--stdin"], workingDirectory: path.path, stdin: payload)
        }
        let disconnected = await GitRepositoryService().resolveStatus(workingDirectory: path.path, session: server.session(directory: path.path))
        guard case .error = disconnected else { Issue.record("A disconnected SSH session must never fall back to local Git"); return }

    }
}
