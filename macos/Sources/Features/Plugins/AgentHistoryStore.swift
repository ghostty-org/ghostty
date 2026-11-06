import Foundation
import SQLite3

struct AgentHistorySession: Identifiable, Equatable, Codable, Sendable {
    let agent: SupportedAgent
    let conversationID: AgentConversationID
    let title: String
    let workingDirectory: String?
    let updatedAt: Date
    let sourcePath: String
    /// Non-nil when the session lives on a remote host; the value is the SSH
    /// alias used to reach it.
    var remoteHost: String?
    var isActive: Bool
    var previewSnippet: String?

    var id: String { "\(agent.rawValue):\(conversationID.rawValue)" }

    /// Use the host's verified CLI syntax, without inventing launch flags that
    /// were not recorded with this session.
    var resumeCommand: String? {
        let arguments = agent == .pi ? ["--session", "{id}"] : agent.definition.resume.resumeArguments
        guard arguments.contains(where: { $0.contains("{id}") }) else { return nil }
        let argv = [agent.definition.command] + arguments.map {
            $0.replacingOccurrences(of: "{id}", with: conversationID.rawValue)
        }
        return argv.map { value in
            value.range(of: "^[A-Za-z0-9_./:@+-]+$", options: .regularExpression) != nil
                ? value : Ghostty.Shell.quote(value)
        }.joined(separator: " ")
    }
}

enum AgentHistoryMessageRole: String, Equatable, Sendable {
    case user
    case assistant
}

struct AgentHistoryMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: AgentHistoryMessageRole
    let text: String
    let timestamp: Date?
}

struct AgentHistoryTranscript: Equatable, Sendable {
    let sessionID: String
    let messages: [AgentHistoryMessage]
    let wasTruncated: Bool
}

enum AgentHistoryStore {
    static let maximumSessions = 10_000

    private static let maximumFiles = 200_000
    private static let maximumHeaderCandidates = 20_000
    private static let maximumHeaderBytes = 2 * 1_024 * 1_024
    private static let maximumTranscriptBytes = 8 * 1_024 * 1_024
    private static let maximumRecordBytes = 4 * 1_024 * 1_024
    private static let maximumTranscriptMessages = 500
    private static let maximumTranscriptCharacters = 500_000
    private static let maximumMessageCharacters = 16_000

    private enum Format {
        case jsonl
    }

    private struct Source {
        let agent: SupportedAgent
        let root: URL
        let format: Format
        let entryPattern: String?
        let idKeyPath: String?
        let cwdKeyPath: String?
    }

    private struct Candidate {
        let source: Source
        let url: URL
        let filenameID: AgentConversationID?
        let updatedAt: Date
    }

    private struct RemoteSource {
        let agent: SupportedAgent
        let rootPath: String
        let entryPattern: String?
        let idKeyPath: String?
        let cwdKeyPath: String?
    }

    private struct RemoteCandidate {
        let source: RemoteSource
        let file: AgentHistoryRemoteFile
        let filenameID: AgentConversationID?
    }

    static func load(
        agents: [SupportedAgent] = SupportedAgent.allCases,
        rootURLs: [SupportedAgent: URL] = [:],
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        cacheURL: URL? = nil,
        updatedAfter: Date? = nil
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            scan(
                agents: agents,
                rootURLs: rootURLs,
                maximumSessions: maximumSessions,
                cacheURL: cacheURL,
                updatedAfter: updatedAfter
            )
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func loadCached(
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        cacheURL: URL? = nil
    ) async -> [AgentHistorySession] {
        let resolvedURL = cacheURL ?? defaultCacheURL()
        let diskTask = Task.detached(priority: .utility) { () -> [AgentHistorySession] in
            guard maximumSessions > 0,
                  let data = try? Data(contentsOf: resolvedURL),
                  let cache = try? JSONDecoder().decode(DiskCache.self, from: data),
                  cache.version == DiskCache.currentVersion else { return [] }
            var sessionsByID: [String: AgentHistorySession] = [:]
            for entry in cache.entries.values {
                guard !Task.isCancelled else { return [] }
                let session = entry.session
                guard FileManager.default.fileExists(atPath: session.sourcePath) else { continue }
                if let existing = sessionsByID[session.id],
                   existing.updatedAt >= session.updatedAt {
                    continue
                }
                sessionsByID[session.id] = session
            }
            return Array(sessionsByID.values.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }.prefix(maximumSessions))
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func loadRemote(
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent] = SupportedAgent.allCases,
        maximumSessions: Int = AgentHistoryStore.maximumSessions,
        updatedAfter: Date? = nil
    ) async -> [AgentHistorySession] {
        let diskTask = Task.detached(priority: .utility) {
            await scanRemote(
                access: access,
                agents: agents,
                maximumSessions: maximumSessions,
                updatedAfter: updatedAfter
            )
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    static func session(
        agent: SupportedAgent,
        conversationID: AgentConversationID,
        remoteHost: String? = nil,
        maximumSessions: Int = AgentHistoryStore.maximumSessions
    ) async -> AgentHistorySession? {
        if let remoteHost {
            let access = AgentHistoryRemoteAccess(alias: remoteHost)
            return await loadRemote(
                access: access,
                agents: [agent],
                maximumSessions: maximumSessions
            ).first(where: { $0.conversationID == conversationID })
        }
        return await load(
            agents: [agent],
            maximumSessions: maximumSessions
        ).first(where: { $0.conversationID == conversationID })
    }

    static func transcript(
        for session: AgentHistorySession,
        remoteAccess: AgentHistoryRemoteAccess? = nil
    ) async -> AgentHistoryTranscript {
        // Agy stores protobuf steps in SQLite; its summary is the supported preview.
        if session.agent == .antigravity {
            return .init(sessionID: session.id, messages: session.previewSnippet.map {
                [.init(id: session.id + ":preview", role: .user, text: $0, timestamp: nil)]
            } ?? [], wasTruncated: true)
        }
        if let alias = session.remoteHost {
            let access = remoteAccess ?? AgentHistoryRemoteAccess(alias: alias)
            guard let prefix = try? await access.readTranscript(
                path: session.sourcePath,
                maximumBytes: 8 * 1_024 * 1_024
            ) else {
                return .init(
                    sessionID: session.id,
                    messages: [],
                    wasTruncated: false
                )
            }
            return parseTranscript(
                data: prefix.data,
                session: session,
                sourceWasTruncated: prefix.wasTruncated
            )
        }
        let diskTask = Task.detached(priority: .utility) {
            parseTranscript(for: session)
        }
        return await withTaskCancellationHandler(
            operation: { await diskTask.value },
            onCancel: { diskTask.cancel() }
        )
    }

    /// Searches metadata and complete user/assistant transcript text off the
    /// main actor. Values are bounded snippets used for result highlighting.
    static func search(
        sessions: [AgentHistorySession],
        query: String
    ) async -> [String: String] {
        var latest: [String: String] = [:]
        for await matches in searchUpdates(sessions: sessions, query: query) {
            latest = matches
        }
        return latest
    }

    /// Emits cached metadata/preview matches immediately, then progressively
    /// adds complete transcript matches in recent-session order. A cold deep
    /// search can scan gigabytes, but useful results never wait for the tail.
    static func searchUpdates(
        sessions: [AgentHistorySession],
        query: String
    ) -> AsyncStream<[String: String]> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return AsyncStream { continuation in
                continuation.yield([:])
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var matches: [String: String] = [:]

                // Phase 1: title and small metadata only. This intentionally
                // avoids touching multi-kilobyte preview strings so the first
                // result batch can render immediately.
                for session in sessions {
                    guard !Task.isCancelled else { break }
                    let metadata = [
                        session.title,
                        session.agent.rawValue,
                        session.conversationID.rawValue,
                        session.workingDirectory ?? "",
                    ].joined(separator: "\n")
                    guard let range = metadata.range(
                        of: needle,
                        options: .caseInsensitive
                    ) else { continue }
                    matches[session.id] = searchSnippet(
                        metadata,
                        around: range
                    )
                }
                continuation.yield(matches)

                // Phase 2: cached bounded body previews. This still avoids
                // filesystem I/O and usually resolves recent-session queries.
                for session in sessions where matches[session.id] == nil {
                    guard !Task.isCancelled else { break }
                    guard let preview = session.previewSnippet,
                          let range = preview.range(
                              of: needle,
                              options: .caseInsensitive
                          ) else { continue }
                    matches[session.id] = searchSnippet(
                        preview,
                        around: range
                    )
                }
                continuation.yield(matches)

                // Phase 3: complete transcript scan, yielding each newly found
                // match instead of waiting for every historical file.
                for (index, session) in sessions.enumerated() {
                    guard !Task.isCancelled else { break }
                    // Remote full-body search would otherwise open one SSH
                    // process per session. Remote sessions use their bounded
                    // metadata/preview index; local sessions keep deep search.
                    guard session.remoteHost == nil,
                          matches[session.id] == nil else { continue }
                    if let snippet = firstTranscriptMatch(
                        at: URL(fileURLWithPath: session.sourcePath),
                        query: needle,
                        agent: session.agent
                    ) {
                        matches[session.id] = snippet
                        continuation.yield(matches)
                    } else if index.isMultiple(of: 100) {
                        continuation.yield(matches)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct DiskCache: Codable {
        static let currentVersion = 7
        var version: Int = currentVersion
        struct Entry: Codable {
            let session: AgentHistorySession
            let mtime: TimeInterval
        }
        var entries: [String: Entry] = [:]
    }

    nonisolated private static func defaultCacheURL() -> URL {
        OMGApplicationEnvironment.applicationSupportURL()
            .appendingPathComponent("AgentHistory", isDirectory: true)
            .appendingPathComponent("session-cache.json")
    }

    nonisolated private static func scan(
        agents: [SupportedAgent],
        rootURLs: [SupportedAgent: URL],
        maximumSessions: Int,
        cacheURL: URL? = nil,
        updatedAfter: Date? = nil
    ) -> [AgentHistorySession] {
        guard maximumSessions > 0 else { return [] }
        let resolvedCacheURL = cacheURL ?? defaultCacheURL()
        var diskCache: DiskCache = {
            if let data = try? Data(contentsOf: resolvedCacheURL),
               let decoded = try? JSONDecoder().decode(DiskCache.self, from: data),
               decoded.version == DiskCache.currentVersion {
                return decoded
            }
            return DiskCache()
        }()

        var candidates: [Candidate] = []
        var candidatePaths: Set<String> = []
        var inspectedFiles = 0

        for agent in agents where !Task.isCancelled {
            for source in sources(for: agent, rootURL: rootURLs[agent]) {
                guard !Task.isCancelled else { break }
                guard let enumerator = FileManager.default.enumerator(
                    at: source.root,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .creationDateKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard !Task.isCancelled else { break }
                    inspectedFiles += 1
                    guard inspectedFiles <= maximumFiles else { break }
                    guard isTranscript(url),
                          let values = try? url.resourceValues(forKeys: [
                              .contentModificationDateKey,
                              .creationDateKey,
                              .isRegularFileKey,
                              .isSymbolicLinkKey,
                          ]),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true else { continue }
                    candidatePaths.insert(url.path)
                    let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
                    if let updatedAfter, modified < updatedAfter { continue }

                    let filenameID: AgentConversationID?
                    if let pattern = source.entryPattern {
                        let relativePath = relativePath(of: url, under: source.root)
                        // Stores such as omp write each conversation into its own
                        // directory, so a file name alone may not carry the ID.
                        // Fall back to validated header metadata instead of
                        // discarding the transcript entirely.
                        filenameID = id(from: relativePath, pattern: pattern)
                            .flatMap(AgentConversationID.init)
                    } else {
                        filenameID = nil
                    }
                    candidates.append(.init(
                        source: source,
                        url: url,
                        filenameID: filenameID,
                        updatedAt: values.contentModificationDate ??
                            values.creationDate ?? .distantPast
                    ))
                }
                if inspectedFiles > maximumFiles { break }
            }
        }

        candidates.sort { $0.updatedAt > $1.updatedAt }
        var sessionsByID: [String: AgentHistorySession] = [:]
        let originalCacheCount = diskCache.entries.count
        diskCache.entries = diskCache.entries.filter { path, entry in
            !agents.contains(entry.session.agent) || candidatePaths.contains(path)
        }
        var cacheUpdated = diskCache.entries.count != originalCacheCount

        // Parsing a compressed rollout needs an external decompressor, which
        // costs several milliseconds each. Fold cache hits serially, then parse
        // the remainder concurrently so thousands of archives stay responsive.
        let candidateLimit = min(candidates.count, maximumHeaderCandidates)
        var cachedSessions = [AgentHistorySession?](repeating: nil, count: candidateLimit)
        var parsedSessions = [AgentHistorySession?](repeating: nil, count: candidateLimit)
        var needsParse: [Int] = []
        needsParse.reserveCapacity(candidateLimit)
        for index in 0..<candidateLimit {
            let candidate = candidates[index]
            if let cached = diskCache.entries[candidate.url.path],
               abs(cached.mtime - candidate.updatedAt.timeIntervalSince1970) < 0.001 {
                cachedSessions[index] = cached.session
            } else {
                needsParse.append(index)
            }
        }
        if !needsParse.isEmpty {
            let lock = NSLock()
            // Bound decompression/JSON workers, and check the parent task's
            // cancellation between batches (GCD workers have no Swift task).
            for start in stride(from: 0, to: needsParse.count, by: 2) {
                guard !Task.isCancelled else { break }
                DispatchQueue.concurrentPerform(iterations: min(2, needsParse.count - start)) { offset in
                    let index = needsParse[start + offset]
                    let session = session(from: candidates[index])
                    lock.lock()
                    parsedSessions[index] = session
                    lock.unlock()
                }
            }
        }

        for index in 0..<candidateLimit {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            let candidate = candidates[index]
            let session: AgentHistorySession?
            if let cached = cachedSessions[index] {
                session = cached
            } else {
                session = parsedSessions[index]
                if let session {
                    diskCache.entries[candidate.url.path] = .init(
                        session: session,
                        mtime: candidate.updatedAt.timeIntervalSince1970
                    )
                    cacheUpdated = true
                }
            }
            guard let session else { continue }
            if let existing = sessionsByID[session.id], existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
        }

        if cacheUpdated && !Task.isCancelled {
            try? FileManager.default.createDirectory(
                at: resolvedCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(diskCache) {
                try? data.write(to: resolvedCacheURL, options: .atomic)
            }
        }

        if agents.contains(.antigravity) {
            for session in antigravitySessions(rootURL: rootURLs[.antigravity]) {
                sessionsByID[session.id] = session
            }
        }
        return Array(sessionsByID.values.filter { session in updatedAfter.map { session.updatedAt >= $0 } ?? true }.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }.prefix(maximumSessions))
    }

    nonisolated private static func antigravitySessions(rootURL: URL?) -> [AgentHistorySession] {
        let root = rootURL ?? URL(fileURLWithPath:
            ("~/.gemini/antigravity-cli/conversations" as NSString).expandingTildeInPath)
        let index = root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db")
        // Antigravity keeps its index in WAL mode. A read-only handle cannot
        // prepare statements against it (SQLITE_CANTOPEN), so read a private
        // copy with a read-write handle and never touch the Agent's own files.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-agy-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("summary.db")
        guard (try? FileManager.default.copyItem(at: index, to: copy)) != nil else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT conversation_id, title, preview, workspace_uris, strftime('%s', last_modified_time) FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 10000"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func value(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var sessions: [AgentHistorySession] = []
        while !Task.isCancelled, sqlite3_step(statement) == SQLITE_ROW {
            guard let id = AgentConversationID(value(0)), let seconds = Double(value(4)) else { continue }
            let path = root.appendingPathComponent(id.rawValue + ".db").path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let uris = value(3).data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let cwd = uris.compactMap(URL.init(string:)).first(where: \.isFileURL)?.path
            let modified = seconds > 0 ? Date(timeIntervalSince1970: seconds) :
                ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date())
            let preview = value(2)
            let title = value(1).isEmpty ? preview : value(1)
            sessions.append(.init(agent: .antigravity, conversationID: id,
                title: normalizedTitle(title, workingDirectory: cwd, conversationID: id),
                workingDirectory: cwd, updatedAt: modified,
                sourcePath: path, isActive: false, previewSnippet: preview.isEmpty ? nil : preview))
        }
        return sessions
    }

    nonisolated private static func sources(
        for agent: SupportedAgent,
        rootURL: URL?
    ) -> [Source] {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return [] }

        if let discovery = resume.discover, discovery.format == .jsonl {
            let roots = rootURL.map { [$0] } ?? ([discovery.root] + (discovery.additionalRoots ?? []))
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            return roots.map { root in
                .init(
                    agent: agent,
                    root: root,
                    format: .jsonl,
                    entryPattern: nil,
                    idKeyPath: discovery.idKeyPath,
                    cwdKeyPath: discovery.cwdKeyPath
                )
            }
        }

        guard let store = resume.store,
              store.entryPattern.lowercased().contains(".jsonl") else {
            return []
        }
        let root = rootURL ?? URL(fileURLWithPath:
            (store.root as NSString).expandingTildeInPath
        )
        return [.init(
            agent: agent,
            root: root,
            format: .jsonl,
            entryPattern: store.entryPattern,
            idKeyPath: nil,
            cwdKeyPath: nil
        )]
    }

    nonisolated private static func session(
        from candidate: Candidate
    ) -> AgentHistorySession? {
        let header = headerSnapshot(at: candidate.url, maximumBytes: maximumHeaderBytes)
        let records = header.records
        guard !records.isEmpty else { return nil }

        let metadataID: AgentConversationID? = if let keyPath =
            candidate.source.idKeyPath {
            records.lazy.compactMap {
                stringValue(at: keyPath, in: $0).flatMap(AgentConversationID.init)
            }.first
        } else {
            records.lazy.compactMap { record in
                if let value = record["sessionId"] as? String {
                    return AgentConversationID(value)
                }
                guard record["type"] as? String == "session",
                      let value = record["id"] as? String else { return nil }
                return AgentConversationID(value)
            }.first
        }
        if let filenameID = candidate.filenameID,
           let metadataID,
           filenameID != metadataID {
            return nil
        }
        guard let conversationID = metadataID ?? candidate.filenameID else {
            return nil
        }

        let configuredCwd = candidate.source.cwdKeyPath.flatMap { keyPath in
            records.lazy.compactMap { stringValue(at: keyPath, in: $0) }.first
        }
        let workingDirectory = validWorkingDirectory(
            configuredCwd ?? records.lazy.compactMap { record in
                stringValue(at: "cwd", in: record) ??
                    stringValue(at: "payload.cwd", in: record)
            }.first
        )
        let explicitTitle = records.reduce(nil as String?) { current, record in
            guard let type = record["type"] as? String,
                  ["title", "title_change", "session", "session_info"].contains(type),
                  let title = record["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return current
            }
            return title
        }
        let userTitle = records.lazy.compactMap { record -> String? in
            guard role(of: record) == .user else { return nil }
            return text(of: record)
        }.compactMap { cleaned -> String? in
            guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
            return cleaned
        }.first
        let title = normalizedTitle(
            explicitTitle ?? userTitle,
            workingDirectory: workingDirectory,
            conversationID: conversationID
        )

        let previewSnippet = conversationRecords(records, agent: candidate.source.agent, isComplete: header.isComplete).lazy.compactMap { record -> String? in
            guard role(of: record) != nil, let cleaned = text(of: record) else { return nil }
            return cleaned.isEmpty || cleaned == "[Image/Attachment]" ? nil : String(cleaned.prefix(1_000))
        }.prefix(10).joined(separator: "\n")

        return .init(
            agent: candidate.source.agent,
            conversationID: conversationID,
            title: title,
            workingDirectory: workingDirectory,
            updatedAt: candidate.updatedAt,
            sourcePath: candidate.url.path,
            isActive: false,
            previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet
        )
    }

    nonisolated private static func parseTranscript(
        data: Data,
        session: AgentHistorySession,
        sourceWasTruncated: Bool = false
    ) -> AgentHistoryTranscript {
        var offset = 0
        return parseTranscript(session: session, sourceWasTruncated: sourceWasTruncated) {
            guard offset < data.count else { return nil }
            let end = min(offset + 64 * 1_024, data.count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    nonisolated private static func parseTranscript(for session: AgentHistorySession) -> AgentHistoryTranscript {
        let url = URL(fileURLWithPath: session.sourcePath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .init(sessionID: session.id, messages: [], wasTruncated: false)
        }
        defer { try? handle.close() }
        var bytesRead = 0
        return parseTranscript(session: session) {
            let count = min(64 * 1_024, max(1, maximumTranscriptBytes - bytesRead))
            let data = try? handle.read(upToCount: count)
            bytesRead += data?.count ?? 0
            return data
        }
    }

    nonisolated static func parseTranscript(
        session: AgentHistorySession,
        sourceWasTruncated: Bool = false,
        readChunk: () -> Data?
    ) -> AgentHistoryTranscript {
        var filter = ConversationRecordFilter(agent: session.agent)
        var builder = TranscriptBuilder(session: session)
        let scan = scanJSONLines(maximumBytes: maximumTranscriptBytes, readChunk: readChunk) { line in
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
            return filter.consume(record).allSatisfy { builder.append($0) }
        }
        if let pending = filter.finish(isComplete: scan.reachedEnd && !sourceWasTruncated) {
            _ = builder.append(pending)
        }
        return .init(sessionID: session.id, messages: builder.messages,
                     wasTruncated: scan.wasTruncated || sourceWasTruncated || builder.wasTruncated || filter.wasTruncated)
    }

    private struct TranscriptBuilder {
        let session: AgentHistorySession
        var messages: [AgentHistoryMessage] = []
        var characterCount = 0
        var lastTurnID: String?
        var wasTruncated = false

        mutating func append(_ record: [String: Any]) -> Bool {
            guard let role = AgentHistoryStore.role(of: record),
                  let cleaned = AgentHistoryStore.text(of: record, keepingUserPastes: true),
                  !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return true }
            let payload = record["payload"] as? [String: Any]
            let metadata = payload?["internal_chat_message_metadata_passthrough"] as? [String: Any]
            let turnID = metadata?["turn_id"] as? String
            let merge = session.agent == .codex && role == .assistant && messages.last?.role == .assistant &&
                turnID == lastTurnID
            let previous = merge ? messages.last : nil
            let separator = previous == nil ? "" : "\n\n"
            let existing = previous?.text ?? ""
            let remaining = min(AgentHistoryStore.maximumMessageCharacters - existing.count,
                                AgentHistoryStore.maximumTranscriptCharacters - characterCount)
            guard merge || messages.count < AgentHistoryStore.maximumTranscriptMessages,
                  remaining > separator.count else {
                wasTruncated = true
                return false
            }
            let value = String(cleaned.prefix(remaining - separator.count))
            if value.count < cleaned.count { wasTruncated = true }
            let message = AgentHistoryMessage(
                id: previous?.id ?? "\(session.id):\(messages.count)", role: role,
                text: existing + separator + value,
                timestamp: previous?.timestamp ?? AgentHistoryStore.timestamp(of: record)
            )
            if merge { messages[messages.count - 1] = message } else { messages.append(message) }
            characterCount += separator.count + value.count
            lastTurnID = turnID
            return !wasTruncated
        }
    }

    nonisolated private static func scanRemote(
        access: AgentHistoryRemoteAccess,
        agents: [SupportedAgent],
        maximumSessions: Int,
        updatedAfter: Date? = nil
    ) async -> [AgentHistorySession] {
        guard maximumSessions > 0, !Task.isCancelled else { return [] }

        var roots: [String] = []
        for agent in agents {
            for rel in relativeRoots(for: agent) where !roots.contains(rel) {
                roots.append(rel)
            }
        }
        guard !roots.isEmpty else { return [] }

        guard let chunks = try? await access.discoverSessions(
            relativeRoots: roots,
            maximumSessions: maximumSessions,
            updatedAfter: updatedAfter
        ) else { return [] }

        var sessionsByID: [String: AgentHistorySession] = [:]
        for chunk in chunks.sorted(by: { $0.file.modifiedAt > $1.file.modifiedAt }) {
            guard !Task.isCancelled, sessionsByID.count < maximumSessions else { break }
            if let updatedAfter, chunk.file.modifiedAt < updatedAfter { continue }
            let records = headerRecords(from: chunk.headerData)
            guard !records.isEmpty else { continue }

            guard let matchedAgent = agents.first(where: { agent in
                relativeRoots(for: agent).contains { rel in
                    chunk.file.path.contains("/" + rel + "/") || chunk.file.path.contains("/" + rel)
                }
            }) else { continue }

            let pattern = matchedAgent.definition.resume.store?.entryPattern
            let idKeyPath = matchedAgent.definition.resume.discover?.idKeyPath
            let cwdKeyPath = matchedAgent.definition.resume.discover?.cwdKeyPath

            let filenameID: AgentConversationID?
            if let pattern {
                let filename = URL(fileURLWithPath: chunk.file.path).lastPathComponent
                filenameID = id(from: filename, pattern: pattern).flatMap(AgentConversationID.init)
            } else {
                filenameID = conversationIDFromRemoteFilename(chunk.file.path)
            }

            let metadataID: AgentConversationID? = if let idKeyPath {
                records.lazy.compactMap {
                    stringValue(at: idKeyPath, in: $0).flatMap(AgentConversationID.init)
                }.first
            } else {
                records.lazy.compactMap { record in
                    if let value = record["sessionId"] as? String {
                        return AgentConversationID(value)
                    }
                    guard record["type"] as? String == "session",
                          let value = record["id"] as? String else { return nil }
                    return AgentConversationID(value)
                }.first
            }
            // Remote stores have legitimate variants such as `session.jsonl`
            // and `__advisor.jsonl` whose filename does not encode the real
            // conversation ID. Validated metadata is authoritative remotely;
            // filename parsing is only a fallback for truncated Codex headers.
            guard let conversationID = metadataID ?? filenameID else {
                continue
            }

            let configuredCwd = cwdKeyPath.flatMap { keyPath in
                records.lazy.compactMap { stringValue(at: keyPath, in: $0) }.first
            }
            let workingDirectory = validWorkingDirectory(
                configuredCwd ?? records.lazy.compactMap { record in
                    stringValue(at: "cwd", in: record) ??
                        stringValue(at: "payload.cwd", in: record)
                }.first
            )
            let explicitTitle = records.reduce(nil as String?) { current, record in
                guard let type = record["type"] as? String,
                      ["title", "title_change", "session", "session_info"].contains(type),
                      let title = record["title"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return current
                }
                return title
            }
            let userTitle = records.lazy.compactMap { record -> String? in
                guard role(of: record) == .user else { return nil }
                return text(of: record)
            }.compactMap { cleaned -> String? in
                guard !cleaned.isEmpty, cleaned != "[Image/Attachment]" else { return nil }
                return cleaned
            }.first
            let title = normalizedTitle(
                explicitTitle ?? userTitle,
                workingDirectory: workingDirectory,
                conversationID: conversationID
            )
            let previewSnippet = conversationRecords(records, agent: matchedAgent, isComplete: false).lazy.compactMap { record -> String? in
                guard role(of: record) != nil, let cleaned = text(of: record) else { return nil }
                return cleaned.isEmpty || cleaned == "[Image/Attachment]"
                    ? nil
                    : String(cleaned.prefix(1_000))
            }.prefix(10).joined(separator: "\n")

            let session = AgentHistorySession(
                agent: matchedAgent,
                conversationID: conversationID,
                title: title,
                workingDirectory: workingDirectory,
                updatedAt: chunk.file.modifiedAt,
                sourcePath: chunk.file.path,
                remoteHost: access.alias,
                isActive: false,
                previewSnippet: previewSnippet.isEmpty ? nil : previewSnippet
            )
            if let existing = sessionsByID[session.id],
               existing.updatedAt >= session.updatedAt {
                continue
            }
            sessionsByID[session.id] = session
        }

        return sessionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    nonisolated private static func conversationIDFromRemoteFilename(
        _ path: String
    ) -> AgentConversationID? {
        let name = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        guard name.count >= 36 else { return nil }
        return AgentConversationID(String(name.suffix(36)))
    }

    nonisolated private static func relativeRoots(for agent: SupportedAgent) -> [String] {
        let resume = agent.definition.resume
        guard !resume.resumeArguments.isEmpty else { return [] }
        var values: [String] = []
        for rawPath in [resume.discover?.root ?? resume.store?.root] + (resume.discover?.additionalRoots ?? []) {
            guard let rawPath, let relative = relativePath(rawPath), !values.contains(relative) else { continue }
            values.append(relative)
        }
        return values
    }

    nonisolated private static func relativePath(_ rawPath: String) -> String? {
        if rawPath.hasPrefix("~/") {
            return String(rawPath.dropFirst(2))
        } else if rawPath.hasPrefix("~") {
            return String(rawPath.dropFirst(1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }

    /// Streams a bounded prefix of a zstd-compressed transcript. The helper is
    /// external because compression libs ship zstd only with newer SDKs; when
    /// it is unavailable the archived session is skipped rather than listed
    /// without metadata.
    /// GUI processes inherit a minimal PATH, so Homebrew's zstd is invisible to
    /// `/usr/bin/env`. Resolve an absolute executable once.
    nonisolated private static let zstdExecutable: URL? = {
        let fixed = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        if let path = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/zstd"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }()

    nonisolated private static func decompressedHeader(
        at url: URL,
        maximumBytes: Int
    ) -> Data {
        guard maximumBytes > 0, let executable = zstdExecutable else { return Data() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--decompress", "--stdout", "--quiet", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        var data = Data()
        let handle = pipe.fileHandleForReading
        while data.count < maximumBytes {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk.prefix(maximumBytes - data.count))
        }
        try? handle.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return data
    }

    nonisolated private static func headerRecords(from data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
    }

    /// Codex archives older rollouts as `rollout-….jsonl.zst`. They hold the
    /// same JSONL records, so only the transport differs.
    nonisolated private static func isTranscript(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
    }

    nonisolated private static func headerSnapshot(
        at url: URL,
        maximumBytes: Int
    ) -> (records: [[String: Any]], isComplete: Bool) {
        guard maximumBytes > 0 else { return ([], false) }
        if url.lastPathComponent.lowercased().hasSuffix(".zst") {
            // Codex archives are single-session rollouts whose metadata sits in
            // the leading records; decompressing less keeps thousands of archive
            // headers affordable.
            let limit = min(maximumBytes, 64 * 1_024)
            let data = decompressedHeader(at: url, maximumBytes: limit)
            return (headerRecords(from: data), data.count < limit)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? handle.close() }
        var data = (try? handle.read(upToCount: maximumBytes)) ?? Data()
        let size = try? handle.seekToEnd()
        let isComplete = size.map { $0 <= UInt64(data.count) } ?? false
        if let size, !isComplete {
            if let newline = data.lastIndex(of: 0x0A) { data = Data(data[...newline]) }
            try? handle.seek(toOffset: size > 128 * 1_024 ? size - 128 * 1_024 : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            for line in tail.split(separator: 0x0A).dropFirst() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let kind = record["type"] as? String,
                      ["session_info", "title", "title_change"].contains(kind) else { continue }
                data.append(0x0A)
                data.append(contentsOf: line)
            }
        }
        return (data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }, isComplete)
    }

    nonisolated private static func firstTranscriptMatch(
        at url: URL,
        query: String,
        agent: SupportedAgent
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return firstTranscriptMatch(query: query, agent: agent) { try? handle.read(upToCount: 64 * 1_024) }
    }

    nonisolated static func firstTranscriptMatch(
        query: String, agent: SupportedAgent, readChunk: () -> Data?
    ) -> String? {
        var filter = ConversationRecordFilter(agent: agent)
        var match: String?
        func findMatch(_ record: [String: Any]) -> Bool {
            guard role(of: record) != nil, let cleaned = text(of: record),
                  let range = cleaned.range(of: query, options: .caseInsensitive) else { return true }
            match = searchSnippet(cleaned, around: range)
            return false
        }
        let scan = scanJSONLines(readChunk: readChunk, visit: { line in
            guard let raw = String(data: line, encoding: .utf8) else { return true }
            let isControl = agent == .codex && ["response_item", "token_usage_record", "compacted", "turn_context", "task_complete", "turn_aborted"]
                .contains { raw.contains("\"\($0)\"") }
            guard isControl || raw.range(of: query, options: .caseInsensitive) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
            return filter.consume(record).allSatisfy(findMatch)
        })
        if match == nil, let pending = filter.finish(isComplete: scan.reachedEnd) { _ = findMatch(pending) }
        return match
    }

    /// Returns whether input was cut short or an oversized record was skipped.
    /// Readers can stop on a match without scanning the rest of a session.
    nonisolated private static func scanJSONLines(
        maximumBytes: Int = Int.max,
        readChunk: () -> Data?,
        visit: (Data) -> Bool
    ) -> (wasTruncated: Bool, reachedEnd: Bool) {
        var leftover = Data()
        var discardingLine = false
        var truncated = false
        var count = 0
        while !Task.isCancelled, let chunk = readChunk(), !chunk.isEmpty {
            guard count < maximumBytes else { return (true, false) }
            let available = chunk.prefix(maximumBytes - count)
            count += available.count
            var buffer = leftover + available
            leftover = Data()
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if !discardingLine && line.count <= maximumRecordBytes {
                    if !visit(Data(line)) { return (true, false) }
                } else {
                    truncated = true
                }
                discardingLine = false
                buffer = buffer[buffer.index(after: newline)...]
            }
            if buffer.count > maximumRecordBytes {
                discardingLine = true
                truncated = true
            } else if !discardingLine {
                leftover = Data(buffer)
            }
            if available.count < chunk.count { return (true, false) }
        }
        guard !Task.isCancelled else { return (true, false) }
        if !discardingLine && !leftover.isEmpty && !visit(leftover) { return (true, false) }
        return (truncated, true)
    }

    nonisolated private static func searchSnippet(
        _ text: String,
        around range: Range<String.Index>
    ) -> String {
        let start = text.index(
            range.lowerBound,
            offsetBy: -80,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            range.upperBound,
            offsetBy: 120,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let value = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > text.startIndex ? "…" : "") + value +
            (end < text.endIndex ? "…" : "")
    }

    // Defer only Codex records that can be compaction summaries, until the next
    // response item or its compaction marker resolves them. No file pre-pass.
    private struct ConversationRecordFilter {
        let agent: SupportedAgent
        var pending: [String: Any]?
        var responseID: String?
        var wasTruncated = false

        mutating func consume(_ record: [String: Any]) -> [[String: Any]] {
            guard agent == .codex else { return [record] }
            let payload = record["payload"] as? [String: Any] ?? [:]
            let type = record["type"] as? String
            if type == "compacted", let responseID,
               payload["compaction_response_id"] as? String == responseID {
                pending = nil
                self.responseID = nil
                return []
            }
            if type == "token_usage_record", let pending,
               let metadata = (pending["payload"] as? [String: Any])?["internal_chat_message_metadata_passthrough"] as? [String: Any],
               let turnID = metadata["turn_id"] as? String, payload["turn_id"] as? String == turnID {
                responseID = payload["response_id"] as? String
            }
            var result: [[String: Any]] = []
            let completedTurn = type == "event_msg" &&
                ["task_complete", "turn_aborted"].contains(payload["type"] as? String ?? "")
            if type == "response_item" || type == "turn_context" || completedTurn || AgentHistoryStore.role(of: record) == .user {
                if let pending { result.append(pending) }
                pending = nil
                responseID = nil
            }
            if type == "response_item", payload["type"] as? String == "message",
               payload["role"] as? String == "assistant", payload["phase"] as? String != "commentary",
               payload["id"] is String,
               let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
               metadata["turn_id"] is String {
                pending = record
            } else {
                result.append(record)
            }
            return result
        }

        mutating func finish(isComplete: Bool) -> [String: Any]? {
            defer { pending = nil; responseID = nil }
            guard isComplete else {
                if pending != nil { wasTruncated = true }
                return nil
            }
            return pending
        }
    }

    nonisolated private static func conversationRecords(
        _ records: [[String: Any]], agent: SupportedAgent, isComplete: Bool
    ) -> [[String: Any]] {
        var filter = ConversationRecordFilter(agent: agent)
        var result = records.flatMap { filter.consume($0) }
        if let pending = filter.finish(isComplete: isComplete) { result.append(pending) }
        return result
    }

    nonisolated private static func role(
        of record: [String: Any]
    ) -> AgentHistoryMessageRole? {
        let rawRole = (record["message"] as? [String: Any])?["role"] as? String ??
            (record["payload"] as? [String: Any])?["role"] as? String ??
            record["role"] as? String ??
            record["type"] as? String
        switch rawRole?.lowercased() {
        case "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    nonisolated private static func text(of record: [String: Any]) -> String? {
        text(of: record, keepingUserPastes: false)
    }

    /// - Parameter keepingUserPastes: Keeps the body of a `<pasted_content>`
    ///   wrapper. Transcripts show what the user actually pasted, while titles
    ///   and previews drop the wrapper so the surrounding request surfaces.
    nonisolated private static func text(
        of record: [String: Any], keepingUserPastes: Bool
    ) -> String? {
        let filterInjected = role(of: record) == .user
        if let message = record["message"] as? [String: Any],
           let text = text(from: message["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let payload = record["payload"] as? [String: Any],
           let text = text(from: payload["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let text = text(from: record["content"], filterInjected: filterInjected,
                           keepingUserPastes: keepingUserPastes) {
            return text
        }
        if let humanInput = record["humanInput"] as? [String: Any],
           let text = humanInput["text"] as? String {
            return cleanMeaningfulText(text, keepingUserPastes: keepingUserPastes)
        }
        return nil
    }

    nonisolated private static func text(
        from value: Any?, filterInjected: Bool, keepingUserPastes: Bool
    ) -> String? {
        func cleaned(_ value: String) -> String {
            filterInjected
                ? cleanMeaningfulText(value, keepingUserPastes: keepingUserPastes)
                : value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? String { return cleaned(value) }
        guard let values = value as? [Any] else { return nil }
        let parts = values.compactMap { item -> String? in
            if let item = item as? String { return cleaned(item) }
            guard let item = item as? [String: Any], let text = item["text"] as? String else { return nil }
            return cleaned(text)
        }.filter { !$0.isEmpty && $0 != "[Image/Attachment]" }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated private static func timestamp(
        of record: [String: Any]
    ) -> Date? {
        if let raw = record["timestamp"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = fractional.date(from: raw) { return value }
            if let value = ISO8601DateFormatter().date(from: raw) { return value }
        }
        if let milliseconds = (record["message"] as? [String: Any])?["timestamp"] as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        return nil
    }

    nonisolated private static func stringValue(
        at keyPath: String,
        in object: [String: Any]
    ) -> String? {
        var current: Any = object
        for key in keyPath.split(separator: ".") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(key)] else { return nil }
            current = next
        }
        return current as? String
    }

    nonisolated private static func id(
        from relativePath: String,
        pattern: String
    ) -> String? {
        guard let range = pattern.range(of: "{id}") else { return nil }
        let usesPath = pattern.contains("/")
        var target = usesPath
            ? relativePath
            : URL(fileURLWithPath: relativePath).lastPathComponent
        let before = String(pattern[..<range.lowerBound])
            .split(separator: "*", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let after = String(pattern[range.upperBound...])
            .split(separator: "*", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard target.hasSuffix(after) else { return nil }
        if !after.isEmpty { target.removeLast(after.count) }
        if !before.isEmpty {
            guard let beforeRange = target.range(of: before, options: .backwards) else {
                return nil
            }
            target = String(target[beforeRange.upperBound...])
        }
        return target.isEmpty ? nil : target
    }

    nonisolated private static func relativePath(
        of url: URL,
        under root: URL
    ) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }

    nonisolated private static func validWorkingDirectory(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.isEmpty,
              !value.contains("\0"),
              value.utf8.count <= 4_096 else { return nil }
        return value
    }

    /// Wrapper names that agents inject into user content blocks.
    nonisolated private static let injectedWrapperNames: Set<String> = [
        "local-command-caveat", "command-name", "command-message", "command-args",
        "local-command-stdout", "system-reminder", "external_codex_apps_open_page",
        "recommended_plugins", "environment_context", "instructions", "pasted_content",
        "skills_instructions", "model_switch", "codex_apps_client_time_context",
        "task-notification",
    ]

    /// Wrapper families whose tag name carries a generated suffix.
    nonisolated private static let injectedWrapperPrefixes: [String] = [
        "external_codex_apps_selected_page_part",
    ]

    /// A leading injected wrapper and the tags that delimit it.
    nonisolated private struct InjectedWrapper {
        let name: String
        let opening: Range<String.Index>
        let closing: Range<String.Index>?

        var isUserPaste: Bool { name == "pasted_content" }
    }

    /// Finds the injected wrapper that starts a user content block, if any.
    nonisolated private static func leadingInjectedWrapper(
        in text: String
    ) -> InjectedWrapper? {
        guard text.hasPrefix("<"), let openEnd = text.range(of: ">") else { return nil }
        let opening = text[text.index(after: text.startIndex)..<openEnd.lowerBound]
        let name = opening.prefix { !$0.isWhitespace && $0 != "/" }
        guard !name.isEmpty, isInjectedWrapper(String(name)) else { return nil }
        let openingRange = text.startIndex..<openEnd.upperBound
        guard let match = text[openEnd.upperBound...].range(of: "</\(name)", options: .caseInsensitive),
              let closingEnd = closingTagEnd(in: text, after: match.upperBound) else {
            return .init(name: String(name), opening: openingRange, closing: nil)
        }
        return .init(name: String(name), opening: openingRange,
                     closing: match.lowerBound..<closingEnd)
    }

    /// Confirms that a closing match is the wrapper itself, not a longer name,
    /// and returns the index just after its `>`.
    nonisolated private static func closingTagEnd(
        in text: String, after index: String.Index
    ) -> String.Index? {
        if index < text.endIndex {
            let character = text[index]
            guard character == ">" || character == "/" || character.isWhitespace else {
                return nil
            }
        }
        return text.range(of: ">", range: index..<text.endIndex)?.upperBound
    }

    nonisolated private static func isInjectedWrapper(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return injectedWrapperNames.contains(lowered) ||
            injectedWrapperPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Removes `<pasted_content>` wrappers wherever they appear. The user can
    /// type a character before pasting, so the wrapper is not always at the
    /// start of the content block.
    nonisolated private static func removingUserPasteWrappers(
        in text: String, keepingBody: Bool
    ) -> String {
        var output = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while let opening = text.range(of: "<pasted_content", options: .caseInsensitive,
                                      range: searchStart..<text.endIndex) {
            guard let openEnd = text.range(of: ">", range: opening.upperBound..<text.endIndex),
                  isWrapperTagEnd(text, after: opening.upperBound, before: openEnd.lowerBound) else {
                searchStart = opening.upperBound
                continue
            }
            guard let closing = text.range(of: "</pasted_content", options: .caseInsensitive,
                                             range: openEnd.upperBound..<text.endIndex),
                  let closeEnd = closingTagEnd(in: text, after: closing.upperBound) else {
                searchStart = openEnd.upperBound
                continue
            }
            var start = opening.lowerBound
            var end = closeEnd
            if !keepingBody {
                // Quotes around a paste become orphans once the body is gone.
                start = orphanQuoteStart(in: text, before: start)
                end = orphanQuoteEnd(in: text, after: end)
            }
            output += text[cursor..<start]
            if keepingBody {
                output += text[openEnd.upperBound..<closing.lowerBound]
            }
            cursor = end
            searchStart = closeEnd
        }
        output += text[cursor...]
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confirms that an opening match is the paste tag itself.
    nonisolated private static func isWrapperTagEnd(
        _ text: String, after nameEnd: String.Index, before tagEnd: String.Index
    ) -> Bool {
        guard nameEnd < tagEnd else { return false }
        let character = text[nameEnd]
        return character == ">" || character == "/" || character.isWhitespace
    }

    /// Extends a removal backwards over whitespace and a single orphan quote.
    nonisolated private static func orphanQuoteStart(
        in text: String, before index: String.Index
    ) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace {
                cursor = previous
                continue
            }
            guard orphanQuotes.contains(text[previous]) else { break }
            return previous
        }
        return index
    }

    /// Extends a removal forwards over whitespace and a single orphan quote.
    nonisolated private static func orphanQuoteEnd(
        in text: String, after index: String.Index
    ) -> String.Index {
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
                continue
            }
            guard orphanQuotes.contains(text[cursor]) else { break }
            return text.index(after: cursor)
        }
        return index
    }

    nonisolated private static let orphanQuotes: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "`",
    ]

    nonisolated static func cleanMeaningfulText(_ raw: String) -> String {
        cleanMeaningfulText(raw, keepingUserPastes: false)
    }

    /// Removes machine-injected wrappers from a user content block.
    ///
    /// Agents emit these wrappers with a fixed name, a generated suffix, or
    /// extra attributes, so the opening and closing forms must both be matched
    /// by name. A user's own paste keeps its body when the caller asks for it.
    nonisolated static func cleanMeaningfulText(
        _ raw: String, keepingUserPastes: Bool
    ) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only remove these wrappers at the beginning of a user content block.
        // Inline quotations, fenced examples and assistant answers are content.
        while let wrapper = leadingInjectedWrapper(in: text) {
            // A paste is handled below so its body and the quotes around it
            // stay consistent wherever the wrapper appears.
            if wrapper.isUserPaste { break }
            let end = wrapper.closing?.upperBound ?? wrapper.opening.upperBound
            text = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = removingUserPasteWrappers(in: text, keepingBody: keepingUserPastes)
        var output: [String] = []
        var prose: [String] = []
        var fence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let currentFence = fence {
                output.append(line)
                if trimmed.hasPrefix(currentFence),
                   trimmed.drop(while: { $0 == currentFence.first })
                    .trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                continue
            }
            let marker = trimmed.first
            let run = trimmed.prefix { $0 == marker }
            if (marker == "`" || marker == "~") && run.count >= 3 {
                if !prose.isEmpty { output.append(cleanUserProse(prose.joined(separator: "\n"))); prose = [] }
                output.append(line)
                fence = String(run)
            } else {
                prose.append(line)
            }
        }
        if !prose.isEmpty { output.append(cleanUserProse(prose.joined(separator: "\n"))) }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func cleanUserProse(_ raw: String) -> String {
        var text = raw
        let blockTags = ["recommended_plugins", "environment_context", "instructions"]
        for tag in blockTags {
            var searchStart = text.startIndex
            while let startRange = text.range(of: "<\(tag)>", options: .caseInsensitive,
                                             range: searchStart..<text.endIndex),
                  let endRange = text.range(of: "</\(tag)>", options: .caseInsensitive,
                                           range: startRange.upperBound..<text.endIndex) {
                let lineStart = text[..<startRange.lowerBound].lastIndex(of: "\n")
                    .map { text.index(after: $0) } ?? text.startIndex
                if text[lineStart..<startRange.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                    let offset = text.distance(from: text.startIndex, to: startRange.lowerBound)
                    text.removeSubrange(startRange.lowerBound..<endRange.upperBound)
                    searchStart = text.index(text.startIndex, offsetBy: offset)
                } else {
                    searchStart = endRange.upperBound
                }
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var filtered: [String] = []
        var inInstructionsBlock = false
        var inFilesBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<INSTRUCTIONS>") || trimmed.hasPrefix("<instructions>") {
                inInstructionsBlock = true
                continue
            }
            if inInstructionsBlock {
                if trimmed.hasPrefix("</INSTRUCTIONS>") || trimmed.hasPrefix("</instructions>") {
                    inInstructionsBlock = false
                }
                continue
            }
            if trimmed.hasPrefix("# Files mentioned by the user") || trimmed.hasPrefix("Files mentioned by the user") {
                inFilesBlock = true
                continue
            }
            if inFilesBlock {
                if trimmed.hasPrefix("## ") || TransientAttachmentNoise.isNoise(line: String(line)) {
                    continue
                } else if !trimmed.isEmpty {
                    inFilesBlock = false
                }
            }
            if isMeaninglessPasteOrSystemLine(trimmed) {
                continue
            }
            filtered.append(String(line))
        }
        let result = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            let fallback = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isMeaninglessPasteOrSystemLine(fallback) {
                return "[Image/Attachment]"
            }
            return ""
        }
        return result
    }

    nonisolated private static func isMeaninglessPasteOrSystemLine(_ line: String) -> Bool {
        if line.isEmpty { return false }
        let lower = line.lowercased()
        if lower.hasPrefix("# agents.md instructions") || lower.hasPrefix("agents.md instructions") {
            return true
        }
        if line.hasPrefix("@/Users/") && (line.hasSuffix(".md") || line.hasSuffix(".txt")) {
            return true
        }
        if TransientAttachmentNoise.isNoise(line: line) {
            return true
        }
        if line.hasPrefix("<cwd>") || line.hasPrefix("<shell>") ||
            line.hasPrefix("<current_date>") || line.hasPrefix("<timezone>") ||
            line.hasPrefix("<filesystem>") || line.hasPrefix("</filesystem>") ||
            line.hasPrefix("<permission_profile") || line.hasPrefix("</environment_context>") ||
            line.hasPrefix("<image") || line.hasPrefix("</image>") {
            return true
        }
        return false
    }

    nonisolated private static func normalizedTitle(
        _ rawValue: String?,
        workingDirectory: String?,
        conversationID: AgentConversationID
    ) -> String {
        if let rawValue {
            let collapsed = rawValue
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if !collapsed.isEmpty {
                return String(collapsed.prefix(140))
            }
        }
        if let workingDirectory {
            let folder = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !folder.isEmpty { return folder }
        }
        return conversationID.rawValue
    }
}
