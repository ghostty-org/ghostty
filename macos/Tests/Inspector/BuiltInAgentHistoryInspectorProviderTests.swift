import AppKit
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct AgentHistoryInspectorTests {
    @Test func revisitingHistoryKeepsTheLoadedTranscript() async throws {
        let registry = InspectorRegistry()
        let session = AgentHistorySession(agent: .pi, conversationID: AgentConversationID("retained")!,
            title: "Existing", workingDirectory: "/tmp", updatedAt: Date(), sourcePath: "/tmp/session", isActive: false)
        var reads = 0
        let provider = BuiltInAgentHistoryInspectorProvider(registry: registry, sessionLoader: { [session] },
            transcriptLoader: { session in
                reads += 1
                return .init(sessionID: session.id, messages: [], wasTruncated: false)
            })
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "Test", workingDirectory: "/tmp")
        let pane = BuiltInAgentHistoryInspectorProvider.paneID
        registry.presentationDidChange(to: pane, context: context)
        try await Task.sleep(for: .milliseconds(30))
        registry.performAction(paneID: pane, action: .init(context: context, kind: .selectAgentHistorySession(id: session.id)))
        try await Task.sleep(for: .milliseconds(30))
        registry.presentationDidChange(to: nil, context: context)
        try await Task.sleep(for: .milliseconds(30))
        registry.presentationDidChange(to: pane, context: context)
        try await Task.sleep(for: .milliseconds(30))
        guard case .agentHistory(let content) = registry.content(for: pane, context: context) else {
            Issue.record("Missing history content"); return
        }
        #expect(content.selectedSessionID == session.id)
        #expect(content.transcript != nil && !content.isLoadingTranscript)
        #expect(reads == 1)
    }

    @Test func remoteDiscoveryAppliesRangeBeforeReadingHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, days) in [("recent-session", 1), ("old-session", 180)] {
            let file = root.appendingPathComponent(".pi/agent/sessions/project/2026-01-01_\(id).jsonl")
            try writeJSONL([
                ["type": "session", "id": id, "cwd": "/repo"],
                ["type": "message", "message": ["role": "user", "content": id]],
            ], to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)],
                                                 ofItemAtPath: file.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let rootLiteral = try #require(String(data: encoder.encode(root.path), encoding: .utf8))
        let access = AgentHistoryRemoteAccess(alias: "fixture") { command in
            let script = command.replacingOccurrences(of: "os.path.expanduser('~')", with: rootLiteral)
            let result = try await GitProcessRunner().run(executablePath: "/bin/sh", arguments: ["-c", script],
                workingDirectory: root.path, maxOutputBytes: 100_000, timeout: 5)
            guard result.isSuccess, let text = String(data: result.stdout, encoding: .utf8) else {
                throw AgentHistoryRemoteError.unavailable
            }
            return text
        }
        let recent = try await access.discoverSessions(relativeRoots: [".pi/agent/sessions"], maximumSessions: 100,
                                                       updatedAfter: AgentHistoryTimeFilter.quarter.cutoff())
        #expect(recent.count == 1)
        #expect(recent.first?.file.path.contains("recent-session") == true)
        let all = try await access.discoverSessions(relativeRoots: [".pi/agent/sessions"], maximumSessions: 100)
        #expect(all.count == 2)
    }

    @Test func recentScanSkipsOldHeadersWithoutDiscardingCachedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        for (id, days) in [("recent-session", 1), ("old-session", 180)] {
            let file = root.appendingPathComponent("project/2026-01-01_\(id).jsonl")
            try writeJSONL([
                ["type": "session", "id": id, "cwd": "/repo"],
                ["type": "message", "message": ["role": "user", "content": id]],
            ], to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)],
                                                 ofItemAtPath: file.path)
        }
        let all = await AgentHistoryStore.load(agents: [.pi], rootURLs: [.pi: root], cacheURL: cache)
        #expect(all.count == 2)
        let recent = await AgentHistoryStore.load(agents: [.pi], rootURLs: [.pi: root], cacheURL: cache,
                                                  updatedAfter: AgentHistoryTimeFilter.quarter.cutoff())
        #expect(recent.map(\.conversationID.rawValue) == ["recent-session"])
        let cached = await AgentHistoryStore.loadCached(cacheURL: cache)
        #expect(cached.count == 2)
    }

    @Test func requestingAllHistoryExpandsTheHostCacheOnce() async throws {
        let registry = InspectorRegistry()
        var loads = 0
        let provider = BuiltInAgentHistoryInspectorProvider(registry: registry, sessionLoader: { loads += 1; return [] })
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "Test", workingDirectory: "/tmp")
        let pane = BuiltInAgentHistoryInspectorProvider.paneID
        registry.presentationDidChange(to: pane, context: context)
        try await Task.sleep(for: .milliseconds(30))
        #expect(loads == 1)
        registry.performAction(paneID: pane, action: .init(context: context, kind: .setAgentHistoryTimeRange(.any)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(loads == 2)
        registry.performAction(paneID: pane, action: .init(context: context, kind: .setAgentHistoryTimeRange(.year)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(loads == 2)
    }

    @Test func discoversCompressedCodexArchives() async throws {
        let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = try #require(AgentConversationID("019d05c3-3eb9-7562-b8e6-111111111111"))
        let plain = root.appendingPathComponent("rollout.jsonl")
        try writeJSONL([
            ["type": "session_meta", "payload": ["id": conversationID.rawValue, "cwd": "/repo"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                                                  "content": [["type": "input_text", "text": "Archived question"]]]],
        ], to: plain)
        guard let zstd else {
            // The archived-session reader shells out to zstd; report the skip.
            return
        }
        let archive = root.appendingPathComponent("rollout-\(conversationID.rawValue).jsonl.zst")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["--quiet", "--force", plain.path, "-o", archive.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try FileManager.default.removeItem(at: plain)

        let sessions = await AgentHistoryStore.load(
            agents: [.codex],
            rootURLs: [.codex: root],
            cacheURL: root.appendingPathComponent("cache.json")
        )
        let session = try #require(sessions.first)
        #expect(session.conversationID == conversationID)
        #expect(session.title == "Archived question")
        #expect(session.workingDirectory == "/repo")
        // Codex keeps compressed rollouts beside the live store.
        #expect(SupportedAgent.codex.definition.resume.discover?.additionalRoots?
            .contains("~/.codex/archived_sessions") == true)
    }

    @Test func discoversSessionsStoredInIdentifierDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = try #require(AgentConversationID("019fa897-1a97-7000-81b1-9a2fd2b4c2ce"))
        // omp writes each conversation into its own timestamp_ID directory and
        // names transcripts freely, so the file name carries no identifier.
        let file = root
            .appendingPathComponent("project")
            .appendingPathComponent("2026-07-28T11-58-22-871Z_\(conversationID.rawValue)")
            .appendingPathComponent("FailurePathReview.jsonl")
        try writeJSONL([
            ["type": "title", "title": ""],
            ["type": "session", "version": 3, "id": conversationID.rawValue, "cwd": "/repo"],
            ["type": "message", "message": ["role": "user", "content": "Review the failure paths"]],
        ], to: file)

        let sessions = await AgentHistoryStore.load(
            agents: [.omp],
            rootURLs: [.omp: root],
            cacheURL: root.appendingPathComponent("cache.json")
        )
        let session = try #require(sessions.first)
        #expect(session.conversationID == conversationID)
        #expect(session.title == "Review the failure paths")
    }

    @Test func timeAndFolderScopeNarrowSessions() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var state = AgentHistoryFilterState()
        state.time = .quarter
        state.directory = .currentTree

        var counter = 0
        func session(_ directory: String?, _ age: TimeInterval, agent: SupportedAgent = .pi) -> AgentHistorySession {
            counter += 1
            return AgentHistorySession(
                agent: agent,
                conversationID: AgentConversationID("scope-\(counter)")!,
                title: "Session",
                workingDirectory: directory,
                updatedAt: now.addingTimeInterval(-age),
                sourcePath: "/tmp/session",
                isActive: false
            )
        }
        let day: TimeInterval = 86_400
        #expect(state.includes(session("/repo", 10 * day), currentDirectory: "/repo/", now: now))
        #expect(state.includes(session("/repo/sub/dir", 10 * day), currentDirectory: "/repo", now: now))
        #expect(!state.includes(session("/repository", 10 * day), currentDirectory: "/repo", now: now))
        #expect(!state.includes(session("/repo", 100 * day), currentDirectory: "/repo", now: now))
        #expect(!state.includes(session(nil, 10 * day), currentDirectory: "/repo", now: now))

        state.directory = .any
        #expect(state.includes(session("/elsewhere", 10 * day), currentDirectory: "/repo", now: now))
        #expect(state.narrowsSessions)
        state.reset()
        #expect(state.time == .quarter)
        #expect(state.narrowsSessions)
        #expect(!state.includes(session(nil, 400 * day), currentDirectory: "/repo", now: now))
        state.time = .any
        #expect(!state.narrowsSessions)
        #expect(state.includes(session(nil, 400 * day), currentDirectory: "/repo", now: now))
    }

    @Test func timeFilterCutoffsMatchCalendarMath() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(AgentHistoryTimeFilter.any.cutoff(now: now, calendar: calendar) == nil)
        let quarter = try #require(AgentHistoryTimeFilter.quarter.cutoff(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.month], from: quarter, to: now).month == 3)
        let year = try #require(AgentHistoryTimeFilter.year.cutoff(now: now, calendar: calendar))
        #expect(calendar.dateComponents([.year], from: year, to: now).year == 1)
    }

    @Test func filterStateReportsDefaultAndReset() throws {
        var state = AgentHistoryFilterState.initial
        #expect(state.isDefault)
        state.agent = .pi
        #expect(!state.isDefault)
        state.grouping = .project
        state.ordering = .title
        #expect(!state.isDefault)
        state.reset()
        #expect(state == .initial)
        #expect(state.isDefault)
    }

    @Test func nativeFilterControllerBuildsSelectionsAndPublishesChanges() throws {
        let sessions = SupportedAgent.allCases.flatMap { agent in
            (0..<2).map { index in
                AgentHistorySession(
                    agent: agent,
                    conversationID: AgentConversationID("\(agent.rawValue)-\(index)")!,
                    title: "\(agent.displayName) \(index)",
                    workingDirectory: "/repo",
                    updatedAt: Date(),
                    sourcePath: "/repo/\(index)",
                    isActive: false
                )
            }
        }
        var filter = AgentHistoryFilterState()
        filter.agent = .pi
        filter.directory = .currentTree
        filter.time = .quarter
        let controller = AgentHistoryFilterController()
        var published: [AgentHistoryFilterState] = []
        controller.onChange = { published.append($0) }
        controller.update(
            sessions: sessions,
            agents: SupportedAgent.allCases,
            filter: filter,
            strings: .init(language: .english),
            currentDirectory: "/repo"
        )
        #expect(controller.preferredContentSize.width == 320)
        controller.apply("claude", to: .agent)
        #expect(published.last?.agent == .claude)
        controller.apply("month", to: .time)
        #expect(published.last?.time == .month)
    }

    @Test func refreshKeepsRowsAndPublishesLoadingState() async throws {
        let registry = InspectorRegistry()
        let gate = AgentHistoryTranscriptGate()
        let session = AgentHistorySession(agent: .pi, conversationID: AgentConversationID("refresh")!,
            title: "Existing", workingDirectory: "/tmp", updatedAt: Date(), sourcePath: "/tmp/session", isActive: false)
        var loads = 0
        let provider = BuiltInAgentHistoryInspectorProvider(registry: registry, sessionLoader: {
            loads += 1
            if loads > 1 { await gate.wait() }
            return [session]
        })
        try provider.register()
        let context = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "Test", workingDirectory: "/tmp")
        registry.presentationDidChange(to: BuiltInAgentHistoryInspectorProvider.paneID, context: context)
        for _ in 0..<50 { await Task.yield() }
        registry.performAction(paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(context: context, kind: .refreshAgentHistory))
        guard case .agentHistory(let content) = registry.content(for: BuiltInAgentHistoryInspectorProvider.paneID, context: context) else {
            Issue.record("Missing content"); return
        }
        #expect(content.sessions == [session])
        #expect(content.isLoadingSessions)
        for _ in 0..<50 { await Task.yield() }
        await gate.resume()
    }

    @Test func hostSessionStorageIsSharedAcrossTabs() async throws {
        let sessions = (0..<1000).map { index in
            AgentHistorySession(agent: .codex, conversationID: AgentConversationID("session-\(index)")!,
                title: "Session \(index)", workingDirectory: "/repo", updatedAt: .distantPast,
                sourcePath: "/tmp/session-\(index)", isActive: false)
        }
        let registry = InspectorRegistry()
        let provider = BuiltInAgentHistoryInspectorProvider(registry: registry, sessionLoader: { sessions })
        try provider.register()
        let a = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "a", workingDirectory: "/repo")
        let b = InspectorPaneContext(tabID: UUID(), surfaceID: nil, title: "b", workingDirectory: "/repo")
        registry.presentationDidChange(to: BuiltInAgentHistoryInspectorProvider.paneID, context: a)
        try await Task.sleep(for: .milliseconds(80))
        registry.presentationDidChange(to: BuiltInAgentHistoryInspectorProvider.paneID, context: b)
        guard case .agentHistory(let first) = registry.content(for: BuiltInAgentHistoryInspectorProvider.paneID, context: a),
              case .agentHistory(let second) = registry.content(for: BuiltInAgentHistoryInspectorProvider.paneID, context: b) else {
            Issue.record("Missing history snapshots"); return
        }
        #expect(first.sessions.count == 1000 && second.sessions.count == 1000)
        let left = first.sessions.withUnsafeBufferPointer { $0.baseAddress }
        let right = second.sessions.withUnsafeBufferPointer { $0.baseAddress }
        #expect(left == right, "Per-tab snapshots should share host metadata storage")
        registry.closeTab(a.tabID); provider.forgetTab(a.tabID)
        #expect(registry.content(for: BuiltInAgentHistoryInspectorProvider.paneID, context: b) == .agentHistory(second))
    }

    @Test func discoversAndParsesAgentSpecificLocalHistories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-\(UUID().uuidString)")
        let piRoot = root.appendingPathComponent("pi")
        let codexRoot = root.appendingPathComponent("codex")
        defer { try? FileManager.default.removeItem(at: root) }

        let piID = try #require(AgentConversationID("pi-session-1"))
        let piFile = piRoot
            .appendingPathComponent("project")
            .appendingPathComponent("2026-09-03_\(piID.rawValue).jsonl")
        try writeJSONL([
            [
                "type": "session",
                "version": 3,
                "id": piID.rawValue,
                "timestamp": "2026-09-03T01:00:00.000Z",
                "cwd": "/Users/test/pi-project",
            ],
            [
                "type": "message",
                "timestamp": "2026-09-03T01:01:00.000Z",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": "Implement the parser"]],
                ],
            ],
            [
                "type": "message",
                "timestamp": "2026-09-03T01:02:00.000Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "Parser implemented"]],
                ],
            ],
        ], to: piFile)

        let codexID = try #require(AgentConversationID("codex-session-1"))
        let codexFile = codexRoot
            .appendingPathComponent("2026/09/03")
            .appendingPathComponent("rollout-\(codexID.rawValue).jsonl")
        try writeJSONL([
            [
                "type": "session_meta",
                "timestamp": "2026-09-03T02:00:00.000Z",
                "payload": [
                    "id": codexID.rawValue,
                    "cwd": "/Users/test/codex-project",
                ],
            ],
            [
                "type": "response_item",
                "timestamp": "2026-09-03T02:01:00.000Z",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Review the patch"]],
                ],
            ],
        ], to: codexFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: codexFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: piFile.path
        )

        let sessions = await AgentHistoryStore.load(
            agents: [.pi, .codex],
            rootURLs: [.pi: piRoot, .codex: codexRoot],
            maximumSessions: 10
        )

        #expect(sessions.map(\.id) == [
            "codex:\(codexID.rawValue)",
            "pi:\(piID.rawValue)",
        ])
        #expect(sessions[0].title == "Review the patch")
        #expect(sessions[0].workingDirectory == "/Users/test/codex-project")
        #expect(sessions[1].title == "Implement the parser")
        #expect(sessions[1].workingDirectory == "/Users/test/pi-project")

        let transcript = await AgentHistoryStore.transcript(for: sessions[1])
        #expect(transcript.sessionID == sessions[1].id)
        #expect(transcript.messages.map(\.role) == [.user, .assistant])
        #expect(transcript.messages.map(\.text) == [
            "Implement the parser",
            "Parser implemented",
        ])
        #expect(!transcript.wasTruncated)
    }

    @Test func codexTitleAndFullBodySearchSkipInjectedPrompts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-codex-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try #require(AgentConversationID("codex-search-session"))
        let file = root
            .appendingPathComponent("2026/09/03")
            .appendingPathComponent("rollout-\(id.rawValue).jsonl")
        var objects: [[String: Any]] = [
            [
                "type": "session_meta",
                "payload": [
                    "id": id.rawValue,
                    "cwd": "/Users/test/education",
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "role": "developer",
                    "content": [[
                        "type": "input_text",
                        "text": String(repeating: "system context ", count: 6_000),
                    ]],
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "<recommended_plugins>noise</recommended_plugins>"],
                        ["type": "input_text", "text": "# AGENTS.md instructions\n<INSTRUCTIONS>noise</INSTRUCTIONS>"],
                        ["type": "input_text", "text": "<environment_context>noise</environment_context>"],
                    ],
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "查找融合教育教师编制要求",
                    ]],
                ],
            ],
        ]
        for index in 0..<80 {
            objects.append([
                "type": "event_msg",
                "payload": ["message": String(repeating: "filler", count: 1_000)],
            ])
            if index == 79 {
                objects.append([
                    "type": "response_item",
                    "payload": [
                        "role": "assistant",
                        "content": [[
                            "type": "output_text",
                            "text": "正文深处包含唯一关键字：编制资格核验",
                        ]],
                    ],
                ])
            }
        }
        try writeJSONL(objects, to: file)

        let sessions = await AgentHistoryStore.load(
            agents: [.codex],
            rootURLs: [.codex: root],
            maximumSessions: 10,
            cacheURL: root.appendingPathComponent("cache.json")
        )
        let session = try #require(sessions.first)
        #expect(session.title == "查找融合教育教师编制要求")
        #expect(session.previewSnippet?.contains("融合教育") == true)

        var titleUpdates = AgentHistoryStore.searchUpdates(
            sessions: sessions,
            query: "融合教育"
        ).makeAsyncIterator()
        let firstTitleBatch = await titleUpdates.next()
        #expect(firstTitleBatch?[session.id]?.contains("融合教育") == true)

        let matches = await AgentHistoryStore.search(
            sessions: sessions,
            query: "编制资格核验"
        )
        #expect(matches[session.id]?.contains("编制资格核验") == true)

        let transcript = await AgentHistoryStore.transcript(for: session)
        #expect(transcript.messages.contains {
            $0.text.contains("查找融合教育教师编制要求")
        })
        #expect(transcript.messages.contains {
            $0.text.contains("编制资格核验")
        })
        #expect(!transcript.messages.contains {
            $0.text.contains("recommended_plugins")
        })
    }

    @Test func rejectsFilenameAndMetadataConversationMismatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("project/2026_filename-id.jsonl")
        try writeJSONL([
            [
                "type": "session",
                "id": "different-id",
                "timestamp": "2026-09-03T01:00:00.000Z",
                "cwd": "/tmp/project",
            ],
        ], to: file)

        let sessions = await AgentHistoryStore.load(
            agents: [.pi],
            rootURLs: [.pi: root],
            maximumSessions: 10
        )
        #expect(sessions.isEmpty)
    }

    @Test func discoversEveryManifestBackedJSONLStorePattern() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-patterns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeRoot = root.appendingPathComponent("claude")
        let piRoot = root.appendingPathComponent("pi")
        let qoderRoot = root.appendingPathComponent("qoder")
        let ompRoot = root.appendingPathComponent("omp")
        let qwenRoot = root.appendingPathComponent("qwen")
        let roots: [SupportedAgent: URL] = [
            .claude: claudeRoot,
            .pi: piRoot,
            .qoder: qoderRoot,
            .omp: ompRoot,
            .qwen: qwenRoot,
        ]

        try writeJSONL([
            [
                "type": "user",
                "sessionId": "claude-history",
                "cwd": "/tmp/claude",
                "message": ["role": "user", "content": "Claude history"],
            ],
        ], to: claudeRoot
            .appendingPathComponent("project/claude-history.jsonl"))
        try writeJSONL([
            [
                "type": "session",
                "id": "pi-history",
                "cwd": "/tmp/pi",
            ],
        ], to: piRoot
            .appendingPathComponent("project/date_pi-history.jsonl"))
        try writeJSONL([
            [
                "type": "user",
                "sessionId": "qoder-history",
                "cwd": "/tmp/qoder",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": "Qoder history"]],
                ],
            ],
        ], to: qoderRoot
            .appendingPathComponent("project/qoder-history.jsonl"))
        try writeJSONL([
            ["type": "title", "title": "OMP history"],
            [
                "type": "session",
                "id": "omp-history",
                "cwd": "/tmp/omp",
            ],
        ], to: ompRoot
            .appendingPathComponent("project/date_omp-history.jsonl"))
        try writeJSONL([
            [
                "type": "session",
                "id": "qwen-history",
                "cwd": "/tmp/qwen",
            ],
        ], to: qwenRoot
            .appendingPathComponent("bucket/chats/qwen-history.jsonl"))

        let sessions = await AgentHistoryStore.load(
            agents: [.claude, .pi, .qoder, .omp, .qwen],
            rootURLs: roots,
            maximumSessions: 20
        )
        #expect(Set(sessions.map(\.agent)) == [
            .claude,
            .pi,
            .qoder,
            .omp,
            .qwen,
        ])
        #expect(sessions.first(where: { $0.agent == .omp })?.title == "OMP history")
        #expect(sessions.first(where: { $0.agent == .qwen })?.conversationID.rawValue ==
            "qwen-history")
    }

    @Test func registrationDoesNotLoadHistoryUntilPaneAppears() async throws {
        var refreshLoadCount = 0
        let registry = InspectorRegistry()
        let provider = BuiltInAgentHistoryInspectorProvider(
            registry: registry,
            sessionLoader: {
                refreshLoadCount += 1
                return []
            },
            transcriptLoader: { session in
                .init(sessionID: session.id, messages: [], wasTruncated: false)
            },
            sessionResumer: { _, _ in },
            sessionForker: { _, _ in }
        )

        try provider.register()
        await Task.yield()
        #expect(refreshLoadCount == 0)

        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Terminal",
            workingDirectory: "/tmp"
        )
        registry.presentationDidChange(
            to: BuiltInAgentHistoryInspectorProvider.paneID,
            context: context
        )
        for _ in 0..<20 where refreshLoadCount == 0 {
            await Task.yield()
        }
        #expect(refreshLoadCount == 1)
    }

    @Test func contextReplacementKeepsTranscriptLoadAlive() async throws {
        let session = AgentHistorySession(
            agent: .pi,
            conversationID: try #require(AgentConversationID("context-session")),
            title: "Context session",
            workingDirectory: "/tmp/project",
            updatedAt: Date(),
            sourcePath: "/tmp/context-session.jsonl",
            isActive: false
        )
        let transcript = AgentHistoryTranscript(
            sessionID: session.id,
            messages: [
                .init(
                    id: "message",
                    role: .assistant,
                    text: "Still loading",
                    timestamp: nil
                ),
            ],
            wasTruncated: false
        )
        let gate = AgentHistoryTranscriptGate()
        let registry = InspectorRegistry()
        let provider = BuiltInAgentHistoryInspectorProvider(
            registry: registry,
            sessionLoader: { [session] },
            transcriptLoader: { _ in
                await gate.wait()
                return transcript
            },
            sessionResumer: { _, _ in }
        )
        try provider.register()
        let tabID = UUID()
        let context = InspectorPaneContext(
            tabID: tabID,
            surfaceID: UUID(),
            title: "Before",
            workingDirectory: "/tmp/project"
        )
        registry.presentationDidChange(
            to: BuiltInAgentHistoryInspectorProvider.paneID,
            context: context
        )
        for _ in 0..<20 {
            if case .agentHistory(let value) = registry.content(
                for: BuiltInAgentHistoryInspectorProvider.paneID,
                context: context
            ), value.sessions.count == 1 { break }
            await Task.yield()
        }
        registry.performAction(
            paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .selectAgentHistorySession(id: session.id)
            )
        )
        for _ in 0..<20 {
            if await gate.started { break }
            await Task.yield()
        }
        #expect(await gate.started)

        let updated = InspectorPaneContext(
            tabID: tabID,
            surfaceID: context.surfaceID,
            title: "After",
            workingDirectory: "/tmp/project"
        )
        registry.presentationDidChange(
            to: BuiltInAgentHistoryInspectorProvider.paneID,
            context: updated
        )
        await gate.resume()

        var loaded: InspectorAgentHistoryContent?
        for _ in 0..<20 {
            if case .agentHistory(let value) = registry.content(
                for: BuiltInAgentHistoryInspectorProvider.paneID,
                context: updated
            ), value.transcript == transcript {
                loaded = value
                break
            }
            await Task.yield()
        }
        #expect(loaded?.transcript == transcript)
        #expect(loaded?.isLoadingTranscript == false)
    }

    @Test func providerLoadsTranscriptAndRoutesTypedResumeAndForkActions() async throws {
        let session = AgentHistorySession(
            agent: .pi,
            conversationID: try #require(AgentConversationID("session-42")),
            title: "Continue feature work",
            workingDirectory: "/Users/test/project",
            updatedAt: Date(timeIntervalSince1970: 42),
            sourcePath: "/tmp/session-42.jsonl",
            isActive: false
        )
        let transcript = AgentHistoryTranscript(
            sessionID: session.id,
            messages: [
                .init(
                    id: "message-1",
                    role: .user,
                    text: "Continue feature work",
                    timestamp: nil
                ),
            ],
            wasTruncated: false
        )
        var resumedIDs: [String] = []
        var forkedIDs: [String] = []
        let registry = InspectorRegistry()
        let provider = BuiltInAgentHistoryInspectorProvider(
            registry: registry,
            sessionLoader: { [session] },
            transcriptLoader: { _ in transcript },
            sessionResumer: { session, _ in resumedIDs.append(session.id) },
            sessionForker: { session, _ in forkedIDs.append(session.id) }
        )
        try provider.register()
        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: UUID(),
            title: "Project",
            workingDirectory: "/Users/test/project"
        )

        registry.presentationDidChange(
            to: BuiltInAgentHistoryInspectorProvider.paneID,
            context: context
        )
        var content: InspectorAgentHistoryContent?
        for _ in 0..<20 {
            if case .agentHistory(let value) = registry.content(
                for: BuiltInAgentHistoryInspectorProvider.paneID,
                context: context
            ), value.sessions.count == 1 {
                content = value
                break
            }
            await Task.yield()
        }
        #expect(content?.sessions.map(\.id) == [session.id])

        registry.performAction(
            paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .selectAgentHistorySession(id: session.id)
            )
        )
        for _ in 0..<20 {
            if case .agentHistory(let value) = registry.content(
                for: BuiltInAgentHistoryInspectorProvider.paneID,
                context: context
            ), value.transcript == transcript {
                content = value
                break
            }
            await Task.yield()
        }
        #expect(content?.selectedSessionID == session.id)
        #expect(content?.transcript == transcript)

        registry.performAction(
            paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .resumeAgentHistorySession(id: session.id)
            )
        )
        #expect(resumedIDs == [session.id])

        registry.performAction(
            paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(
                context: context,
                kind: .forkAgentHistorySession(id: session.id)
            )
        )
        #expect(forkedIDs == [session.id])

        registry.performAction(
            paneID: BuiltInAgentHistoryInspectorProvider.paneID,
            action: .init(context: context, kind: .clearAgentHistorySelection)
        )
        guard case .agentHistory(let cleared) = registry.content(
            for: BuiltInAgentHistoryInspectorProvider.paneID,
            context: context
        ) else {
            Issue.record("Expected Agent History content")
            return
        }
        #expect(cleared.selectedSessionID == nil)
        #expect(cleared.transcript == nil)
    }

    @Test func forkCommandsMatchSupportedAgentDialects() throws {
        let claudeSession = AgentHistorySession(
            agent: .claude,
            conversationID: try #require(AgentConversationID("claude-123")),
            title: "Claude session",
            workingDirectory: "/tmp/claude",
            updatedAt: Date(),
            sourcePath: "/tmp/c.jsonl",
            isActive: false
        )
        let piSession = AgentHistorySession(
            agent: .pi,
            conversationID: try #require(AgentConversationID("pi-123")),
            title: "Pi session",
            workingDirectory: "/tmp/pi",
            updatedAt: Date(),
            sourcePath: "/tmp/p.jsonl",
            isActive: false
        )
        let codexSession = AgentHistorySession(
            agent: .codex,
            conversationID: try #require(AgentConversationID("codex-123")),
            title: "Codex session",
            workingDirectory: "/tmp/codex",
            updatedAt: Date(),
            sourcePath: "/tmp/cx.jsonl",
            isActive: false
        )

        let claudeCmd = try #require(BuiltInAgentHistoryInspectorProvider.forkCommand(for: claudeSession))
        #expect(claudeCmd.contains("--fork-session"))
        #expect(claudeCmd.contains("claude-123"))

        let piCmd = try #require(BuiltInAgentHistoryInspectorProvider.forkCommand(for: piSession))
        #expect(piCmd.contains("--fork"))
        #expect(piCmd.contains("pi-123"))

        let codexCmd = try #require(BuiltInAgentHistoryInspectorProvider.forkCommand(for: codexSession))
        #expect(codexCmd.contains("fork"))
        #expect(codexCmd.contains("codex-123"))
    }

    @Test func filtersMeaninglessPasteAndTemporaryPathLines() {
        let dirty = """
        帮我看看这个报错
        /var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-paste/omg-paste-199BDD0B-A08E-485E-BCB2-F2669FEE9D7B.png
        <recommended_plugins>
        - Atlassian Rovo
        </recommended_plugins>
        # AGENTS.md instructions
        <INSTRUCTIONS>
        - Always reply in Chinese.
        @/Users/chengjisheng/.codex/RTK.md
        </INSTRUCTIONS>
        <environment_context>
        <cwd>/Users/test</cwd>
        </environment_context>
        这是第二行说明
        """
        let cleaned = AgentHistoryStore.cleanMeaningfulText(dirty)
        #expect(!cleaned.contains("omg-paste"))
        #expect(!cleaned.contains("recommended_plugins"))
        #expect(!cleaned.contains("AGENTS.md instructions"))
        #expect(!cleaned.contains("<environment_context>"))
        #expect(cleaned.contains("帮我看看这个报错"))
        #expect(cleaned.contains("这是第二行说明"))

        let isolatedPath = "/var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/otty-paste/image-12345.png"
        #expect(AgentHistoryStore.cleanMeaningfulText(isolatedPath) == "[Image/Attachment]")
    }

    @Test func remoteSessionEnumerationAndTranscript() async throws {
        let sessionFile = "/home/test/.pi/agent/sessions/--home-test-proj--/2026_remote-123.jsonl"
        let remoteListing = """
        -rw-r--r-- 1 test test 240 Sep 04 12:00 \(sessionFile)
        """
        let remoteHeader = """
        {"type":"session","id":"remote-123","cwd":"/home/test/proj"}
        {"type":"message","message":{"role":"user","content":"远程测试提问"}}
        {"type":"message","message":{"role":"assistant","content":"这是远程的回复"}}

        """

        let access = AgentHistoryRemoteAccess(alias: "cloud") { command in
            if command.contains("OMG_HISTORY_PY") {
                return """
                ===OMG_FILE===\(remoteListing)
                \(remoteHeader)
                ===OMG_END===
                """
            }
            if command.contains("head -c") {
                return remoteHeader
            }
            return ""
        }

        let sessions = await AgentHistoryStore.loadRemote(access: access, agents: [.pi])
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.agent == .pi)
        #expect(session.remoteHost == "cloud")
        #expect(session.conversationID.rawValue == "remote-123")
        #expect(session.title == "远程测试提问")
        #expect(session.workingDirectory == "/home/test/proj")

        let transcript = await AgentHistoryStore.transcript(
            for: session,
            remoteAccess: access
        )
        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[0].text == "远程测试提问")
        #expect(transcript.messages[1].role == .assistant)
        #expect(transcript.messages[1].text == "这是远程的回复")
    }

    @Test func remoteMetadataOverridesGenericSessionFilename() async throws {
        let path = "/home/test/.pi/agent/sessions/project/session.jsonl"
        let listing = "-rw-r--r-- 1 test test 120 Sep 04 12:00 \(path)"
        let header = """
        {"type":"session","id":"remote-generic-456","cwd":"/home/test/project"}
        {"type":"message","message":{"role":"user","content":"Generic remote session"}}

        """
        let access = AgentHistoryRemoteAccess(alias: "cloud") { command in
            guard command.contains("OMG_HISTORY_PY") else {
                return ""
            }
            return """
            ===OMG_FILE===\(listing)
            \(header)
            ===OMG_END===
            """
        }

        let sessions = await AgentHistoryStore.loadRemote(
            access: access,
            agents: [.pi]
        )
        let session = try #require(sessions.first)
        #expect(session.conversationID.rawValue == "remote-generic-456")
        #expect(session.title == "Generic remote session")
    }

    @Test func remoteNumericTimestampAndNamedPiSession() async throws {
        let timestamp = 1_800_000_000.0
        let object: [String: Any] = [
            "path": "/home/test/.pi/agent/sessions/project/session.jsonl", "size": 500,
            "modified": timestamp, "records": [
                ["type": "session", "id": "named-session", "cwd": "/repo"],
                ["type": "session_info", "title": "Named Pi session"],
            ],
        ]
        let output = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let access = AgentHistoryRemoteAccess(alias: "cloud") { command in
            #expect(!command.contains("ls -ld"))
            return output
        }
        let sessions = await AgentHistoryStore.loadRemote(access: access, agents: [.pi])
        let session = try #require(sessions.first)
        #expect(session.updatedAt.timeIntervalSince1970 == timestamp)
        #expect(session.title == "Named Pi session")
    }

    @Test func antigravityHistoryUsesSummaryIndexAndResumeArgument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try Data().write(to: conversations.appendingPathComponent("agy-session.db"))
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("conversation_summaries.db").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE conversation_summaries (conversation_id TEXT, title TEXT, preview TEXT, workspace_uris TEXT, last_modified_time TEXT); INSERT INTO conversation_summaries VALUES ('agy-session', 'Agy title', 'Preview', '[\"file:///tmp/my%20project\"]', '2026-10-01 12:00:00+00:00');", nil, nil, nil) == SQLITE_OK)
        let sessions = await AgentHistoryStore.load(agents: [.antigravity], rootURLs: [.antigravity: conversations],
            cacheURL: root.appendingPathComponent("cache.json"))
        let session = try #require(sessions.first)
        #expect(session.title == "Agy title")
        #expect(session.workingDirectory == "/tmp/my project")
        #expect(session.updatedAt.timeIntervalSince1970 > 1_700_000_000)
        #expect(SupportedAgent.antigravity.definition.resume.resumeArguments == ["--conversation", "{id}"])
        let transcript = await AgentHistoryStore.transcript(for: session)
        #expect(transcript.wasTruncated)
        #expect(transcript.messages.first?.text == "Preview")
    }

    @Test func cacheDropsDeletedSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/2026_deleted-session.jsonl")
        let cache = root.appendingPathComponent("cache.json")
        try writeJSONL([["type": "session", "id": "deleted-session", "cwd": "/repo"]], to: file)
        let sessions = await AgentHistoryStore.load(agents: [.pi],
            rootURLs: [.pi: file.deletingLastPathComponent()], cacheURL: cache)
        #expect(sessions.count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(await AgentHistoryStore.loadCached(cacheURL: cache).isEmpty)
        #expect(await AgentHistoryStore.load(agents: [.pi],
            rootURLs: [.pi: file.deletingLastPathComponent()], cacheURL: cache).isEmpty)
        #expect(await AgentHistoryStore.loadCached(cacheURL: cache).isEmpty)
    }

    private func writeJSONL(
        _ objects: [[String: Any]],
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try objects.map {
            try JSONSerialization.data(withJSONObject: $0)
        }.reduce(into: Data()) { result, object in
            result.append(object)
            result.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

private actor AgentHistoryTranscriptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
