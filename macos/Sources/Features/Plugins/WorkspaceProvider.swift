import Darwin
import Foundation

private let editorMaximumFileSize = 10 * 1_024 * 1_024

struct RemoteTabBreadcrumb: Equatable, Sendable {
    let host: String
    let directory: String

    var title: String { "\(host) › \(directory)" }
}

struct PaneSessionContext: Equatable, Sendable {
    struct Local: Equatable, Sendable {
        var workingDirectory: String?
        var terminalTitle: String
    }

    struct SSH: Equatable, Sendable {
        let connectionID: String
        let alias: String
        let serverID: String?
        let replay: SSHReplayDescriptor?
        /// Exact OpenSSH destination used for host-owned auxiliary transfers.
        /// This preserves `user@host` for foreground-inferred sessions while
        /// keeping the shorter alias for presentation.
        let transferTarget: String
        /// Non-nil only when the host inferred a plain interactive `ssh`
        /// process from the Surface foreground process group. Typed `omg +ssh`
        /// lifecycles keep this nil and remain authoritative.
        let localProcessGroupID: Int?
    }

    enum State: Equatable, Sendable {
        case local
        case sshConnecting(SSH)
        case sshReady(SSH, workingDirectory: String)
    }

    private(set) var revision: UInt64 = 0
    private(set) var local: Local
    private(set) var state: State = .local
    private(set) var disconnectedSSH: SSH?
    private(set) var disconnectedRemoteWorkingDirectory: String?
    private var staleRemoteTerminalTitle: String?

    init(workingDirectory: String?, terminalTitle: String) {
        self.local = .init(
            workingDirectory: workingDirectory,
            terminalTitle: terminalTitle
        )
        self.staleRemoteTerminalTitle = nil
    }

    var workingDirectory: String? {
        switch state {
        case .local, .sshConnecting:
            local.workingDirectory
        case .sshReady(_, let workingDirectory):
            workingDirectory
        }
    }

    /// Title revisions do not change the pane's directory or connection.
    /// Keep these updates local to title consumers instead of invalidating
    /// every view and connection observer attached to the controller.
    func hasSameLocation(as other: Self) -> Bool {
        var comparable = other
        comparable.local.terminalTitle = local.terminalTitle
        comparable.revision = revision
        return self == comparable
    }

    var workspace: WorkspaceDescriptor? {
        guard case .sshReady(let ssh, let workingDirectory) = state else {
            return nil
        }
        return SSHPlugin.workspace(
            alias: ssh.alias,
            workingDirectory: workingDirectory
        )
    }

    var remoteTabBreadcrumb: RemoteTabBreadcrumb? {
        guard case .sshReady(let ssh, let workingDirectory) = state else {
            return nil
        }
        return .init(
            host: ssh.alias,
            directory: WorkspacePathPresentation.folderName(workingDirectory)
        )
    }

    var presentationTitle: String {
        presentationTitle(pathDisplay: .fullPath)
    }

    func presentationTitle(
        pathDisplay: OhMyGhosttyTabPathDisplay
    ) -> String {
        switch state {
        case .local, .sshConnecting:
            if pathDisplay == .folderName, let workingDirectory = local.workingDirectory {
                return WorkspacePathPresentation.folderName(workingDirectory)
            }
            if !local.terminalTitle.isEmpty { return local.terminalTitle }
            return local.workingDirectory.map(WorkspacePathPresentation.folderName) ?? "Terminal"
        case .sshReady(let ssh, _):
            return remoteTabBreadcrumb?.title ?? ssh.alias
        }
    }

    func agentPathTitle(
        pathDisplay: OhMyGhosttyTabPathDisplay
    ) -> String {
        let path: String? = workingDirectory.map {
            pathDisplay == .folderName
                ? WorkspacePathPresentation.folderName($0)
                : $0
        }
        switch state {
        case .local:
            return path ?? "Terminal"
        case .sshConnecting(let ssh):
            return path.map { "\(ssh.alias) \($0)" } ?? ssh.alias
        case .sshReady(let ssh, _):
            return remoteTabBreadcrumb?.title ?? ssh.alias
        }
    }

    var tabIconSystemName: String {
        switch state {
        case .local: "terminal"
        case .sshConnecting, .sshReady: "cloud"
        }
    }

    var inferredSSHProcessGroupID: Int? {
        switch state {
        case .local:
            nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            ssh.localProcessGroupID
        }
    }

    var isSSHSession: Bool {
        if case .local = state { return false }
        return true
    }

    mutating func updateLocalMetadata(
        workingDirectory: String?,
        terminalTitle: String
    ) {
        guard case .local = state else { return }
        let acceptsTitle = staleRemoteTerminalTitle == nil ||
            staleRemoteTerminalTitle != terminalTitle
        if acceptsTitle { staleRemoteTerminalTitle = nil }
        let next = Local(
            workingDirectory: workingDirectory ?? local.workingDirectory,
            terminalTitle: acceptsTitle && !terminalTitle.isEmpty
                ? terminalTitle
                : local.terminalTitle
        )
        guard next != local else { return }
        local = next
        revision &+= 1
    }

    /// Marks a simple interactive OpenSSH process observed directly in the
    /// Surface foreground process group. This makes ordinary `ssh host`
    /// sessions participate in remote presentation without rewriting the
    /// user's command or requiring a shell alias.
    mutating func observeForegroundSSH(
        alias: String,
        transferTarget: String,
        processGroupID: Int,
        currentWorkingDirectory: String?,
        currentTerminalTitle: String,
        remoteWorkingDirectory: String? = nil,
        replay: SSHReplayDescriptor? = nil
    ) {
        guard processGroupID > 0, SSHPlugin.validAlias(alias) else { return }
        let activeSSH: SSH? = switch state {
        case .local:
            nil
        case .sshConnecting(let ssh), .sshReady(let ssh, _):
            ssh
        }
        // Never replace an authenticated `omg +ssh` lifecycle with heuristic
        // foreground data.
        guard activeSSH?.localProcessGroupID != nil || activeSSH == nil else {
            return
        }
        let isCurrentConnection = activeSSH?.localProcessGroupID == processGroupID
        if !isCurrentConnection, case .local = state {
            local = .init(
                workingDirectory: currentWorkingDirectory ?? local.workingDirectory,
                terminalTitle: currentTerminalTitle.isEmpty
                    ? local.terminalTitle
                    : currentTerminalTitle
            )
        }
        let ssh = SSH(
            connectionID: "omg-ssh-foreground-\(processGroupID)",
            alias: alias,
            serverID: nil,
            replay: replay ?? activeSSH?.replay,
            transferTarget: transferTarget,
            localProcessGroupID: processGroupID
        )
        let next: State = if let remoteWorkingDirectory,
                             !remoteWorkingDirectory.isEmpty,
                             !remoteWorkingDirectory.contains("\0") {
            .sshReady(ssh, workingDirectory: remoteWorkingDirectory)
        } else {
            .sshConnecting(ssh)
        }
        guard state != next else { return }
        state = next
        revision &+= 1
    }

    /// Uses a validated remote Agent cwd to complete a foreground-inferred SSH
    /// session when ordinary SSH has no typed remote prompt lifecycle.
    mutating func applyInferredRemoteWorkingDirectory(_ workingDirectory: String) {
        guard !workingDirectory.isEmpty,
              !workingDirectory.contains("\0") else { return }
        switch state {
        case .sshConnecting(let ssh) where ssh.localProcessGroupID != nil:
            state = .sshReady(ssh, workingDirectory: workingDirectory)
            revision &+= 1
        case .sshReady(let ssh, let current) where ssh.localProcessGroupID != nil:
            guard current != workingDirectory else { return }
            state = .sshReady(ssh, workingDirectory: workingDirectory)
            revision &+= 1
        case .local, .sshConnecting, .sshReady:
            return
        }
    }

    /// Ends only the foreground-inferred SSH connection for this process
    /// group. A stale observation can therefore never clear a newer SSH
    /// connection on the same Surface.
    @discardableResult
    mutating func finishForegroundSSH(
        processGroupID: Int,
        currentWorkingDirectory: String?,
        currentTerminalTitle: String
    ) -> Bool {
        guard inferredSSHProcessGroupID == processGroupID else { return false }
        if let currentWorkingDirectory, !currentWorkingDirectory.isEmpty {
            local.workingDirectory = currentWorkingDirectory
        }
        staleRemoteTerminalTitle = currentTerminalTitle
        state = .local
        revision &+= 1
        return true
    }

    mutating func apply(
        _ signal: Ghostty.ContextSignal,
        currentWorkingDirectory: String?,
        currentTerminalTitle: String,
        sshReplay: SSHReplayDescriptor? = nil
    ) {
        guard signal.id.hasPrefix("omg-ssh-") else { return }
        let metadata = Self.metadata(signal.metadata)

        switch signal.action {
        case .start:
            guard metadata["type"] == "remote",
                  let alias = metadata["targethost"],
                  SSHPlugin.validAlias(alias) else { return }
            let activeSSH: SSH? = switch state {
            case .sshConnecting(let active), .sshReady(let active, _):
                active.connectionID == signal.id ? active : nil
            case .local:
                nil
            }
            let ssh = SSH(
                connectionID: signal.id,
                alias: alias,
                serverID: metadata["serverid"].flatMap(Self.validServerID)
                    ?? activeSSH?.serverID,
                replay: sshReplay ?? activeSSH?.replay,
                transferTarget: sshReplay?.transferTarget
                    ?? activeSSH?.transferTarget
                    ?? alias,
                localProcessGroupID: nil
            )
            let isCurrentConnection = activeSSH != nil
            if !isCurrentConnection, case .local = state {
                let localWorkingDirectory = metadata["localcwd"]?.removingPercentEncoding
                local = .init(
                    workingDirectory: localWorkingDirectory.flatMap { $0.isEmpty ? nil : $0 }
                        ?? currentWorkingDirectory
                        ?? local.workingDirectory,
                    terminalTitle: currentTerminalTitle.isEmpty
                        ? local.terminalTitle
                        : currentTerminalTitle
                )
            }
            if let workingDirectory = Self.remoteWorkingDirectory(metadata) {
                state = .sshReady(ssh, workingDirectory: workingDirectory)
            } else {
                state = .sshConnecting(ssh)
            }
            disconnectedSSH = nil
            disconnectedRemoteWorkingDirectory = nil
            revision &+= 1

        case .end:
            let activeID: String? = switch state {
            case .local:
                nil
            case .sshConnecting(let ssh), .sshReady(let ssh, _):
                ssh.connectionID
            }
            guard activeID == signal.id else { return }
            switch state {
            case .local:
                break
            case .sshConnecting(let ssh):
                disconnectedSSH = ssh
            case .sshReady(let ssh, let workingDirectory):
                disconnectedSSH = ssh
                disconnectedRemoteWorkingDirectory = workingDirectory
            }
            if let workingDirectory = metadata["cwd"]?.removingPercentEncoding,
               !workingDirectory.isEmpty {
                local.workingDirectory = workingDirectory
            }
            staleRemoteTerminalTitle = currentTerminalTitle
            state = .local
            revision &+= 1
        }
    }

    mutating func applyDetectedSSHReconnect(processGroupID: Int) {
        guard case .local = state,
              let previous = disconnectedSSH,
              let workingDirectory = disconnectedRemoteWorkingDirectory else { return }
        state = .sshReady(.init(
            connectionID: "omg-ssh-detected-\(processGroupID)",
            alias: previous.alias,
            serverID: previous.serverID,
            replay: previous.replay,
            transferTarget: previous.transferTarget,
            localProcessGroupID: processGroupID
        ), workingDirectory: workingDirectory)
        revision &+= 1
    }

    mutating func endDetectedSSHReconnect(processGroupID: Int) {
        guard case .sshReady(let ssh, _) = state,
              ssh.connectionID == "omg-ssh-detected-\(processGroupID)" else { return }
        state = .local
        revision &+= 1
    }

    static func isSSHReconnectCommand(_ commandLines: String, alias: String) -> Bool {
        let tokens = commandLines.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.contains(where: {
            let executable = ($0 as NSString).lastPathComponent
            return executable == "ssh" || executable == "omg"
        }) else { return false }
        return tokens.contains(alias) || tokens.contains { token in
            token.hasSuffix("@\(alias)")
        }
    }

    private static func validServerID(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 256 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".:_+-/=")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    private static func remoteWorkingDirectory(
        _ metadata: [String: String]
    ) -> String? {
        if let cwd = metadata["cwd"]?.removingPercentEncoding,
           !cwd.isEmpty {
            return cwd
        }
        guard let raw = metadata["cwdhex"] else { return nil }
        let hex = Array(raw.utf8)
        guard !hex.isEmpty,
              hex.count <= 8_192,
              hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let high = hexNibble(hex[index]),
                  let low = hexNibble(hex[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        guard let value = String(bytes: bytes, encoding: .utf8),
              !value.isEmpty,
              !value.contains("\0") else { return nil }
        return value
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func metadata(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, field in
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }
}

enum ForegroundSSHProcessObservation: Equatable, Sendable {
    case interactive(alias: String, transferTarget: String)
    case ambiguous
    case none
}

/// Conservative host-side recognition for a foreground OpenSSH client. This
/// intentionally mirrors `+ssh`'s interactive-destination policy: forwarding,
/// control, no-command, and explicit remote-command invocations are not
/// classified as interactive panes.
enum ForegroundSSHProcessDetector {
    static func observe(in commandLines: String) -> ForegroundSSHProcessObservation {
        var sawSSHProcess = false
        for rawLine in commandLines.split(whereSeparator: \.isNewline) {
            let argv = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let executable = argv.first,
                  executable.split(separator: "/").last == "ssh" else { continue }
            sawSSHProcess = true
            guard let destination = interactiveDestination(Array(argv.dropFirst())),
                  let alias = destinationLabel(destination) else { continue }
            return .interactive(alias: alias, transferTarget: destination)
        }
        return sawSSHProcess ? .ambiguous : .none
    }

    static func interactiveDestination(_ args: [String]) -> String? {
        OpenSSHArguments(args)?.interactiveDestination
    }

    private static func destinationLabel(_ destination: String) -> String? {
        let label = destination.lastIndex(of: "@").map {
            String(destination[destination.index(after: $0)...])
        } ?? destination
        guard SSHPlugin.validAlias(label) else { return nil }
        return label
    }
}

enum WorkspacePathPresentation {
    /// Returns the final POSIX path component without touching the filesystem.
    /// URL(fileURLWithPath:) performs lstat work even for presentation-only
    /// remote paths, and VerticalTabRow may be recomputed every display frame.
    static func folderName(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var end = path.endIndex
        while end > path.startIndex,
              path[path.index(before: end)] == "/" {
            end = path.index(before: end)
        }
        let trimmed = path[..<end]
        guard !trimmed.isEmpty else { return "/" }
        guard let separator = trimmed.lastIndex(of: "/") else {
            return String(trimmed)
        }
        let component = trimmed[trimmed.index(after: separator)...]
        return component.isEmpty ? "/" : String(component)
    }
}

struct SSHReplayDescriptor: Codable, Equatable, Sendable {
    let version: Int
    let ssh: String
    let forwardEnv: Bool
    let terminfo: Bool
    let cache: Bool
    let args: [String]
    /// Captured from the foreground process when available. Older +ssh
    /// descriptors use the pane's saved local working directory instead.
    var localWorkingDirectory: String?

    enum CodingKeys: String, CodingKey {
        case version
        case ssh
        case forwardEnv = "forward_env"
        case terminfo
        case cache
        case args
        case localWorkingDirectory = "local_working_directory"
    }

    var transferTarget: String? {
        guard version == 1 else { return nil }
        return ForegroundSSHProcessDetector.interactiveDestination(args)
    }

    func command(
        executablePath: String,
        remoteWorkingDirectory: String? = nil,
        remoteAgent: SupportedAgent? = nil,
        conversationID: AgentConversationID? = nil
    ) -> String? {
        guard version == 1,
              !ssh.isEmpty,
              ssh.utf8.count <= 4_096,
              !ssh.contains("\0"),
              !args.isEmpty,
              args.count <= 128,
              args.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }) else {
            return nil
        }
        if let remoteWorkingDirectory {
            guard remoteWorkingDirectory.utf8.count <= 4_096,
                  !remoteWorkingDirectory.contains("\0") else { return nil }
        }
        var argv = [
            executablePath,
            "+ssh",
            "--forward-env=\(forwardEnv)",
            "--terminfo=\(terminfo)",
            "--cache=\(cache)",
            "--ssh=\(ssh)",
        ]
        if let remoteWorkingDirectory {
            argv.append("--remote-working-directory=\(remoteWorkingDirectory)")
        }
        if let remoteAgent {
            argv.append("--remote-agent=\(remoteAgent.rawValue)")
            if let conversationID {
                argv.append("--remote-agent-session=\(conversationID.rawValue)")
            }
        } else if conversationID != nil {
            return nil
        }
        argv.append("--")
        argv.append(contentsOf: args)
        let command = argv.map(Self.shellQuote).joined(separator: " ")
        guard let localWorkingDirectory else { return command }
        guard localWorkingDirectory.hasPrefix("/"), localWorkingDirectory.utf8.count <= 4_096,
              !localWorkingDirectory.contains("\0") else { return nil }
        return "(cd " + Self.shellQuote(localWorkingDirectory) + " && " + command + ")"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Snapshot of an SSH pane session used to restore the connection after the
/// app relaunches, even when no agent resume descriptor is present.
struct SSHResumeDescriptor: Codable, Equatable, Sendable {
    let sshReplay: SSHReplayDescriptor
    let remoteWorkingDirectory: String?
    let localWorkingDirectory: String?

    func command(executablePath: String) -> String? {
        sshReplay.command(
            executablePath: executablePath,
            remoteWorkingDirectory: remoteWorkingDirectory
        )
    }
}

enum SSHReplayStore {
    static func url(
        for connectionID: String,
        applicationSupportURL: URL? = nil
    ) -> URL? {
        guard connectionID.hasPrefix("omg-ssh-"),
              connectionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        let support = applicationSupportURL ??
            OMGApplicationEnvironment.applicationSupportURL()
        return support
            .appendingPathComponent("SSHReplay", isDirectory: true)
            .appendingPathComponent("\(connectionID).json")
    }

    static func load(
        connectionID: String,
        applicationSupportURL: URL? = nil,
        now: Date = Date()
    ) -> SSHReplayDescriptor? {
        guard let url = url(
            for: connectionID,
            applicationSupportURL: applicationSupportURL
        ),
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let modified = attributes[.modificationDate] as? Date,
        now.timeIntervalSince(modified) >= -5 * 60,
        now.timeIntervalSince(modified) <= 24 * 60 * 60,
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
        permissions & 0o077 == 0,
        let size = (attributes[.size] as? NSNumber)?.intValue,
        size <= 64 * 1_024,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? JSONDecoder().decode(SSHReplayDescriptor.self, from: data)
    }
}

/// Generic workspace identity shared by Local, SSH, and future remote providers.
struct WorkspaceDescriptor: Equatable, Sendable {
    enum Kind: String, Sendable {
        case local
        case ssh
    }

    let kind: Kind
    let id: String
    let displayName: String
    let workingDirectory: String

    var icon: GhosttyTabIcon {
        switch kind {
        case .local: .systemSymbol("terminal")
        case .ssh: .systemSymbol("cloud")
        }
    }

    var presentationTitle: String {
        switch kind {
        case .local: workingDirectory
        case .ssh: "\(displayName) \(workingDirectory)"
        }
    }
}

struct WorkspaceFileEntry: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
}

enum WorkspaceFilesystemError: Error, Equatable, Sendable {
    case unavailable
    case commandFailed(Int32, String)
    case invalidResponse
    case invalidPath
    case fileChanged(String)
    case operationFailed(String)
    case fileTooLarge(String, Int)
}

extension WorkspaceFilesystemError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable: "The workspace filesystem is unavailable."
        case .commandFailed(let status, let message):
            message.isEmpty ? "The filesystem command failed with status \(status)." : message
        case .invalidResponse: "The workspace returned an invalid response."
        case .invalidPath: "The file path is invalid."
        case .fileChanged(let path): "The file changed outside the editor: \(path)"
        case .operationFailed(let reason): reason
        case .fileTooLarge(let path, let maximumBytes):
            "The file is too large to edit: \(path) (maximum \(maximumBytes) bytes)."
        }
    }
}

enum WorkspaceItemType: Equatable, Sendable {
    case file
    case directory
}

/// Data-only filesystem boundary consumed by Files UI/providers.
/// Implementations perform their own bounded asynchronous IO.
protocol WorkspaceFilesystem: Sendable {
    var descriptor: WorkspaceDescriptor { get }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry]
    func listTreeDirectory(at path: String) async throws -> [WorkspaceFileEntry]
    func createFile(named name: String, in directory: String) async throws
    func createDirectory(named name: String, in directory: String) async throws
    func renameItem(at path: String, to name: String) async throws
    func readFile(at path: String) async throws -> Data
    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws
    func itemType(at path: String) async throws -> WorkspaceItemType?
}

enum WorkspaceFileActions {
    static func renamedPath(_ path: String, name: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"),
              !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw WorkspaceFilesystemError.invalidPath
        }
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
    }

    static func relativePath(_ path: String, root: String) -> String {
        let prefix = root == "/" ? "/" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolutePrefix = prefix.hasPrefix("/") ? prefix : "/" + prefix
        let boundary = absolutePrefix == "/" ? "/" : absolutePrefix + "/"
        return path.hasPrefix(boundary) ? String(path.dropFirst(boundary.count)) : path
    }
}

extension WorkspaceFilesystem {
    func listTreeDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        try await listDirectory(at: path)
    }
    func renameItem(at path: String, to name: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func readFile(at path: String) async throws -> Data {
        throw WorkspaceFilesystemError.unavailable
    }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func itemType(at path: String) async throws -> WorkspaceItemType? {
        nil
    }
}

struct LocalWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor

    init(workingDirectory: String) {
        let url = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        self.descriptor = .init(
            kind: .local,
            id: "local",
            displayName: WorkspacePathPresentation.folderName(url.path),
            workingDirectory: url.path
        )
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        try await Task.detached(priority: .utility) {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                throw WorkspaceFilesystemError.unavailable
            }
            return urls.compactMap { url -> WorkspaceFileEntry? in
                guard url.lastPathComponent != ".DS_Store" else { return nil }
                let values = try? url.resourceValues(forKeys: keys)
                return .init(
                    path: url.path,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(500)
            .map { $0 }
        }.value
    }

    func createFile(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw WorkspaceFilesystemError.unavailable
            }
        }.value
    }

    func createDirectory(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        try await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: directory).appendingPathComponent(name),
                    withIntermediateDirectories: false
                )
            } catch {
                throw WorkspaceFilesystemError.unavailable
            }
        }.value
    }

    func renameItem(at path: String, to name: String) async throws {
        let destination = try WorkspaceFileActions.renamedPath(path, name: name)
        guard destination != path else { return }
        try await Task.detached(priority: .utility) {
            // FileManager refuses to replace an existing destination, including symlinks.
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        }.value
    }

    func itemType(at path: String) async throws -> WorkspaceItemType? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return isDir.boolValue ? .directory : .file
    }

    func readFile(at path: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                guard size <= UInt64(editorMaximumFileSize) else {
                    throw WorkspaceFilesystemError.fileTooLarge(path, editorMaximumFileSize)
                }
                return try Data(contentsOf: url)
            } catch let error as WorkspaceFilesystemError {
                throw error
            } catch {
                throw WorkspaceFilesystemError.operationFailed(
                    "Could not read \(path): \(error.localizedDescription)"
                )
            }
        }.value
    }

    private static let pathLocksLock = NSLock()
    private static var pathLocks: [String: NSLock] = [:]

    private static func pathLock(for path: String) -> NSLock {
        pathLocksLock.lock()
        defer { pathLocksLock.unlock() }
        if let lock = pathLocks[path] {
            return lock
        }
        let lock = NSLock()
        pathLocks[path] = lock
        return lock
    }

    private static func withPathLock<T>(for path: String, _ body: () throws -> T) throws -> T {
        let lock = pathLock(for: path)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        try await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            try Self.withPathLock(for: url.path) {
                var fd: Int32 = -1
                var attempts = 0
                while attempts < 10 {
                    attempts += 1
                    let candidate = open(url.path, O_RDWR)
                    if candidate < 0 { break }
                    flock(candidate, LOCK_EX)
                    var stFd = stat()
                    var stPath = stat()
                    if fstat(candidate, &stFd) == 0 && stat(url.path, &stPath) == 0 {
                        if stFd.st_ino == stPath.st_ino && stFd.st_dev == stPath.st_dev {
                            fd = candidate
                            break
                        }
                    }
                    flock(candidate, LOCK_UN)
                    close(candidate)
                }
                defer {
                    if fd >= 0 {
                        flock(fd, LOCK_UN)
                        close(fd)
                    }
                }
                let current = try Data(contentsOf: url)
                guard current == expectedData else {
                    throw WorkspaceFilesystemError.fileChanged(path)
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let permissions = attributes[.posixPermissions]
                try data.write(to: url, options: [.atomic])
                if let permissions {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: url.path
                    )
                }
            }
        }.value
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }
}

struct UnavailableWorkspaceFilesystem: WorkspaceFilesystem {
    let descriptor: WorkspaceDescriptor

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        throw WorkspaceFilesystemError.unavailable
    }

    func createFile(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }

    func createDirectory(named name: String, in directory: String) async throws {
        throw WorkspaceFilesystemError.unavailable
    }
}

struct SSHHostConfiguration: Equatable, Sendable {
    let alias: String
    let hostname: String
    let user: String?
    let port: Int?
    let proxyJump: String?

    var workspaceID: String { "ssh:\(alias)" }

    var icon: GhosttyTabIcon { .systemSymbol("cloud") }
}

/// Reads aliases through the user's OpenSSH configuration without owning keys,
/// passwords, known_hosts, ProxyJump, or an SSH agent.
struct SSHPlugin: Sendable {
    static let pluginID = "builtin.ssh"
    static let manifest = PluginManifest(
        id: pluginID,
        version: "0.5.0",
        executable: "builtin",
        capabilities: [.terminalEvents, .tabMetadata, .tabIcon, .inspectorPane],
        minimumHostVersion: "0.1.0"
    )

    static var isEnabled: Bool {
        let defaultsKey = "OMG.Plugin.Enabled.\(pluginID)"
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        let supportURL = OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("Plugins", isDirectory: true)
        return FileManager.default.fileExists(
            atPath: supportURL
                .appendingPathComponent(pluginID, isDirectory: true)
                .appendingPathComponent("manifest.json")
                .path
        )
    }

    static func validAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.allSatisfy { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
        }
    }

    static func configurations(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> [SSHHostConfiguration] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [SSHHostConfiguration] = []
        var aliases: [String] = []
        var values: [String: String] = [:]

        func flush() {
            for alias in aliases where validAlias(alias) {
                guard let hostname = values["hostname"] else { continue }
                result.append(.init(
                    alias: alias,
                    hostname: hostname,
                    user: values["user"],
                    port: values["port"].flatMap(Int.init),
                    proxyJump: values["proxyjump"]
                ))
            }
            aliases.removeAll()
            values.removeAll()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            if key == "host" {
                flush()
                let aliasParts = value.split(whereSeparator: { character in
                    character == " " || character == "\t"
                })
                aliases = aliasParts.map(String.init)
            } else if !aliases.isEmpty {
                values[key] = value
            }
        }
        flush()
        return result
    }

    static func configuration(
        alias: String,
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    ) -> SSHHostConfiguration? {
        configurations(at: url).first { $0.alias == alias }
    }

    static func workspace(
        alias: String,
        workingDirectory: String
    ) -> WorkspaceDescriptor? {
        guard isEnabled, validAlias(alias) else { return nil }
        // Workspace identity comes from the typed SSH lifecycle. Resolving the
        // OpenSSH host belongs to WorkspaceFilesystemFactory when Files is
        // actually requested, not to every VerticalTabRow body evaluation.
        return .init(
            kind: .ssh,
            id: "ssh:\(alias)",
            displayName: alias,
            workingDirectory: workingDirectory
        )
    }
}

enum WorkspaceFilesystemFactory {
    static func make(for context: InspectorPaneContext) -> any WorkspaceFilesystem {
        if let workspace = context.workspace, workspace.kind == .ssh {
            guard let host = SSHPlugin.configuration(alias: workspace.displayName) else {
                return UnavailableWorkspaceFilesystem(descriptor: workspace)
            }
            return SSHWorkspaceFilesystem(
                host: host,
                workingDirectory: workspace.workingDirectory,
                connection: try? GitSSHConnection(session: context.session)
            )
        }
        if case .sshReady(let ssh, let workingDirectory) = context.session.state {
            return UnavailableWorkspaceFilesystem(descriptor: .init(
                kind: .ssh,
                id: "ssh:\(ssh.alias)",
                displayName: ssh.alias,
                workingDirectory: workingDirectory
            ))
        }
        return LocalWorkspaceFilesystem(
            workingDirectory: context.workingDirectory ?? "/"
        )
    }
}

struct SSHImagePasteTransfer {
    static func upload(localFile: URL, to ssh: PaneSessionContext.SSH) async throws -> String {
        guard localFile.isFileURL,
              !ssh.transferTarget.isEmpty,
              ssh.transferTarget.utf8.count <= 4_096,
              !ssh.transferTarget.contains("\0"),
              !ssh.transferTarget.contains("\n"),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: localFile.path
              ),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw WorkspaceFilesystemError.invalidPath
        }
        let remotePath = remotePath(for: localFile)
        let batch = batch(localPath: localFile.path, remotePath: remotePath)
        _ = try await SSHSFTPClient.run(batch: batch, host: ssh.transferTarget,
                                       connection: try? GitSSHConnection(session: ssh))
        return Ghostty.Shell.escape(remotePath)
    }

    static func remotePath(for localFile: URL) -> String {
        let rawExt = localFile.pathExtension.lowercased()
        let ext = (rawExt.count <= 8 && rawExt.allSatisfy({ $0.isLetter || $0.isNumber }) && !rawExt.isEmpty)
            ? rawExt
            : "png"
        return "/tmp/omg-paste-\(UUID().uuidString).\(ext)"
    }

    static func batch(localPath: String, remotePath: String) -> String {
        [
            "put \(quote(localPath)) \(quote(remotePath))",
            "chmod 600 \(quote(remotePath))",
        ].joined(separator: "\n")
    }

    private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SSHSFTPClient {
    static func run(batch: String, host: String, connection: GitSSHConnection? = nil) async throws -> String {
        let connection = try connection ?? GitSSHConnection(destination: host,
            localWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        return try await SSHSessionTransport.sftp(batch: batch, connection: connection)
    }

    static func runCommand(_ command: String, host: String, connection: GitSSHConnection? = nil) async throws -> String {
        let connection = try connection ?? GitSSHConnection(destination: host,
            localWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let result = try await SSHSessionTransport.run(connection: connection,
            command: SSHSessionTransport.shellCommand(command))
        guard result.isSuccess else { throw WorkspaceFilesystemError.commandFailed(result.exitCode, result.stderrString) }
        return result.stdoutString
    }
}

struct SSHWorkspaceFilesystem: WorkspaceFilesystem {
    let host: SSHHostConfiguration
    let connection: GitSSHConnection?
    let descriptor: WorkspaceDescriptor

    init(host: SSHHostConfiguration, workingDirectory: String, connection: GitSSHConnection? = nil) {
        self.connection = connection
        self.host = host
        self.descriptor = .init(
            kind: .ssh,
            id: host.workspaceID,
            displayName: host.alias,
            workingDirectory: workingDirectory
        )
    }

    func listDirectory(at path: String) async throws -> [WorkspaceFileEntry] {
        let output = try await runSFTP(batch: "ls -la \(Self.quote(path))")
        return try Self.parseLongListing(output, directory: path)
    }

    func createFile(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        _ = try await runSFTP(batch: "put /dev/null \(Self.quote(Self.join(directory, name)))")
    }

    func createDirectory(named name: String, in directory: String) async throws {
        guard Self.validChildName(name) else { throw WorkspaceFilesystemError.invalidPath }
        _ = try await runSFTP(batch: "mkdir \(Self.quote(Self.join(directory, name)))")
    }

    func renameItem(at path: String, to name: String) async throws {
        let destination = try WorkspaceFileActions.renamedPath(path, name: name)
        guard destination != path else { return }
        let command = "python3 -c " + Self.shellQuote(Self.exclusiveRenameScript) + " " +
            Self.shellQuote(path) + " " + Self.shellQuote(destination)
        _ = try await SSHSFTPClient.runCommand(command, host: host.alias, connection: connection)
    }

    // No check-then-rename fallback: it could overwrite a concurrently created target.
    static let exclusiveRenameScript = """
    import ctypes, os, sys
    libc = ctypes.CDLL(None, use_errno=True)
    source, target = map(os.fsencode, sys.argv[1:3])
    if sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(-100, source, -100, target, 1)
    elif sys.platform == 'darwin' and hasattr(libc, 'renamex_np'):
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = rename(source, target, 4)
    else:
        sys.exit('Safe rename requires Linux renameat2 or macOS renamex_np and Python 3.')
    if result != 0:
        sys.exit(os.strerror(ctypes.get_errno()))
    """

    func statFile(at path: String) async throws -> (size: UInt64, permissions: Int?, isDirectory: Bool)? {
        let output = try await runSFTP(batch: "ls -la \(Self.quote(path))")
        return Self.parseFileAttributes(from: output)
    }

    func itemType(at path: String) async throws -> WorkspaceItemType? {
        guard let output = try? await runSFTP(batch: "ls -la \(Self.quote(path))"),
              let attrs = Self.parseFileAttributes(from: output) else {
            return nil
        }
        return attrs.isDirectory ? .directory : .file
    }

    func readFile(at path: String) async throws -> Data {
        // Pre-check remote attributes before downloading (E11)
        if let output = try? await runSFTP(batch: "ls -la \(Self.quote(path))"),
           let attrs = Self.parseFileAttributes(from: output) {
            guard !attrs.isDirectory else {
                throw WorkspaceFilesystemError.invalidPath
            }
            guard attrs.size <= UInt64(editorMaximumFileSize) else {
                throw WorkspaceFilesystemError.fileTooLarge(path, editorMaximumFileSize)
            }
        }

        let localURL = Self.temporaryTransferURL()
        defer { try? FileManager.default.removeItem(at: localURL) }
        _ = try await runSFTP(batch: "get \(Self.quote(path)) \(Self.quote(localURL.path))")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size <= UInt64(editorMaximumFileSize) else {
                throw WorkspaceFilesystemError.fileTooLarge(path, editorMaximumFileSize)
            }
            return try Data(contentsOf: localURL)
        } catch let error as WorkspaceFilesystemError {
            throw error
        } catch {
            throw WorkspaceFilesystemError.invalidResponse
        }
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func resolveSymlinkViaSSH(at path: String) async -> String? {
        let command = "readlink -f \(Self.shellQuote(path)) 2>/dev/null || realpath \(Self.shellQuote(path)) 2>/dev/null"
        guard let output = try? await SSHSFTPClient.runCommand(command, host: host.alias, connection: connection) else { return nil }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.hasPrefix("/") && result != path ? result : nil
    }

    enum RemoteSymlinkCheckResult: Equatable {
        case symlink
        case regularFile
        case indeterminate
    }

    static func parseSymlinkStatus(name: String, fromDirectoryListing output: String) -> RemoteSymlinkCheckResult {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, !line.hasPrefix("sftp>") else { continue }
            let columns = line.split(maxSplits: 8, whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 9 else { continue }
            let entryPath = String(columns[8])
            let entryName = (entryPath.components(separatedBy: " -> ").first ?? entryPath)
            if (entryName as NSString).lastPathComponent == name {
                return line.first == "l" ? .symlink : .regularFile
            }
        }
        return .indeterminate
    }

    func checkRemoteSymlinkStatus(at path: String) async -> RemoteSymlinkCheckResult {
        let parentDir = (path as NSString).deletingLastPathComponent
        let targetName = (path as NSString).lastPathComponent
        guard let output = try? await runSFTP(batch: "ls -la \(Self.quote(parentDir))") else {
            return .indeterminate
        }
        return Self.parseSymlinkStatus(name: targetName, fromDirectoryListing: output)
    }

    func resolveSymlinkTarget(at path: String) async -> String {
        var currentPath = path
        var depth = 0
        while depth < 32 {
            guard let output = try? await runSFTP(batch: "ls -la \(Self.quote(currentPath))"),
                  let target = Self.parseSymlinkTarget(from: output) else {
                break
            }
            if target.hasPrefix("/") {
                currentPath = Self.standardized(target)
            } else {
                let parentDir = (currentPath as NSString).deletingLastPathComponent
                currentPath = Self.standardized(Self.join(parentDir, target))
            }
            depth += 1
        }
        return currentPath
    }

    func writeFile(_ data: Data, at path: String, replacing expectedData: Data) async throws {
        var targetPath = path
        if let resolved = await resolveSymlinkViaSSH(at: path) {
            targetPath = resolved
        } else {
            targetPath = await resolveSymlinkTarget(at: path)
        }

        if targetPath == path {
            let status = await checkRemoteSymlinkStatus(at: path)
            switch status {
            case .symlink:
                throw WorkspaceFilesystemError.operationFailed(
                    "Cannot safely save symbolic link without resolving its remote target: \(path)"
                )
            case .indeterminate:
                throw WorkspaceFilesystemError.operationFailed(
                    "Cannot verify whether \(path) is a symbolic link; saving aborted to prevent overwriting."
                )
            case .regularFile:
                break
            }
        }

        var remotePermissions: Int?
        if let attrs = try? await statFile(at: targetPath) {
            remotePermissions = attrs.permissions
        }

        let current = try await readFile(at: targetPath)
        guard current == expectedData else {
            throw WorkspaceFilesystemError.fileChanged(path)
        }
        let localURL = Self.temporaryTransferURL()
        defer { try? FileManager.default.removeItem(at: localURL) }
        do {
            try data.write(to: localURL, options: [.atomic])
        } catch {
            throw WorkspaceFilesystemError.unavailable
        }

        // Upload to a remote temporary file in the target's directory and atomically rename
        let directory = (targetPath as NSString).deletingLastPathComponent
        let tempFileName = ".omg-tmp-\(UUID().uuidString)"
        let remoteTempPath = Self.join(directory, tempFileName)

        var batchCommands = [
            "put \(Self.quote(localURL.path)) \(Self.quote(remoteTempPath))"
        ]
        if let permissions = remotePermissions {
            let octal = String(permissions, radix: 8)
            batchCommands.append("chmod \(octal) \(Self.quote(remoteTempPath))")
        }
        batchCommands.append("rename \(Self.quote(remoteTempPath)) \(Self.quote(targetPath))")
        let batch = batchCommands.joined(separator: "\n")

        do {
            _ = try await runSFTP(batch: batch)
        } catch {
            _ = try? await runSFTP(batch: "rm \(Self.quote(remoteTempPath))")
            throw error
        }
    }

    private func runSFTP(batch: String) async throws -> String {
        try await SSHSFTPClient.run(batch: batch, host: host.alias, connection: connection)
    }

    static func parseFileAttributes(
        from output: String
    ) -> (size: UInt64, permissions: Int?, isDirectory: Bool)? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, !line.hasPrefix("sftp>") else { continue }
            let isDirectory = line.first == "d"
            let columns = line.split(maxSplits: 8, whereSeparator: { character in
                character == " " || character == "\t"
            })
            guard columns.count >= 5 else { continue }
            guard let size = UInt64(columns[4]) else { continue }
            let permissions = parsePosixPermissions(String(columns[0]))
            return (size: size, permissions: permissions, isDirectory: isDirectory)
        }
        return nil
    }

    static func parseSymlinkTarget(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, !line.hasPrefix("sftp>") else { continue }
            guard line.first == "l" else { return nil }
            guard let arrowRange = line.range(of: " -> ") else { return nil }
            return String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func parsePosixPermissions(_ modeString: String) -> Int? {
        guard modeString.count >= 10 else { return nil }
        let chars = Array(modeString)
        var mode = 0
        if chars[1] == "r" { mode |= 0o400 }
        if chars[2] == "w" { mode |= 0o200 }
        if chars[3] == "x" {
            mode |= 0o100
        } else if chars[3] == "s" {
            mode |= 0o4000 | 0o100
        } else if chars[3] == "S" {
            mode |= 0o4000
        }

        if chars[4] == "r" { mode |= 0o040 }
        if chars[5] == "w" { mode |= 0o020 }
        if chars[6] == "x" {
            mode |= 0o010
        } else if chars[6] == "s" {
            mode |= 0o2000 | 0o010
        } else if chars[6] == "S" {
            mode |= 0o2000
        }

        if chars[7] == "r" { mode |= 0o004 }
        if chars[8] == "w" { mode |= 0o002 }
        if chars[9] == "x" {
            mode |= 0o001
        } else if chars[9] == "t" {
            mode |= 0o1000 | 0o001
        } else if chars[9] == "T" {
            mode |= 0o1000
        }
        return mode
    }

    static func parseLongListing(
        _ output: String,
        directory: String
    ) throws -> [WorkspaceFileEntry] {
        var result: [WorkspaceFileEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 10, !line.hasPrefix("sftp>") else { continue }
            let isDirectory = line.first == "d"
            let columns = line.split(maxSplits: 8, whereSeparator: { character in
                character == " " || character == "\t"
            })
            guard columns.count == 9 else { continue }
            let listedPath = listingPath(String(columns[8]), directory: directory)
            let name = (listedPath as NSString).lastPathComponent
            guard name != ".", name != "..", name != ".DS_Store" else { continue }
            result.append(.init(
                path: listedPath,
                name: name,
                isDirectory: isDirectory
            ))
        }
        guard result.count <= 500 else { return Array(result.prefix(500)) }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func listingPath(_ field: String, directory: String) -> String {
        // Long listings render symlinks as "name -> target". The entry path is
        // the link itself; resolving the target here would change navigation.
        let value = field.components(separatedBy: " -> ").first ?? field
        if value.hasPrefix("/") { return standardized(value) }

        let normalizedDirectory = standardized(directory)
        let directoryWithoutRoot = normalizedDirectory.drop(while: { $0 == "/" })
        if !directoryWithoutRoot.isEmpty,
           value == directoryWithoutRoot || value.hasPrefix(directoryWithoutRoot + "/") {
            return standardized("/" + value)
        }
        return standardized(join(normalizedDirectory, value))
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func join(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func validChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains(":")
    }

    private static func temporaryTransferURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-editor-\(UUID().uuidString)")
    }
}
