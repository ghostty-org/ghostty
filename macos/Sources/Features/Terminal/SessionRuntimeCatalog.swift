import AppKit
import Combine
import Foundation

struct SessionRuntimeCatalogEndpoint: Codable, Equatable, Identifiable, Sendable {
    var descriptor: SessionRuntimeDescriptor
    var lastUsedAt: Date

    var id: String { descriptor.identity }
}

/// A deliberately small projection of a host runtime record. The list helper
/// only returns these public fields; never decode or persist its full record.
struct SessionRuntimeCatalogSession: Decodable, Equatable, Identifiable, Sendable {
    struct Resume: Decodable, Equatable, Sendable {
        let agent: String
        let conversationID: String
        let cwd: String

        enum CodingKeys: String, CodingKey {
            case agent, cwd
            case conversationID = "conversation_id"
        }
    }

    let id: String
    let generation: String
    let createdAt: UInt64
    let updatedAt: UInt64
    let pid: Int?
    let ended: String?
    let resume: Resume?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case id, generation, pid, ended, resume, cwd
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var paneID: UUID? { UUID(uuidString: id) }
    var workingDirectory: String? {
        SessionRuntimeDescriptor.validWorkingDirectory(cwd) ??
            SessionRuntimeDescriptor.validWorkingDirectory(resume?.cwd)
    }
    var isAttachable: Bool { ended == nil && paneID != nil }
    func statusLabel(using strings: SessionRuntimeLibraryStrings) -> String {
        if let ended {
            let reason = strings.endReason(ended)
            return strings.t("Ended (\(reason))", "已结束（\(reason)）")
        }
        return pid.map { _ in strings.running } ?? strings.starting
    }
    var agentLabel: String? {
        guard let agent = resume?.agent, !agent.isEmpty else { return nil }
        return SupportedAgent(rawValue: agent)?.displayName ?? agent.capitalized
    }

    static func decodeList(_ data: Data) throws -> [Self] {
        let records = try JSONDecoder().decode([Self].self, from: data)
        guard records.count <= 2_048 else {
            throw NSError(
                domain: "OMGSessionRuntimeCatalog",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The endpoint returned too much session data."]
            )
        }
        return records.filter { record in
            record.paneID != nil &&
                record.id.utf8.count <= 64 &&
                record.generation.utf8.count <= 128 &&
                record.cwd.map { SessionRuntimeDescriptor.validWorkingDirectory($0) != nil } != false &&
                record.resume.map { SessionRuntimeDescriptor.validWorkingDirectory($0.cwd) != nil } != false
        }
    }
}

@MainActor
final class SessionRuntimeCatalog: ObservableObject {
    private struct Archive: Codable {
        let version: Int
        var endpoints: [SessionRuntimeCatalogEndpoint]
    }

    static let shared = SessionRuntimeCatalog(
        url: OMGApplicationEnvironment.isRunningTests ? nil :
            OMGApplicationEnvironment.applicationSupportURL()
                .appendingPathComponent("session-runtime/endpoints.json")
    )

    @Published private(set) var endpoints: [SessionRuntimeCatalogEndpoint] = []
    @Published private(set) var persistenceError: String?
    private let url: URL?
    private var loadError: String?

    init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let values = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(Archive.self, from: values)
            guard archive.version == 1, archive.endpoints.count <= 512 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            endpoints = Self.normalized(archive.endpoints)
        } catch {
            let message = "Could not read the saved session endpoints: \(error.localizedDescription)"
            loadError = message
            persistenceError = message
        }
    }

    /// Adds the runtime endpoint to the local catalog. The process can still
    /// start if persistence is unavailable; the error stays visible in Library.
    func remember(_ descriptor: SessionRuntimeDescriptor) {
        var durable = descriptor
        durable.initialWorkingDirectory = nil
        let endpoint = SessionRuntimeCatalogEndpoint(descriptor: durable, lastUsedAt: Date())
        var next = endpoints.filter { $0.id != endpoint.id }
        next.append(endpoint)
        next = Self.normalized(next)
        endpoints = next
        if let loadError {
            persistenceError = loadError
            return
        }
        do {
            try persist(next)
            persistenceError = nil
        } catch {
            persistenceError = "Could not save the session endpoint: \(error.localizedDescription)"
        }
    }

    private static func normalized(_ values: [SessionRuntimeCatalogEndpoint]) -> [SessionRuntimeCatalogEndpoint] {
        var byID: [String: SessionRuntimeCatalogEndpoint] = [:]
        for endpoint in values {
            guard endpoint.descriptor.revision.utf8.count <= 128,
                  endpoint.descriptor.revision.allSatisfy({
                      $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0))
                  }) else { continue }
            if byID[endpoint.id].map({ $0.lastUsedAt < endpoint.lastUsedAt }) ?? true {
                byID[endpoint.id] = endpoint
            }
        }
        return byID.values.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(512).map { $0 }
    }

    private func persist(_ values: [SessionRuntimeCatalogEndpoint]) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let archive = Archive(version: 1, endpoints: values)
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class SessionRuntimeLibraryModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    typealias Loader = @MainActor @Sendable
        (SessionRuntimeDescriptor) async throws -> [SessionRuntimeCatalogSession]

    @Published private(set) var endpoints: [SessionRuntimeCatalogEndpoint]
    @Published private(set) var sessions: [SessionRuntimeCatalogSession] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var persistenceError: String?
    @Published var selectedEndpointID: String? {
        didSet {
            guard selectedEndpointID != oldValue else { return }
            cancelRefresh()
            sessions = []
            selectedSessionID = nil
            if selectedEndpointID != nil { refresh() }
        }
    }

    private let catalog: SessionRuntimeCatalog
    private let closeQueue: SessionRuntimeCloseQueue
    private let loader: Loader
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var catalogObservers: Set<AnyCancellable> = []

    init(
        catalog: SessionRuntimeCatalog? = nil,
        closeQueue: SessionRuntimeCloseQueue? = nil,
        loader: Loader? = nil
    ) {
        let catalog = catalog ?? SessionRuntimeCatalog.shared
        self.catalog = catalog
        self.closeQueue = closeQueue ?? SessionRuntimeCloseQueue.shared
        self.loader = loader ?? { descriptor in
            try await Self.loadSessions(descriptor)
        }
        endpoints = catalog.endpoints
        persistenceError = catalog.persistenceError
        catalog.$endpoints.sink { [weak self] value in
            guard let self else { return }
            endpoints = value
            if let selectedEndpointID, !value.contains(where: { $0.id == selectedEndpointID }) {
                self.selectedEndpointID = nil
            }
        }.store(in: &catalogObservers)
        catalog.$persistenceError.sink { [weak self] value in
            self?.persistenceError = value
        }.store(in: &catalogObservers)
    }

    var selectedEndpoint: SessionRuntimeCatalogEndpoint? {
        endpoints.first { $0.id == selectedEndpointID }
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    func selectSession(_ session: SessionRuntimeCatalogSession?) {
        guard case .loaded = loadState, let session, sessions.contains(session) else {
            selectedSessionID = nil
            return
        }
        selectedSessionID = session.id
    }

    func refreshIfSelected() {
        guard selectedEndpointID != nil else { return }
        refresh()
    }

    func refresh() {
        guard let endpoint = selectedEndpoint else {
            cancelRefresh()
            sessions = []
            loadState = .idle
            return
        }
        refreshTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        sessions = []
        selectedSessionID = nil
        loadState = .loading
        let loader = self.loader
        refreshTask = Task { @MainActor [weak self] in
            do {
                let result = try await loader(endpoint.descriptor)
                guard let self, !Task.isCancelled, generation == requestGeneration,
                      selectedEndpointID == endpoint.id else { return }
                sessions = result.sorted { $0.updatedAt > $1.updatedAt }
                loadState = .loaded
                refreshTask = nil
            } catch {
                guard let self, generation == requestGeneration,
                      selectedEndpointID == endpoint.id else { return }
                if Task.isCancelled || error is CancellationError {
                    loadState = .idle
                } else if let processError = error as? GitExecutionError, processError == .cancelled {
                    loadState = .idle
                } else {
                    loadState = .failed(error.localizedDescription)
                }
                refreshTask = nil
            }
        }
    }

    func cancelRefresh() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if isLoading { loadState = .idle }
    }

    func end(_ session: SessionRuntimeCatalogSession) throws {
        guard let endpoint = selectedEndpoint,
              let pane = session.paneID,
              loadState == .loaded,
              selectedSessionID == session.id,
              sessions.contains(session),
              session.ended == nil else { return }
        try closeQueue.enqueue([SessionRuntimeCloseRequest(pane: pane, descriptor: endpoint.descriptor)])
        closeQueue.start()
        closeQueue.retry()
        refresh()
    }

    private static func loadSessions(
        _ descriptor: SessionRuntimeDescriptor
    ) async throws -> [SessionRuntimeCatalogSession] {
        let socket = try SessionRuntimeConnections.shared.prepareBatch(descriptor)
        let helper = SessionRuntimeConnections.resources.appendingPathComponent("omgd")
        let result: GitExecutionResult
        do {
            result = try await GitProcessRunner().run(
                executablePath: helper.path,
                arguments: ["list-local", socket.path],
                workingDirectory: FileManager.default.temporaryDirectory.path,
                maxOutputBytes: 8 * 1024 * 1024,
                timeout: 30
            )
        } catch let error as GitExecutionError {
            switch error {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw Self.queryError("Session query timed out.")
            case .outputLimitExceeded:
                throw Self.queryError("The endpoint returned too much session data.")
            case .processFailed(_, let message), .executionFailed(let message):
                throw Self.queryError(message)
            }
        }
        guard result.isSuccess else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.queryError(
                message.isEmpty ? "The session runtime helper exited with code \(result.exitCode)." : message
            )
        }
        do {
            return try SessionRuntimeCatalogSession.decodeList(result.stdout)
        } catch {
            throw Self.queryError("The endpoint returned invalid session data.")
        }
    }

    private static func queryError(_ message: String) -> NSError {
        NSError(domain: "OMGSessionRuntimeCatalog", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
