import AppKit
import CryptoKit
import Darwin
import Foundation

struct SessionRuntimePolicy: Codable, Equatable, Sendable {
    var detachedTTLSeconds = 259_200
    var expiresAt: Int?
    var closeOnAgentDone = false
    var agentDoneGraceSeconds = 60
    var terminateGraceSeconds = 5
    var hostIdleSeconds = 300
    var recordRetentionSeconds = 604_800

    enum CodingKeys: String, CodingKey {
        case detachedTTLSeconds = "detached_ttl_seconds"
        case expiresAt = "expires_at"
        case closeOnAgentDone = "close_on_agent_done"
        case agentDoneGraceSeconds = "agent_done_grace_seconds"
        case terminateGraceSeconds = "terminate_grace_seconds"
        case hostIdleSeconds = "host_idle_seconds"
        case recordRetentionSeconds = "record_retention_seconds"
    }
}

enum SessionRuntimeConnectionState: Equatable, Sendable {
    case connecting(attempt: Int)
    case reconnecting(attempt: Int, retryInMilliseconds: Int?)
    case attention(attempt: Int, message: String?)
    case ready
    case failed(message: String?, retryable: Bool = true)
    case exited(exitCode: Int)

    private struct Payload: Decodable {
        let state: String
        var attempt: Int?
        var retryInMS: Int?
        var message: String?
        var retryable: Bool?
        var exitCode: Int?

        enum CodingKeys: String, CodingKey {
            case state, attempt, message, retryable
            case retryInMS = "retry_in_ms"
            case exitCode = "exit_code"
        }
    }

    static func decode(_ metadata: String) -> Self? {
        guard metadata.utf8.count <= 8_192,
              let data = metadata.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let attempt = max(0, min(payload.attempt ?? 0, 1_000_000))
        let retry = payload.retryInMS.map { max(0, min($0, 86_400_000)) }
        let message = payload.message.map { value in
            String(value.unicodeScalars.prefix(2_048).map {
                CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
            })
        }
        if payload.state == "exited" {
            guard let exitCode = payload.exitCode else { return nil }
            return .exited(exitCode: exitCode)
        }
        return switch payload.state {
        case "connecting": .connecting(attempt: attempt)
        case "reconnecting": .reconnecting(attempt: attempt, retryInMilliseconds: retry)
        case "attention": .attention(attempt: attempt, message: message)
        case "ready": .ready
        case "failed": .failed(message: message, retryable: payload.retryable ?? true)
        default: nil
        }
    }

    var canRetry: Bool {
        switch self {
        case .ready, .connecting, .exited: false
        case .reconnecting(_, let delay): delay != nil
        case .attention: true
        case .failed(_, let retryable): retryable
        }
    }

    var attempt: Int {
        switch self {
        case .connecting(let attempt), .attention(let attempt, _): attempt
        case .reconnecting(let attempt, _): attempt
        case .ready, .failed, .exited: 0
        }
    }
}

struct SessionRuntimeDescriptor: Codable, Equatable, Sendable {
    static let environmentKey = "OMG_SESSION_RUNTIME_DESCRIPTOR"
    static let localRuntimeEnvironmentKey = "OMG_RUNTIME_LOCAL"
    static let attachExistingEnvironmentKey = "OMG_RUNTIME_ATTACH_EXISTING"
    /// Nil identifies a local host runtime. Older archives always contain an SSH connection.
    var connection: GitSSHConnection?
    var revision: String
    var policy: SessionRuntimePolicy
    var localWorkingDirectory: String?
    /// Used only when creating this pane. Reattach never changes a live cwd.
    var initialWorkingDirectory: String?

    var isLocal: Bool { connection == nil }
    var displayEndpoint: String {
        connection?.displayEndpoint ?? localWorkingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    var launchWorkingDirectory: String {
        connection?.localWorkingDirectory ?? localWorkingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func validWorkingDirectory(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 4096, !value.contains("\0") else { return nil }
        return value
    }

    var identity: String {
        let endpoint = connection?.identity ?? "local:\(OMGApplicationEnvironment.applicationSupportURL().path)"
        return SHA256.hash(data: Data((endpoint + "\0" + revision).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func configure(_ config: inout Ghostty.SurfaceConfiguration) throws {
        config.environmentVariables[Self.environmentKey] = String(data: try JSONEncoder().encode(self), encoding: .utf8)
        config.environmentVariables[Self.localRuntimeEnvironmentKey] = isLocal ? "1" : ""
        config.environmentVariables[Self.attachExistingEnvironmentKey] = ""
    }

    func configureAttachExisting(_ config: inout Ghostty.SurfaceConfiguration) throws {
        try configure(&config)
        config.environmentVariables[Self.attachExistingEnvironmentKey] = "1"
    }

    func openRequest(pane: UUID, attachExisting: Bool) throws -> String {
        struct Request: Encodable {
            let id: String
            let policy: SessionRuntimePolicy
            let create: Bool
            let cwd: String?
        }
        let directory = initialWorkingDirectory ?? (isLocal ? localWorkingDirectory : nil)
        let data = try JSONEncoder().encode(Request(id: pane.uuidString.lowercased(), policy: policy,
            create: !attachExisting, cwd: attachExisting ? nil : Self.validWorkingDirectory(directory)))
        guard let result = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}

enum SessionRuntimeRetryCommand {
    static func arguments(socket: URL, interactive: Bool) -> [String] {
        ["retry-local", socket.path] + (interactive ? ["--interactive"] : [])
    }
}

enum SessionRuntimeRestorationPolicy {
    static func attachesSavedRuntime(for mode: OMGStartupMode) -> Bool {
        mode == .restoreSessions
    }

    static func createsFreshPaneIDsFromSavedState(for mode: OMGStartupMode) -> Bool {
        mode == .restoreTabs
    }
}

@MainActor
struct SessionRuntimeCloseCopy: Equatable {
    let hasPersistentRuntime: Bool
    let hasOrdinaryProcess: Bool

    init(hasPersistentRuntime: Bool, hasOrdinaryProcess: Bool) {
        self.hasPersistentRuntime = hasPersistentRuntime
        self.hasOrdinaryProcess = hasOrdinaryProcess
    }

    init(surfaces: [Ghostty.SurfaceView]) {
        hasPersistentRuntime = surfaces.contains { $0.runtimeDescriptor != nil }
        hasOrdinaryProcess = surfaces.contains { $0.runtimeDescriptor == nil }
    }

    func windowMessage(allWindows: Bool, strings: SettingsStrings) -> String {
        switch (hasPersistentRuntime, hasOrdinaryProcess) {
        case (true, true):
            return strings.t(
                allWindows
                    ? "Ordinary terminal processes will be terminated; persistent sessions will continue in the background."
                    : "Ordinary terminal processes in this window will be terminated; persistent sessions will continue in the background.",
                allWindows
                    ? "普通终端进程将被终止；持久会话会在后台继续运行。"
                    : "此窗口中的普通终端进程将被终止；持久会话会在后台继续运行。"
            )
        case (true, false):
            return strings.t(
                allWindows
                    ? "Persistent sessions will continue running in the background."
                    : "Persistent sessions in this window will continue running in the background.",
                allWindows
                    ? "持久会话会在后台继续运行。"
                    : "此窗口中的持久会话会在后台继续运行。"
            )
        case (false, true):
            return strings.t(
                allWindows
                    ? "All terminal sessions will be terminated."
                    : "All terminal sessions in this window will be terminated.",
                allWindows
                    ? "所有终端会话都将被终止。"
                    : "此窗口中的所有终端会话都将被终止。"
            )
        case (false, false):
            return ""
        }
    }

    func quitMessage(multipleWindows: Bool, strings: SettingsStrings) -> String {
        switch (hasPersistentRuntime, hasOrdinaryProcess) {
        case (true, true):
            return strings.t(
                multipleWindows
                    ? "If you quit without reviewing windows, ordinary terminal processes will be terminated; persistent sessions will continue in the background."
                    : "Ordinary terminal processes will be terminated; persistent sessions will continue in the background.",
                multipleWindows
                    ? "如果不检查窗口就退出，普通终端进程将被终止；持久会话会在后台继续运行。"
                    : "普通终端进程将被终止；持久会话会在后台继续运行。"
            )
        case (true, false):
            return strings.t(
                "Persistent sessions will continue running in the background after OMG quits.",
                "退出 OMG 后，持久会话会在后台继续运行。"
            )
        case (false, true):
            return strings.t(
                multipleWindows
                    ? "If you don't review your windows, any running processes will be terminated."
                    : "The terminal still has a running process. If you quit, the process will be killed.",
                multipleWindows
                    ? "如果不检查窗口，所有运行中的进程都将被终止。"
                    : "终端仍有运行中的进程。退出后，该进程将被终止。"
            )
        case (false, false):
            return ""
        }
    }

    func quitButtonTitle(multipleWindows: Bool, strings: SettingsStrings) -> String {
        if hasPersistentRuntime {
            return strings.t("Quit", "退出")
        }
        return multipleWindows
            ? strings.t("Terminate Processes", "终止进程")
            : strings.t("Terminate", "终止")
    }
}

final class TerminalPaneIDRemapping {
    var ids: [String: String] = [:]
}

enum TerminalPaneIDDecodeContext {
    private static let key = "omg.terminal.restore-pane-id-remapping"

    static func withRemapping<T>(
        _ remapping: TerminalPaneIDRemapping,
        decode: () throws -> T
    ) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = remapping
        defer {
            if let previous {
                dictionary[key] = previous
            } else {
                dictionary.removeObject(forKey: key)
            }
        }
        return try decode()
    }

    static func record(archivedID: UUID, restoredID: UUID) {
        guard archivedID != restoredID,
              let remapping = Thread.current.threadDictionary[key] as? TerminalPaneIDRemapping else { return }
        remapping.ids[archivedID.uuidString] = restoredID.uuidString
    }
}

enum SessionRuntimeBridgeStorage {
    static func directory(
        for descriptor: SessionRuntimeDescriptor,
        pane: UUID,
        purpose: String,
        applicationSupportRoot: URL? = nil,
        homeDirectory: URL? = nil
    ) throws -> URL {
        guard descriptor.isLocal,
              !purpose.isEmpty,
              purpose.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let root = SessionRuntimeConnections.localStateDirectory(
            for: descriptor,
            applicationSupportRoot: applicationSupportRoot,
            homeDirectory: home
        )
        let directories = [
            home.appendingPathComponent(".omg", isDirectory: true),
            home.appendingPathComponent(".omg/run", isDirectory: true),
            root,
            root.appendingPathComponent("bridges", isDirectory: true),
            root.appendingPathComponent("bridges/\(pane.uuidString.lowercased())", isDirectory: true),
            root.appendingPathComponent("bridges/\(pane.uuidString.lowercased())/\(purpose)", isDirectory: true),
        ]
        for directory in directories { try ensurePrivateDirectory(directory) }
        return directories[directories.count - 1]
    }

    static func capabilityToken(in directory: URL) throws -> String {
        let tokenURL = directory.appendingPathComponent("capability")
        let path = tokenURL.path
        let existing = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        if existing >= 0 {
            defer { Darwin.close(existing) }
            return try readToken(existing)
        }
        guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { return try capabilityToken(in: directory) }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let bytes = Array(token.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            offset += written
        }
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return token
    }

    static func readPrivateFile(at url: URL, maximumSize: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumSize else {
            throw CocoaError(.fileReadNoPermission)
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0, data.count + count <= maximumSize else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func writePrivateFile(at url: URL, data: Data, permissions: mode_t) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, permissions)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fchmod(fd, permissions) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    fileprivate static func ensurePrivateDirectory(_ url: URL) throws {
        let path = url.path
        if mkdir(path, 0o700) != 0 {
            guard errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } else if chmod(path, 0o700) != 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              hasPrivateDirectoryMetadata(owner: info.st_uid, mode: info.st_mode, expectedOwner: getuid()) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    static func hasPrivateDirectoryMetadata(
        owner: uid_t,
        mode: mode_t,
        expectedOwner: uid_t = getuid()
    ) -> Bool {
        owner == expectedOwner && mode & S_IFMT == S_IFDIR && mode & 0o077 == 0
    }

    private static func readToken(_ fd: Int32) throws -> String {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_size == 64 else {
            throw CocoaError(.fileReadNoPermission)
        }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count,
              let token = String(bytes: bytes, encoding: .utf8),
              token.allSatisfy(\.isHexDigit) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return token
    }
}

@MainActor
protocol SessionRuntimeRetrying {
    func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws
}

/// Owns one relay process per exact host/revision. Each surface gets a descriptor,
/// never a process-global SSH target. Remote PTYs outlive this coordinator.
@MainActor
final class SessionRuntimeConnections: SessionRuntimeRetrying {
    static let shared = SessionRuntimeConnections()
    private struct Relay {
        let process: Process
        let socket: URL
        let allowsInteractiveFirstAttempt: Bool
    }
    private var relays: [String: Relay] = [:]

    static var resources: URL {
        Bundle.main.resourceURL!.appendingPathComponent("session-runtime", isDirectory: true)
    }

    static func cachedHelperURL(
        forRevision revision: String,
        applicationSupportRoot: URL? = nil
    ) throws -> URL {
        guard !revision.isEmpty, revision.count <= 128,
              revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = (applicationSupportRoot ?? OMGApplicationEnvironment.applicationSupportURL())
            .appendingPathComponent("session-runtime/versions", isDirectory: true)
        let version = root.appendingPathComponent(revision, isDirectory: true)
        guard FileManager.default.fileExists(atPath: version.appendingPathComponent("revision").path),
              FileManager.default.fileExists(atPath: version.appendingPathComponent("snapshot-revision").path) else {
            throw NSError(domain: "OMGSessionRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The helper for this session runtime version is unavailable."])
        }
        let helper = version.appendingPathComponent("omgd")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NSError(domain: "OMGSessionRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The helper for this session runtime version is unavailable."])
        }
        return helper
    }

    static func descriptor(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws -> SessionRuntimeDescriptor {
        let revision = try String(contentsOf: resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(connection: connection, revision: revision, policy: policy)
    }

    static func localDescriptor(workingDirectory: String? = nil, policy: SessionRuntimePolicy) throws -> SessionRuntimeDescriptor {
        let directory = SessionRuntimeDescriptor.validWorkingDirectory(workingDirectory)
        guard workingDirectory == nil || directory != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        let revision = try String(contentsOf: resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(
            connection: nil,
            revision: revision,
            policy: policy,
            localWorkingDirectory: directory,
            initialWorkingDirectory: directory
        )
    }

    static func hasAutomaticLocalRuntimeResources(
        at resources: URL?,
        isRunningTests: Bool
    ) -> Bool {
        guard !isRunningTests, let resources else { return false }
        let runtime = resources.appendingPathComponent("session-runtime", isDirectory: true)
        let helper = runtime.appendingPathComponent("omgd")
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let revision = try? String(contentsOf: runtime.appendingPathComponent("revision"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty,
              let snapshot = try? String(contentsOf: runtime.appendingPathComponent("snapshot-revision"), encoding: .utf8),
              !snapshot.isEmpty else { return false }
        return true
    }

    static var supportsAutomaticLocalRuntime: Bool {
        hasAutomaticLocalRuntimeResources(
            at: Bundle.main.resourceURL,
            isRunningTests: OMGApplicationEnvironment.isRunningTests
        )
    }

    @discardableResult
    static func automaticallyConfigureLocalRuntime(
        _ config: inout Ghostty.SurfaceConfiguration,
        policy: SessionRuntimePolicy,
        enabled: Bool,
        resources: URL? = Bundle.main.resourceURL,
        isRunningTests: Bool = OMGApplicationEnvironment.isRunningTests
    ) -> Bool {
        guard enabled,
              hasAutomaticLocalRuntimeResources(at: resources, isRunningTests: isRunningTests),
              config.environmentVariables[SessionRuntimeDescriptor.environmentKey] == nil,
              config.environmentVariables["OMG_RUNTIME_SOCKET"] == nil else { return false }
        guard let resources,
              let revision = try? String(
                contentsOf: resources.appendingPathComponent("session-runtime/revision"),
                encoding: .utf8
              ).trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty else { return false }
        return (try? configureLocalRuntime(&config, policy: policy, revision: revision)) != nil
    }

    static func configureAutomaticLocalRuntime(
        _ config: inout Ghostty.SurfaceConfiguration,
        policy: SessionRuntimePolicy
    ) throws -> SessionRuntimeDescriptor {
        let runtimeResources = resources
        let revision = try String(
            contentsOf: runtimeResources.appendingPathComponent("revision"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return try configureLocalRuntime(&config, policy: policy, revision: revision)
    }

    static func configureLocalRuntime(
        _ config: inout Ghostty.SurfaceConfiguration,
        policy: SessionRuntimePolicy,
        revision: String
    ) throws -> SessionRuntimeDescriptor {
        guard !revision.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let workingDirectory = SessionRuntimeDescriptor.validWorkingDirectory(config.workingDirectory)
        let descriptor = SessionRuntimeDescriptor(
            connection: nil,
            revision: revision,
            policy: policy,
            localWorkingDirectory: workingDirectory,
            initialWorkingDirectory: workingDirectory
        )
        try descriptor.configure(&config)
        return descriptor
    }

    nonisolated static func localStateDirectory(
        for descriptor: SessionRuntimeDescriptor,
        applicationSupportRoot: URL? = nil,
        homeDirectory: URL? = nil
    ) -> URL {
        let support = applicationSupportRoot ?? OMGApplicationEnvironment.applicationSupportURL()
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let input = support.path + "\0" + descriptor.revision
        let hash = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        return home.appendingPathComponent(".omg/run/\(hash)")
    }

    private func artifactDirectory(revision: String, applicationSupportRoot: URL? = nil) throws -> URL {
        guard !revision.isEmpty, revision.count <= 128,
              revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let current = try String(contentsOf: Self.resources.appendingPathComponent("revision"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (applicationSupportRoot ?? OMGApplicationEnvironment.applicationSupportURL())
            .appendingPathComponent("session-runtime/versions")
        let cached = root.appendingPathComponent(revision)
        if revision == current && !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = root.appendingPathComponent(".copy-" + UUID().uuidString)
            try FileManager.default.copyItem(at: Self.resources, to: staging)
            do { try FileManager.default.moveItem(at: staging, to: cached) } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        guard FileManager.default.fileExists(atPath: cached.appendingPathComponent("revision").path) else {
            throw NSError(domain: "OMGSessionRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The runtime version for this session is unavailable. Its remote process has not been restarted."])
        }
        let currentSnapshot = try String(contentsOf: Self.resources.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        let cachedSnapshot = try String(contentsOf: cached.appendingPathComponent("snapshot-revision"), encoding: .utf8)
        guard currentSnapshot == cachedSnapshot else {
            throw NSError(domain: "OMGSessionRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This session uses an incompatible terminal snapshot version. Its remote process is preserved; reopen it with the matching app version."])
        }
        return cached
    }

    func cachedHelper(
        for descriptor: SessionRuntimeDescriptor,
        applicationSupportRoot: URL? = nil
    ) throws -> URL {
        _ = try artifactDirectory(revision: descriptor.revision, applicationSupportRoot: applicationSupportRoot)
        return try Self.cachedHelperURL(
            forRevision: descriptor.revision,
            applicationSupportRoot: applicationSupportRoot
        )
    }

    func prepare(
        _ descriptor: SessionRuntimeDescriptor,
        interactive: Bool = true,
        runtimeRoot: URL? = nil
    ) throws -> URL {
        if let relay = relays[descriptor.identity], relay.process.isRunning { return relay.socket }
        // Darwin sockaddr_un paths are capped near 104 bytes; the user's
        // /var/folders temporary path plus a host identity can exceed that.
        let root = runtimeRoot ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("omg-runtime-\(getuid())-\(ProcessInfo.processInfo.processIdentifier)")
        try SessionRuntimeBridgeStorage.ensurePrivateDirectory(root)
        let artifacts = try artifactDirectory(revision: descriptor.revision)
        let key = String(descriptor.identity.prefix(16))
        let socket = root.appendingPathComponent(key + ".sock")
        let configURL = root.appendingPathComponent(key + ".json")
        struct Configuration: Encodable {
            let transport: String
            let executable: String
            let arguments: [String]
            let cwd: String
            let localShell: String
            let bundle: String
            let policy: SessionRuntimePolicy
            let revision: String
            let hooks: String?
            let localStateDirectory: String?

            enum CodingKeys: String, CodingKey {
                case transport, executable, arguments, cwd, bundle, policy, revision, hooks
                case localShell = "local_shell"
                case localStateDirectory = "local_state_directory"
            }
        }
        let connection = descriptor.connection
        let localStateDirectory = Self.localStateDirectory(for: descriptor).path
        let config = Configuration(transport: descriptor.isLocal ? "local" : "ssh",
            executable: connection?.executablePath ?? "/usr/bin/ssh",
            arguments: connection?.arguments.map {
                $0 == "BatchMode=yes" || $0 == "BatchMode=no" ? "BatchMode=\(interactive ? "no" : "yes")" : $0
            } ?? [],
            cwd: descriptor.launchWorkingDirectory,
            localShell: Self.localLoginShell,
            bundle: artifacts.path, policy: descriptor.policy, revision: descriptor.revision,
            hooks: connection == nil ? nil : try AgentHookInstaller.remoteInstallerScript(agents: [.codex, .claude, .pi]),
            localStateDirectory: connection == nil ? localStateDirectory : nil)
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        try? FileManager.default.removeItem(at: socket)
        let process = Process()
        // Use the current transport optimizations for compatible cached runtimes;
        // the connection JSON still pins deployment to the original revision.
        process.executableURL = Self.resources.appendingPathComponent("omgd")
        process.arguments = ["connect", socket.path, configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Finder launches have no reliable inherited stderr. Keep helper
        // diagnostics in this connection's private directory instead.
        let logURL = root.appendingPathComponent(key + ".log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let diagnostics = try FileHandle(forWritingTo: logURL)
        try diagnostics.seekToEnd()
        defer { try? diagnostics.close() }
        process.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = artifacts.appendingPathComponent("askpass").path
        environment["SSH_ASKPASS_REQUIRE"] = interactive ? "force" : "never"
        environment["DISPLAY"] = environment["DISPLAY"] ?? "omg:0"
        process.environment = environment
        try process.run()
        relays[descriptor.identity] = .init(
            process: process,
            socket: socket,
            allowsInteractiveFirstAttempt: interactive
        )
        SessionRuntimeCatalog.shared.remember(descriptor)
        return socket
    }

    func prepareBatch(_ descriptor: SessionRuntimeDescriptor) throws -> URL {
        try prepare(descriptor, interactive: false)
    }

    func prepareInteractiveSession(_ descriptor: SessionRuntimeDescriptor) throws -> URL {
        guard let relay = relays[descriptor.identity], relay.process.isRunning else {
            return try prepare(descriptor, interactive: true)
        }
        if !relay.allowsInteractiveFirstAttempt, descriptor.connection != nil {
            try launchRetryRequest(socket: relay.socket, interactive: true)
        }
        return relay.socket
    }

    func retry(_ descriptor: SessionRuntimeDescriptor, onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        let socket = try prepare(descriptor, interactive: false)
        try launchRetryRequest(socket: socket, interactive: true, onFailure: onFailure)
    }

    private func launchRetryRequest(
        socket: URL,
        interactive: Bool,
        onFailure: (@MainActor @Sendable (String) -> Void)? = nil
    ) throws {
        let process = Process()
        process.executableURL = Self.resources.appendingPathComponent("omgd")
        process.arguments = SessionRuntimeRetryCommand.arguments(socket: socket, interactive: interactive)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0, let onFailure else { return }
            Task { @MainActor in onFailure("The runtime relay did not accept the retry request.") }
        }
        try process.run()
    }

    func shutdown() {
        SessionRuntimeCloseQueue.shared.stop()
        for relay in relays.values where relay.process.isRunning { relay.process.terminate() }
        relays.removeAll()
    }

    private static var localLoginShell: String {
        if let environmentShell = ProcessInfo.processInfo.environment["SHELL"],
           environmentShell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: environmentShell) {
            return environmentShell
        }
        if let account = getpwuid(getuid()), let shell = account.pointee.pw_shell,
           let path = String(validatingUTF8: shell),
           path.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/sh"
    }

    func open(connection: GitSSHConnection, policy: SessionRuntimePolicy) throws {
        let descriptor = try Self.descriptor(connection: connection, policy: policy)
        try open(descriptor)
    }

    func openLocal(workingDirectory: String, policy: SessionRuntimePolicy) throws {
        try open(Self.localDescriptor(workingDirectory: workingDirectory, policy: policy))
    }

    private func open(_ descriptor: SessionRuntimeDescriptor) throws {
        var config = Ghostty.SurfaceConfiguration()
        try descriptor.configure(&config)
        config.workingDirectory = descriptor.launchWorkingDirectory
        guard let delegate = NSApp.delegate as? AppDelegate else { throw CocoaError(.featureUnsupported) }
        if let parent = TerminalController.preferredParent?.window {
            guard TerminalController.newTab(delegate.ghostty, from: parent, withBaseConfig: config) != nil else {
                throw CocoaError(.featureUnsupported)
            }
        } else {
            _ = TerminalController.newWindow(delegate.ghostty, withBaseConfig: config)
        }
    }
}
