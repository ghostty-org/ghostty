import AppKit
import Foundation
import Testing
@testable import Ghostty

struct AgentStatusPluginTests {
    private let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func mapsTypedContextSignalsForEverySupportedAgent() throws {
        for agent in SupportedAgent.allCases {
            var reducer = AgentContextSignalReducer()
            let idleUpdate = reducer.consume(signal(
                agent: agent,
                state: "idle"
            ))
            let idle = try #require(idleUpdate)
            guard case .set(let idleActivity) = idle else {
                Issue.record("Expected idle activity for \(agent.rawValue)")
                continue
            }
            #expect(idleActivity.source == agent.rawValue)
            #expect(idleActivity.state == .idle)
            #expect(idleActivity.icon == agent.icon)
            #expect(idleActivity.icon?.kind == .bundledAsset)
            #expect(idleActivity.icon?.name == agent.glyphAssetName)

            let waitingUpdate = reducer.consume(signal(
                agent: agent,
                state: "needsAttention",
                attention: .permission
            ))
            let waiting = try #require(waitingUpdate)
            guard case .set(let waitingActivity) = waiting else {
                Issue.record("Expected waiting activity for \(agent.rawValue)")
                continue
            }
            #expect(waitingActivity.state == .needsAttention)
            #expect(waitingActivity.attentionKind == .permission)

            let endUpdate = reducer.consume(.init(
                action: .end,
                id: "omg-agent-\(agent.rawValue)",
                metadata: "type=app;omg_agent=\(agent.rawValue)"
            ))
            guard case .set(let interrupted) = endUpdate else {
                Issue.record("Expected interruption error for \(agent.rawValue)")
                continue
            }
            #expect(interrupted.state == .error)
            #expect(reducer.acknowledgeTerminalState() == .clear)
        }
    }

    @Test func mapsBackgroundPhaseOnlyForWorkingActivity() throws {
        var reducer = AgentContextSignalReducer()
        guard case .set(let background) = reducer.consume(.init(
            action: .start,
            id: "omg-agent-pi-41",
            metadata: "type=app;omg_agent=pi;omg_scope=local;" +
                "omg_state=working;omg_phase=background"
        )) else {
            Issue.record("Expected background working activity")
            return
        }
        #expect(background.state == .working)
        #expect(background.phase == .background)

        guard case .set(let done) = reducer.consume(.init(
            action: .start,
            id: "omg-agent-pi-41",
            metadata: "type=app;omg_agent=pi;omg_scope=local;" +
                "omg_state=done;omg_phase=background"
        )) else {
            Issue.record("Expected done activity")
            return
        }
        #expect(done.state == .done)
        #expect(done.phase == nil)
    }

    @Test func boundsTrackedAgentContextsAndEvictsOldest() {
        var reducer = AgentContextSignalReducer()
        let overflow = 5
        for instance in 1...(AgentContextSignalReducer.maximumTrackedContexts + overflow) {
            _ = reducer.consume(signal(
                agent: .pi,
                state: "idle",
                instance: instance
            ))
        }

        #expect(
            reducer.trackedContextCount ==
                AgentContextSignalReducer.maximumTrackedContexts
        )
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-1",
            metadata: "type=app;omg_agent=pi"
        )) == nil)
        #expect(
            reducer.trackedContextCount ==
                AgentContextSignalReducer.maximumTrackedContexts
        )

        _ = reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-\(AgentContextSignalReducer.maximumTrackedContexts + overflow)",
            metadata: "type=app;omg_agent=pi"
        ))
        #expect(
            reducer.trackedContextCount ==
                AgentContextSignalReducer.maximumTrackedContexts - 1
        )
    }

    @Test func bundledAgentCatalogDefinesHooksAndResume() {
        let expected: [SupportedAgent: (String, String, Int)] = [
            .codex: ("codex", "AgentOpenAI", 7),
            .claude: ("claude", "AgentClaude", 8),
            .pi: ("pi", "AgentPi", 7),
            .qoder: ("qodercli", "AgentQoder", 7),
            .reasonix: ("reasonix", "AgentReasonixGlyph", 8),
            .omp: ("omp", "AgentOMP", 4),
            .opencode: ("opencode", "AgentOpenCode", 4),
            .amp: ("amp", "AgentAmp", 2),
            .antigravity: ("agy", "AgentAntigravity", 3),
            .cline: ("cline", "AgentCline", 7),
            .copilot: ("copilot", "AgentCopilot", 5),
            .crush: ("crush", "AgentCrushGlyph", 0),
            .cursor: ("cursor-agent", "AgentCursor", 5),
            .droid: ("droid", "AgentDroidGlyph", 5),
            .grok: ("grok", "AgentGrok", 5),
            .hermes: ("hermes", "AgentHermesGlyph", 4),
            .kimi: ("kimi", "AgentKimi", 3),
            .qwen: ("qwen", "AgentQwen", 5),
        ]
        for agent in SupportedAgent.allCases {
            let definition = agent.definition
            let value = expected[agent]
            #expect(definition.id == agent.rawValue)
            #expect(definition.command == value?.0)
            #expect(definition.iconAsset == value?.1)
            #expect(definition.hook.events.count == value?.2)
        }
        let bundledDialects = Set(SupportedAgent.allCases.compactMap {
            $0.definition.hook.dialect
        })
        #expect(bundledDialects == Set(AgentDefinition.HookSpec.Dialect.allCases))
        #expect(SupportedAgent.codex.definition.resume.discover != nil)
        #expect(SupportedAgent.claude.definition.resume.store != nil)
        #expect(SupportedAgent.pi.definition.resume.seed == "pi-session-file")
        #expect(SupportedAgent.codex.definition.hook.conversationField == "session_id")
        #expect(SupportedAgent.claude.definition.hook.transcriptField == "transcript_path")
    }

    /// Every Agent identity asset must be a monochrome template so Settings and the
    /// Inspector follow the system foreground colour, exactly like tab glyphs. A
    /// raster brand image on an opaque background rendered as a fixed colour block
    /// and was the only agent-to-agent inconsistency in those surfaces.
    @Test @MainActor func identityAssetsAreTintedTemplates() throws {
        for agent in SupportedAgent.allCases {
            let definition = agent.definition
            #expect(definition.iconAsset.isEmpty == false)
            let image = try #require(
                NSImage(named: definition.iconAsset),
                "Missing identity asset \(definition.iconAsset) for \(agent.rawValue)"
            )
            #expect(
                image.isTemplate,
                "\(definition.iconAsset) must be a template so it follows the system appearance"
            )
            #expect(renderedPixelCount(image) > 100)
            if let glyph = definition.iconGlyph {
                #expect(glyph != definition.iconAsset)
            }
        }
    }

    @Test func restoredTitleMetadataIsOptionalAndSurvivesRoundTrip() throws {
        let legacy = Data(#"{"version":1,"agent":"codex","scope":"local","workingDirectory":"/tmp"}"#.utf8)
        var descriptor = try JSONDecoder().decode(AgentResumeDescriptor.self, from: legacy)
        #expect(descriptor.isValid)
        #expect(descriptor.restoredTitle == nil)
        descriptor.restoredTitle = "History title"
        let data = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(AgentResumeDescriptor.self, from: data) == descriptor)
        descriptor.restoredTitle = "invalid\0title"
        #expect(!descriptor.isValid)
    }

    @Test func buildsOnlyAllowlistedAgentResumeCommands() throws {
        let conversation = try #require(AgentConversationID("019f-test_session"))
        let codex = AgentResumeDescriptor(
            agent: .codex,
            conversationID: conversation,
            scope: .local,
            workingDirectory: "/tmp/project"
        )
        let command = try #require(codex.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
            verifyLocalStore: false
        ))
        for token in ["codex", "resume", "019f-test_session"] {
            #expect(command.contains(token))
        }
        #expect(command.contains("\"${SHELL:-/bin/zsh}\" -l -i -c"))
        #expect(command.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        let remote = AgentResumeDescriptor(
            agent: .pi,
            conversationID: conversation,
            scope: .remote,
            workingDirectory: "/home/user/project",
            sshReplay: .init(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: ["cloud"]
            )
        )
        let remoteCommand = try #require(remote.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(remoteCommand.contains("--remote-agent=pi"))
        #expect(remoteCommand.contains("--remote-agent-session=019f-test_session"))
        #expect(remoteCommand.contains("--remote-working-directory=/home/user/project"))

        let remoteWithoutConversation = AgentResumeDescriptor(
            agent: .pi,
            conversationID: nil,
            scope: .remote,
            workingDirectory: "/home/user/project",
            sshReplay: .init(
                version: 1,
                ssh: "/usr/bin/ssh",
                forwardEnv: true,
                terminfo: true,
                cache: true,
                args: ["cloud"]
            )
        )
        let reconnectCommand = try #require(remoteWithoutConversation.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg"
        ))
        #expect(reconnectCommand.contains("'+ssh'"))
        #expect(reconnectCommand.contains("'--'"))
        #expect(!reconnectCommand.contains("--remote-agent"))
        #expect(!reconnectCommand.contains("--remote-agent-session"))
        let encoded = try JSONEncoder().encode(remote)
        #expect(try JSONDecoder().decode(
            AgentResumeDescriptor.self,
            from: encoded
        ) == remote)
        let expectedResumeTokens: [SupportedAgent: [String]] = [
            .claude: ["claude", "--resume", "019f-test_session"],
            .qoder: ["qodercli", "--resume", "019f-test_session"],
            .reasonix: ["reasonix", "--resume", "019f-test_session"],
            .omp: ["omp", "--resume=019f-test_session"],
            .opencode: ["opencode", "--session", "019f-test_session"],
            .grok: ["grok", "--resume", "019f-test_session"],
            .qwen: ["qwen", "--resume", "019f-test_session"],
        ]
        for (agent, tokens) in expectedResumeTokens {
            let descriptor = AgentResumeDescriptor(
                agent: agent,
                conversationID: conversation,
                scope: .local,
                workingDirectory: "/tmp/project"
            )
            let command = try #require(descriptor.restorationCommand(
                executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
                verifyLocalStore: false
            ))
            for token in tokens {
                #expect(command.contains(token))
            }
        }
        #expect(AgentConversationID("bad session") == nil)
        #expect(AgentConversationID("../escape") == nil)
    }

    @Test func localRestoreLoadsAgentFromLoginShellPATH() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-agent-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let shell = root.appendingPathComponent("test-shell")
        let pi = root.appendingPathComponent("pi")
        let output = root.appendingPathComponent("pi-args.txt")
        try """
        #!/bin/sh
        PATH="$OMG_TEST_BIN:$PATH"
        export PATH
        command_string=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-c" ]; then
            shift
            command_string=$1
            break
          fi
          shift
        done
        if [ -n "$command_string" ]; then
          exec /bin/sh -c "$command_string"
        fi
        exit 0
        """.write(to: shell, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" > "$OMG_TEST_OUTPUT"
        exit 0
        """.write(to: pi, atomically: true, encoding: .utf8)
        for url in [shell, pi] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }

        let conversation = try #require(AgentConversationID("019f-path-test"))
        let descriptor = AgentResumeDescriptor(
            agent: .pi,
            conversationID: conversation,
            scope: .local,
            workingDirectory: root.path
        )
        let command = try #require(descriptor.restorationCommand(
            executablePath: "/Applications/OMG.app/Contents/MacOS/omg",
            verifyLocalStore: false
        ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "SHELL": shell.path,
            "PATH": "/usr/bin:/bin",
            "OMG_TEST_BIN": root.path,
            "OMG_TEST_OUTPUT": output.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: output, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) ==
            "--session-id 019f-path-test")
    }

    @Test func extractsValidatedConversationIdentityFromContextSignal() throws {
        let update = AgentContextSignalReducer.sessionSignal(from: .init(
            action: .start,
            id: "omg-agent-codex-42",
            metadata: "type=app;omg_agent=codex;omg_scope=local;" +
                "omg_state=working;omg_conversation=019f-test_session"
        ))
        let signal = try #require(update)
        #expect(signal.agent == .codex)
        #expect(signal.scope == .local)
        #expect(signal.conversationID?.rawValue == "019f-test_session")
        #expect(signal.workingDirectory == nil)
    }

    @Test func extractsSessionWorkingDirectoryFromContextSignal() throws {
        // Mirrors how the Pi extension encodes the value with
        // encodeURIComponent ("/" becomes %2F, spaces become %20).
        let signal = try #require(AgentContextSignalReducer.sessionSignal(from: .init(
            action: .start,
            id: "omg-agent-pi-42",
            metadata: "type=app;omg_agent=pi;omg_scope=remote;" +
                "omg_state=working;omg_conversation=019f-test_session;" +
                "omg_cwd=%2Fhome%2Fuser%2Fcode%2Fsome%20project"
        )))
        #expect(signal.conversationID?.rawValue == "019f-test_session")
        #expect(signal.workingDirectory == "/home/user/code/some project")
    }

    @Test func rejectsInvalidSessionWorkingDirectoryFromContextSignal() throws {
        for rawCwd in [
            "relative/path",
            "",
            "/nul\u{0}byte",
            "/" + String(repeating: "a", count: 4_097),
        ] {
            let signal = try #require(AgentContextSignalReducer.sessionSignal(from: .init(
                action: .start,
                id: "omg-agent-pi-42",
                metadata: "type=app;omg_agent=pi;omg_scope=local;" +
                    "omg_state=working;omg_conversation=019f-test_session;" +
                    "omg_cwd=\(rawCwd)"
            )))
            #expect(signal.workingDirectory == nil)
        }
    }

    @Test func discoversExactConversationFromBoundedSessionStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexFile = root.appendingPathComponent("2026/08/25/rollout.jsonl")
        try FileManager.default.createDirectory(
            at: codexFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "019f-codex", "cwd": "/tmp/project"],
        ]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0A)
        try data.write(to: codexFile)
        #expect(AgentConversationStore.discover(
            agent: .codex,
            workingDirectory: "/tmp/project",
            launchedAfter: Date().addingTimeInterval(-1),
            rootURL: root
        )?.rawValue == "019f-codex")
        let knownID = try #require(AgentConversationID("019f-codex"))
        #expect(AgentConversationStore.contains(
            agent: .codex,
            conversationID: knownID,
            rootURL: root
        ))

        let second = root.appendingPathComponent("2026/08/25/second.jsonl")
        let secondRecord: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": "019f-other", "cwd": "/tmp/project"],
        ]
        var secondData = try JSONSerialization.data(withJSONObject: secondRecord)
        secondData.append(0x0A)
        try secondData.write(to: second)
        #expect(AgentConversationStore.discover(
            agent: .codex,
            workingDirectory: "/tmp/project",
            launchedAfter: Date().addingTimeInterval(-1),
            rootURL: root
        ) == nil)
    }

    @Test func appliesManifestScreenStatusRules() {
        let definition = SupportedAgent.crush.definition
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Permission Required: Allow for Session"
        ) == .needsAttention)
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Thinking..."
        ) == .working)
        #expect(AgentScreenStatusDetector.detect(
            definition: definition,
            screen: "Ready"
        ) == .idle)
        #expect(AgentScreenStatusDetector.detect(
            status: SupportedAgent.grok.definition.titleStatus,
            text: "Action Required"
        ) == .needsAttention)
        #expect(AgentScreenStatusDetector.detect(
            status: SupportedAgent.qwen.definition.titleStatus,
            text: "◐ Thinking"
        ) == .working)
    }

    @Test func clearsOnlyTitleDerivedWorkingWhenTitleSettles() {
        let codexStatus = SupportedAgent.codex.definition.titleStatus
        #expect(AgentTitleStatusReconciler.nextState(
            status: codexStatus,
            title: "Codex ⠋ active",
            current: .idle,
            typedHookOwnsContext: false
        ) == .working)
        #expect(AgentTitleStatusReconciler.nextState(
            status: codexStatus,
            title: "Codex",
            current: .working,
            typedHookOwnsContext: false
        ) == .idle)
        #expect(AgentTitleStatusReconciler.nextState(
            status: codexStatus,
            title: "Codex",
            current: .working,
            typedHookOwnsContext: true
        ) == nil)
        #expect(AgentTitleStatusReconciler.nextState(
            status: SupportedAgent.crush.definition.titleStatus,
            title: "Ready",
            current: .working,
            typedHookOwnsContext: false
        ) == nil)
    }

    @Test func titleIdleWatcherClearsStaleWorkingOnlyWhenTitleSettles() throws {
        let claudeStatus = SupportedAgent.claude.definition.titleStatus
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var watcher = AgentTitleIdleWatcher()

        // No title channel at all: the watcher must never claim idle.
        watcher.observe(title: "Ready", status: nil, now: start)
        #expect(!watcher.confirmsIdle(
            now: start.addingTimeInterval(60),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))

        // Claude Code shows a spinner glyph while a turn runs.
        watcher.observe(title: "◐ Claude Code", status: claudeStatus, now: start)
        #expect(watcher.detected == .working)
        #expect(!watcher.confirmsIdle(
            now: start.addingTimeInterval(1),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))

        // The idle glyph must persist before a stale working state is cleared.
        watcher.observe(title: "✳ Claude Code", status: claudeStatus, now: start.addingTimeInterval(1))
        #expect(watcher.detected == .idle)
        #expect(!watcher.confirmsIdle(
            now: start.addingTimeInterval(2),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))
        #expect(watcher.confirmsIdle(
            now: start.addingTimeInterval(4),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))

        // While the animation keeps running, the busy state must hold even
        // though the idle glyph shows up in between.
        var animated = AgentTitleIdleWatcher()
        for step in 0..<20 {
            animated.observe(
                title: step.isMultiple(of: 2) ? "✳ Claude Code" : "◐ Claude Code",
                status: claudeStatus,
                now: start.addingTimeInterval(Double(step) * 0.1)
            )
        }
        #expect(!animated.confirmsIdle(
            now: start.addingTimeInterval(1.9),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))
        // Once the animation stopped, the stalled title confirms idle.
        #expect(animated.confirmsIdle(
            now: start.addingTimeInterval(23),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))

        // An animation that ends on its working frame is still caught, because
        // the title stopped changing.
        var stalled = AgentTitleIdleWatcher()
        stalled.observe(title: "◐ Claude Code", status: claudeStatus, now: start)
        #expect(!stalled.confirmsIdle(
            now: start.addingTimeInterval(19),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))
        #expect(stalled.confirmsIdle(
            now: start.addingTimeInterval(21),
            delay: AgentTitleStatusReconciler.idleConfirmationDelay,
            stallDelay: AgentTitleStatusReconciler.idleStallDelay
        ))
    }

    @Test func detectsLocalAgentForegroundCommandsWithoutFalseArguments() {
        for agent in SupportedAgent.allCases {
            let command = agent.definition.command
            #expect(LocalAgentProcessDetector.detect(
                in: "/Users/test/.local/bin/\(command)\n"
            ) == agent)
        }
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/codex --model gpt-5\n"
        ) == .codex)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/bin/login -flp test claude\n/usr/local/bin/claude\n"
        ) == .claude)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/node /opt/pi-coding-agent/dist/cli.js\n"
        ) == .pi)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/node /opt/claude-code/cli.js\n"
        ) == .claude)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/qodercli\n"
        ) == .qoder)
        #expect(LocalAgentProcessDetector.detect(
            in: "/usr/local/bin/reasonix\n"
        ) == .reasonix)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.local/bin/omp\n"
        ) == .omp)
        #expect(LocalAgentProcessDetector.detect(
            in: "/Users/test/.opencode/bin/opencode\n"
        ) == .opencode)
        #expect(LocalAgentProcessDetector.detect(
            in: "/bin/cat pi\n"
        ) == nil)
    }

    /// Tab icons tint the glyph's alpha channel by activity state, so every agent
    /// must resolve to a template silhouette. Full-colour brand art on an opaque
    /// background would tint into a solid accent block, so an agent that needs one
    /// declares a separate `iconGlyph`; agents whose identity asset is already a
    /// template reuse it for tabs.
    @Test @MainActor func tabGlyphsResolveToTintedTemplates() throws {
        for agent in SupportedAgent.allCases {
            let name = agent.glyphAssetName
            let image = try #require(
                NSImage(named: name),
                "Missing tab glyph \(name) for \(agent.rawValue)"
            )
            #expect(image.isTemplate, "\(name) must be a template to tint by state")
            #expect(renderedPixelCount(image) > 100)

            if let glyph = agent.definition.iconGlyph {
                #expect(glyph == name)
            }
        }
    }

    @Test @MainActor func bundledAgentAssetsRenderVisiblePixels() throws {
        for agent in SupportedAgent.allCases {
            let image = try #require(NSImage(named: agent.assetName))
            #expect(renderedPixelCount(image) > 100)
        }
    }

    @Test func distinguishesQuestionFromPermissionAttention() throws {
        var reducer = AgentContextSignalReducer()
        guard case .set(let question) = reducer.consume(signal(
            agent: .pi,
            state: "needsAttention",
            attention: .question
        )) else {
            Issue.record("Expected question activity")
            return
        }
        #expect(question.attentionKind == .question)
    }

    @Test func normalizesAgentOwnedTerminalTitleDecoration() {
        #expect(SupportedAgent.claude.normalizedTitle("✳ Claude Code") == "Claude Code")
        #expect(SupportedAgent.codex.normalizedTitle("~/code") == "~/code")
        #expect(SupportedAgent.pi.normalizedTitle("π - project") == "project")
        #expect(SupportedAgent.pi.normalizedTitle("project") == "project")
    }

    @Test func staleAgentEndDoesNotClearNewAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "working"))
        _ = reducer.consume(signal(agent: .claude, state: "working"))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-codex",
            metadata: "type=app;omg_agent=codex"
        )) == nil)
        guard case .set(let done) = reducer.consume(signal(
            agent: .claude,
            state: "done"
        )) else {
            Issue.record("Expected Claude to remain active")
            return
        }
        #expect(done.source == "claude")
        #expect(done.state == .done)
    }

    @Test func newlyDetectedAgentSupersedesTerminatedPreviousAgent() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 100,
            liveness: "pgid"
        ))
        guard case .set(let interrupted) = reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-100",
            metadata: "type=app;omg_agent=pi;omg_scope=local"
        )) else {
            Issue.record("Expected terminated Pi activity")
            return
        }
        #expect(interrupted.state == .error)
        #expect(reducer.currentContextID == "omg-agent-pi-100")

        let nextID = "omg-agent-antigravity-200"
        #expect(reducer.currentContextID != nextID)
        guard case .set(let detected) = reducer.consume(signal(
            agent: .antigravity,
            state: "idle",
            instance: 200,
            liveness: "pgid"
        )) else {
            Issue.record("Expected Antigravity to replace terminated Pi")
            return
        }
        #expect(detected.source == "antigravity")
        #expect(detected.state == .idle)
        #expect(reducer.currentContextID == nextID)
    }

    @Test func staleSameAgentEndDoesNotClearNewInstance() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .codex,
            state: "working",
            instance: 100
        ))
        _ = reducer.consume(signal(
            agent: .codex,
            state: "working",
            instance: 200
        ))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-codex-100",
            metadata: "type=app;omg_agent=codex;omg_scope=local"
        )) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(200) == nil)
    }

    @Test func explicitProcessGroupLivenessUsesForegroundIdentity() {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 299,
            liveness: "pgid"
        ))
        #expect(reducer.validationIdentity == .processGroup(299))
        #expect(reducer.reconcileLocalForegroundProcess(299) == nil)
    }

    @Test func livePiPIDSurvivesForegroundProcessGroupChanges() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 300
        ))
        #expect(reducer.validationIdentity == .process(300))
        #expect(reducer.requiresForegroundValidation)
        #expect(reducer.reconcileLocalForegroundProcess(301) == nil)
        #expect(reducer.reconcileLocalForegroundProcess(
            999,
            livenessIsAlive: true,
            now: Date().addingTimeInterval(10)
        ) == nil)
        guard case .set(let error) = reducer.reconcileLocalForegroundProcess(
            999,
            livenessIsAlive: false,
            now: Date().addingTimeInterval(10)
        ) else {
            Issue.record("Expected an interruption error")
            return
        }
        #expect(error.state == .error)
        #expect(error.message == "Agent process exited unexpectedly.")
        #expect(!reducer.requiresForegroundValidation)
        #expect(reducer.acknowledgeTerminalState() == .clear)
    }

    @Test func normalShutdownClearsIdentityWithoutCompletion() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "done",
            instance: 301
        ))
        _ = reducer.consume(signal(
            agent: .pi,
            state: "idle",
            instance: 301
        ))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-301",
            metadata: "type=app;omg_agent=pi;omg_scope=local"
        )) == .clear)
    }

    @Test func unexpectedHookEndReportsErrorUntilAcknowledged() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 302,
            scope: "remote"
        ))
        guard case .set(let error) = reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-302",
            metadata: "type=app;omg_agent=pi;omg_scope=remote"
        )) else {
            Issue.record("Expected remote interruption error")
            return
        }
        #expect(error.state == .error)
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-302",
            metadata: "type=app;omg_agent=pi;omg_scope=remote"
        )) == nil)
        #expect(reducer.acknowledgeTerminalState() == .clear)
    }

    @Test func completedAgentEndClearsIdentity() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .pi,
            state: "done",
            instance: 303
        ))
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-303",
            metadata: "type=app;omg_agent=pi;omg_scope=local"
        )) == .clear)
        #expect(reducer.trackedContextCount == 0)
        #expect(!reducer.requiresForegroundValidation)
        #expect(reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi-303",
            metadata: "type=app;omg_agent=pi;omg_scope=local"
        )) == nil)
        #expect(reducer.acknowledgeTerminalState() == nil)
    }

    @Test func acknowledgingCompletionRestoresIdleIdentity() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "done"))
        guard case .set(let activity) = reducer.acknowledgeTerminalState() else {
            Issue.record("Expected completion acknowledgement")
            return
        }
        #expect(activity.state == .idle)
        #expect(activity.icon == SupportedAgent.codex.icon)
        #expect(activity.progress == nil)
        #expect(reducer.acknowledgeTerminalState() == nil)
    }

    @Test(arguments: ["cwd=%2Ftmp", "cwdhex=2f746d70"])
    func remotePromptClearsOrphanedAgent(directory: String) throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .claude,
            state: "working",
            instance: 400,
            scope: "remote"
        ))
        let update = reducer.consumeRemotePrompt(.init(
            action: .start,
            id: "omg-ssh-remote-test",
            metadata: "type=remote;targethost=cloud;\(directory)"
        ))
        #expect(update == .clear)
        #expect(!reducer.hasRemoteActivity)
    }

    @Test func SSHDisconnectClearsRemoteAgentAndRestoresLocalContext() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(
            agent: .codex,
            state: "idle",
            instance: 399,
            scope: "local"
        ))
        _ = reducer.consume(signal(
            agent: .pi,
            state: "working",
            instance: 400,
            scope: "remote"
        ))
        #expect(reducer.hasRemoteActivity)
        guard case .set(let restored) = reducer.clearRemoteActivities() else {
            Issue.record("Expected local Agent context after SSH disconnect")
            return
        }
        #expect(restored.source == SupportedAgent.codex.rawValue)
        #expect(restored.state == .idle)
        #expect(!reducer.hasRemoteActivity)
    }

    @Test func nestedAgentInterruptionRestoresPreviousAfterAcknowledgement() throws {
        var reducer = AgentContextSignalReducer()
        _ = reducer.consume(signal(agent: .codex, state: "working"))
        _ = reducer.consume(signal(agent: .pi, state: "working"))
        let update = reducer.consume(.init(
            action: .end,
            id: "omg-agent-pi",
            metadata: "type=app;omg_agent=pi"
        ))
        guard case .set(let interrupted) = update else {
            Issue.record("Expected nested interruption error")
            return
        }
        #expect(interrupted.source == "pi")
        #expect(interrupted.state == .error)
        guard case .set(let restored) = reducer.acknowledgeTerminalState() else {
            Issue.record("Expected parent agent activity after acknowledgement")
            return
        }
        #expect(restored.source == "codex")
        #expect(restored.state == .working)
    }

    @Test func backgroundAttentionOutranksFocusedWorkingActivity() throws {
        var reducer = AgentContextSignalReducer()
        guard case .set(let working) = reducer.consume(signal(
            agent: .codex,
            state: "working"
        )), case .set(let attention) = reducer.consume(signal(
            agent: .claude,
            state: "needsAttention"
        )) else {
            Issue.record("Expected normalized activities")
            return
        }
        let preferred = AgentActivitySelection.preferred([
            .init(activity: working, isFocused: true),
            .init(activity: attention, isFocused: false),
        ])
        #expect(preferred == attention)
        guard case .set(let claudeWorking) = reducer.consume(signal(
            agent: .claude,
            state: "working"
        )) else {
            Issue.record("Expected focused activity")
            return
        }
        let focusedTie = AgentActivitySelection.preferred([
            .init(activity: working, isFocused: false),
            .init(activity: claudeWorking, isFocused: true),
        ])
        #expect(focusedTie == claudeWorking)
    }

    @Test func hookInstallerPreservesExistingCodexAndClaudeHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexHooks = home.appendingPathComponent(".codex/hooks.json")
        let claudeSettings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: codexHooks.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "_otty": true,
                        "hooks": [["type": "command", "command": "otty state"]],
                    ],
                    [
                        "matcher": "legacy-shared-entry",
                        "hooks": [
                            [
                                "type": "command",
                                "command": ": _omg_agent_status; old hook",
                            ],
                            ["type": "command", "command": "keep shared hook"],
                        ],
                    ],
                ],
                "Stop": [[
                    "matcher": "other-stop",
                    "hooks": [[
                        "type": "command",
                        "command": "preserve stop command verbatim",
                    ]],
                ]],
                "Notification": [[
                    "matcher": "other-notification",
                    "hooks": [[
                        "type": "command",
                        "command": "preserve notification command verbatim",
                    ]],
                ]],
            ],
            "preserved": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: codexHooks)
        try data.write(to: claudeSettings)
        try "[features]\nhooks=true\nother = true\n".write(
            to: home.appendingPathComponent(".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        try installer.install(.claude)
        #expect(installer.isInstalled(.codex))
        #expect(installer.isInstalled(.claude))
        #expect(FileManager.default.fileExists(
            atPath: codexHooks.appendingPathExtension("omg-backup").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: claudeSettings.appendingPathExtension("omg-backup").path
        ))

        for url in [codexHooks, claudeSettings] {
            let root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            #expect(root["preserved"] as? Bool == true)
            let hooks = try #require(root["hooks"] as? [String: Any])
            let starts = try #require(hooks["SessionStart"] as? [[String: Any]])
            #expect(starts.contains { $0["_otty"] as? Bool == true })
            let sharedEntry = try #require(starts.first {
                $0["matcher"] as? String == "legacy-shared-entry"
            })
            let sharedCommands = try #require(
                sharedEntry["hooks"] as? [[String: Any]]
            )
            #expect(sharedCommands.count == 1)
            #expect(sharedCommands[0]["command"] as? String == "keep shared hook")
            let omgEntry = try #require(starts.first { entry in
                entry[AgentHookInstaller.marker] as? Int ==
                    AgentHookInstaller.hookVersion
            })
            let commands = try #require(omgEntry["hooks"] as? [[String: Any]])
            let command = try #require(commands.first?["command"] as? String)
            #expect(command.contains("omg_state=idle"))
            #expect(command.contains("ps -o tty= -p \"$PPID\""))
            #expect(command.contains("ps -o pgid= -p \"$PPID\""))
            #expect(command.contains("omg-agent-\(url == codexHooks ? "codex" : "claude")-%s"))
            #expect(command.contains("omg_scope=%s"))
            #expect(command.contains("omg_liveness=pgid"))
            #expect(command.contains("omg_conversation=%s"))
            #expect(command.contains("session_id"))
            #expect(command.contains("> \"/dev/$omg_tty\""))
            try assertUnrelatedHooksPreserved(at: url)
        }
        let config = try String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"),
            encoding: .utf8
        )
        #expect(config.contains("hooks = true"))
        #expect(!config.contains("hooks=true"))
        #expect(config.components(separatedBy: "hooks").count == 2)
        #expect(config.contains("other = true"))

        try installer.uninstall(.codex)
        #expect(!installer.isInstalled(.codex))
        let restored = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: codexHooks)) as? [String: Any]
        )
        let restoredHooks = try #require(restored["hooks"] as? [String: Any])
        let restoredStarts = try #require(
            restoredHooks["SessionStart"] as? [[String: Any]]
        )
        #expect(restoredStarts.count == 2)
        #expect(restoredStarts.contains { $0["_otty"] as? Bool == true })
        let preservedShared = try #require(restoredStarts.first {
            $0["matcher"] as? String == "legacy-shared-entry"
        })
        let preservedCommands = try #require(
            preservedShared["hooks"] as? [[String: Any]]
        )
        #expect(preservedCommands.count == 1)
        #expect(preservedCommands[0]["command"] as? String == "keep shared hook")
        try assertUnrelatedHooksPreserved(at: codexHooks)

        try installer.uninstall(.claude)
        #expect(!installer.isInstalled(.claude))
        try assertUnrelatedHooksPreserved(at: claudeSettings)
    }

    @Test func detectorOnlyAgentsHaveInstallUpdateAndRemoveLifecycle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let detectors = SupportedAgent.allCases.filter {
            AgentHookInstaller.supportsDetector(for: $0)
        }
        // Hermes has a vendor shell-hook adapter now, so only Crush is detector-only.
        #expect(Set(detectors) == [.crush])

        for agent in detectors {
            #expect(installer.installationState(agent) == .missing)
            try installer.install(agent)
            #expect(installer.installationState(agent) == .current)

            let url = home
                .appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
                .appendingPathComponent("\(agent.rawValue).json")
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let marker = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            #expect(marker["owner"] as? String == AgentHookInstaller.marker)
            #expect(marker["agent"] as? String == agent.rawValue)
            #expect(marker["version"] as? Int == AgentHookInstaller.detectorMarkerVersion)

            var stale = marker
            stale["version"] = 0
            try JSONSerialization.data(withJSONObject: stale).write(
                to: url,
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            #expect(installer.installationState(agent) == .updateAvailable)

            try installer.install(agent)
            #expect(installer.installationState(agent) == .current)
            try installer.uninstall(agent)
            #expect(installer.installationState(agent) == .missing)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func detectorReconciliationInstallsEveryRunAndRespectsRemoval() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let detectors = SupportedAgent.allCases.filter {
            AgentHookInstaller.supportsDetector(for: $0)
        }

        // A detector-only Agent bundled after any previous release must still be
        // adopted; the old global sentinel short-circuited this.
        try installer.migrateImplicitDetectorsIfNeeded()
        for agent in detectors {
            #expect(installer.installationState(agent) == .current)
        }

        // Reconciliation is idempotent.
        try installer.migrateImplicitDetectorsIfNeeded()
        for agent in detectors {
            #expect(installer.installationState(agent) == .current)
        }

        // An explicit Remove survives later reconciliation.
        let removed = try #require(detectors.first)
        try installer.uninstall(removed)
        #expect(installer.installationState(removed) == .missing)
        #expect(installer.isDetectorRemovedByUser(removed))
        try installer.migrateImplicitDetectorsIfNeeded()
        #expect(installer.installationState(removed) == .missing)

        // An explicit Install clears the removal record.
        try installer.install(removed)
        #expect(installer.installationState(removed) == .current)
        #expect(!installer.isDetectorRemovedByUser(removed))
        try installer.migrateImplicitDetectorsIfNeeded()
        #expect(installer.installationState(removed) == .current)

        // Detector-only reconciliation never touches vendor Hook agents.
        #expect(installer.installationState(.antigravity) == .missing)
    }

    @Test func detectorReconciliationRefreshesStaleMarkers() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let agent = try #require(
            SupportedAgent.allCases.first { AgentHookInstaller.supportsDetector(for: $0) }
        )
        try installer.install(agent)
        let url = home
            .appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
            .appendingPathComponent("\(agent.rawValue).json")
        var stale = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        stale["version"] = 0
        try JSONSerialization.data(withJSONObject: stale).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #expect(installer.installationState(agent) == .updateAvailable)

        try installer.migrateImplicitDetectorsIfNeeded()
        #expect(installer.installationState(agent) == .current)
    }

    @Test func hermesYAMLHookInstallsUpdatesAndRemoves() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let url = home.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Unrelated top-level YAML must survive byte-for-byte.
        try "model: claude-sonnet-4\ntelemetry: false\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )

        #expect(installer.installationState(.hermes) == .missing)
        try installer.install(.hermes)
        #expect(installer.installationState(.hermes) == .current)

        let installed = try String(contentsOf: url, encoding: .utf8)
        #expect(installed.contains("model: claude-sonnet-4"))
        #expect(installed.contains("telemetry: false"))
        #expect(installed.contains("# >>> OMG agent-status hooks"))
        #expect(installed.contains("hooks_auto_accept: true"))
        // Exactly one top-level `hooks:` key must be emitted, never one per event.
        let hooksKeys = installed.split(separator: "\n").filter { $0 == "hooks:" }.count
        #expect(hooksKeys == 1)
        for event in ["on_session_start", "pre_llm_call", "post_llm_call", "on_session_finalize"] {
            #expect(installed.contains("\(event):"))
        }
        // Hermes hooks run from a headless daemon, so each event delegates to the
        // helper script instead of writing OSC from the hook process.
        let hookLine = try #require(
            installed.split(separator: "\n").first { $0.contains("-hook.sh") }
        )
        #expect(hookLine.contains("agent-status/hermes-hook.sh"))
        let script = home.appendingPathComponent(
            ".config/oh-my-ghostty/agent-status/hermes-hook.sh"
        )
        #expect(FileManager.default.fileExists(atPath: script.path))
        let scriptText = try String(contentsOf: script, encoding: .utf8)
        #expect(scriptText.contains("_omg_agent_status"))
        #expect(scriptText.contains("session_id"))
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        // A stale helper script reports an update, and reinstalling is idempotent.
        try scriptText.replacingOccurrences(
            of: "_omg_agent_status v\(AgentHookInstaller.hookVersion)",
            with: "_omg_agent_status v1"
        ).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        #expect(installer.installationState(.hermes) == .updateAvailable)
        try installer.install(.hermes)
        #expect(installer.installationState(.hermes) == .current)
        let reinstalled = try String(contentsOf: url, encoding: .utf8)
        let blocks = reinstalled.components(separatedBy: "# >>> OMG agent-status hooks").count - 1
        #expect(blocks == 1)

        try installer.uninstall(.hermes)
        #expect(installer.installationState(.hermes) == .missing)
        #expect(!FileManager.default.fileExists(atPath: script.path))
        let removed = try String(contentsOf: url, encoding: .utf8)
        #expect(!removed.contains("# >>> OMG agent-status hooks"))
        #expect(removed.contains("model: claude-sonnet-4"))
        #expect(removed.contains("telemetry: false"))
    }

    @Test func hermesYAMLHookRefusesForeignConfig() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let url = home.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A user-owned top-level `hooks:` cannot be merged without rewriting their
        // YAML, so installation must fail closed instead of duplicating the key.
        try "hooks:\n  pre_llm_call:\n    - command: echo hi\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        #expect(throws: AgentHookInstallerError.self) {
            try installer.install(.hermes)
        }
        let untouched = try String(contentsOf: url, encoding: .utf8)
        #expect(untouched.contains("command: echo hi"))
        #expect(!untouched.contains("# >>> OMG agent-status hooks"))
    }

    @Test func detectorReconciliationLeavesUnownedMarkersUntouched() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        let agent = try #require(
            SupportedAgent.allCases.first { AgentHookInstaller.supportsDetector(for: $0) }
        )
        let directory = home
            .appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("\(agent.rawValue).json")
        try #"{"owner":"someone-else","version":1,"agent":"\(agent.rawValue)"}"#.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let before = try Data(contentsOf: url)

        try installer.migrateImplicitDetectorsIfNeeded()
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func detectorRemovalPreservesUnownedOrNonFileContent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.crush)
        let url = home
            .appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
            .appendingPathComponent("crush.json")
        try #"{"owner":"someone-else","version":1,"agent":"crush"}"#.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        #expect(throws: AgentHookInstallerError.self) {
            try installer.uninstall(.crush)
        }
        #expect(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: AgentHookInstallerError.self) {
            try installer.uninstall(.crush)
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    @Test func hookCommandFallsBackToControllingTTY() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf:
                home.appendingPathComponent(".codex/hooks.json")
            )) as? [String: Any]
        )
        let hooks = try #require(root["hooks"] as? [String: Any])
        let starts = try #require(hooks["SessionStart"] as? [[String: Any]])
        let omg = try #require(starts.first {
            $0[AgentHookInstaller.marker] as? Int == AgentHookInstaller.hookVersion
        })
        let commands = try #require(omg["hooks"] as? [[String: Any]])
        let command = try #require(commands.first?["command"] as? String)
        #expect(command.contains(
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) omg_tty=tty;; esac"
        ))
        #expect(command.contains("> \"/dev/$omg_tty\""))
    }

    @Test func installedCodexHookReportsConversationToRuntimeWithoutUsingShellInput() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try AgentHookInstaller(homeURL: home).install(.codex)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".codex/hooks.json"))) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let starts = try #require(hooks["SessionStart"] as? [[String: Any]])
        let owned = try #require(starts.first { $0[AgentHookInstaller.marker] != nil })
        let commands = try #require(owned["hooks"] as? [[String: Any]])
        let command = try #require(commands.first?["command"] as? String)
        let helper = home.appendingPathComponent("runtime helper")
        let capture = home.appendingPathComponent("arguments")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$OMG_TEST_REPORT\"\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = home
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "OMG_RUNTIME_BIN": helper.path, "OMG_TEST_REPORT": capture.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"session_id\":\"test-conversation\"}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let arguments = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.prefix(2) == ["report", "codex"])
        #expect(arguments[3] == "test-conversation")
        #expect(URL(fileURLWithPath: arguments[4]).resolvingSymlinksInPath() == home.resolvingSymlinksInPath())
    }

    @Test func oldOwnerVersionRequiresHookCommandUpgrade() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.codex)
        let url = home.appendingPathComponent(".codex/hooks.json")
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var hooks = try #require(root["hooks"] as? [String: Any])
        for key in hooks.keys {
            var entries = try #require(hooks[key] as? [[String: Any]])
            for index in entries.indices
            where entries[index][AgentHookInstaller.marker] as? Int ==
                AgentHookInstaller.hookVersion {
                entries[index][AgentHookInstaller.marker] = 4
                var commands = try #require(
                    entries[index]["hooks"] as? [[String: Any]]
                )
                for commandIndex in commands.indices {
                    let command = try #require(
                        commands[commandIndex]["command"] as? String
                    )
                    commands[commandIndex]["command"] = command.replacingOccurrences(
                        of: "_omg_agent_status_v5",
                        with: "_omg_agent_status_v4"
                    )
                }
                entries[index]["hooks"] = commands
            }
            hooks[key] = entries
        }
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        #expect(installer.installationState(.codex) == .updateAvailable)
    }

    @Test func refusesMalformedHooksWithoutOverwriting() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let hooksURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = #"{"hooks":{"SessionStart":"do not replace"}}"#
        try original.write(to: hooksURL, atomically: true, encoding: .utf8)

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.claude)
        }
        #expect(try String(contentsOf: hooksURL, encoding: .utf8) == original)
    }

    @Test func validatesCodexHooksBeforeChangingFeatureFlag() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let originalConfig = "[features]\nhooks = false\n"
        try originalConfig.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        try #"{"hooks":{"SessionStart":"invalid"}}"#.write(
            to: hooksURL,
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.codex)
        }
        #expect(try String(contentsOf: configURL, encoding: .utf8) == originalConfig)
    }

    @Test func refusesDuplicateCodexHooksSettingBeforeWritingHooks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let codexDirectory = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        try "[features]\nhooks=true\nhooks = false\n".write(
            to: codexDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: AgentHookInstallerError.self) {
            try AgentHookInstaller(homeURL: home).install(.codex)
        }
        #expect(!FileManager.default.fileExists(
            atPath: codexDirectory.appendingPathComponent("hooks.json").path
        ))
    }

    @Test func exportedRemoteInstallerProducesCurrentHooks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let scriptURL = root.appendingPathComponent("omg-agent-hooks.py")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try AgentHookInstaller.remoteInstallerScript().write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, Comment(rawValue: message))

        let installer = AgentHookInstaller(homeURL: home)
        for agent in SupportedAgent.allCases {
            let expected: AgentHookInstallationState =
                agent.definition.hook.kind == .none ? .missing : .current
            #expect(installer.installationState(agent) == expected)
        }
        for path in [".cursor/hooks.json", ".copilot/hooks/omg.json"] {
            let root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf:
                    home.appendingPathComponent(path)
                )) as? [String: Any]
            )
            #expect(root["version"] as? Int == 1)
        }
        let reasonix = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf:
                home.appendingPathComponent(".reasonix/settings.json")
            )) as? [String: Any]
        )
        let reasonixHooks = try #require(reasonix["hooks"] as? [String: Any])
        let reasonixStart = try #require(
            reasonixHooks["SessionStart"] as? [[String: Any]]
        )
        #expect(reasonixStart.first?["command"] is String)
        #expect(reasonixStart.first?["hooks"] == nil)

        let remotePi = home.appendingPathComponent(
            ".pi/agent/extensions/omg-agent-status.ts"
        )
        let remoteMode = try #require(
            FileManager.default.attributesOfItem(atPath: remotePi.path)[
                .posixPermissions
            ] as? NSNumber
        )
        #expect(remoteMode.intValue == 0o600)
    }

    @Test func installsAuditablePiExtension() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(homeURL: home)
        try installer.install(.pi)
        #expect(installer.isInstalled(.pi))
        let source = try String(
            contentsOf: home.appendingPathComponent(
                ".pi/agent/extensions/omg-agent-status.ts"
            ),
            encoding: .utf8
        )
        #expect(source.contains("marker: \(AgentHookInstaller.marker)"))
        #expect(source.contains("omg-agent-pi-${process.pid}"))
        #expect(source.contains("omg_liveness=pid"))
        #expect(source.contains("process.env.SSH_CONNECTION"))
        #expect(source.contains("sessionManager?.getSessionId"))
        #expect(source.contains("omg_conversation="))
        #expect(source.contains("sessionManager?.getCwd"))
        #expect(source.contains("omg_cwd="))
        #expect(source.contains("agent_settled"))
        #expect(source.contains("if (!context.isIdle()) return"))
        #expect(source.contains("subagent:async-started"))
        #expect(source.contains("subagent:async-complete"))
        #expect(source.contains("pi-background-tasks:terminal:v1"))
        #expect(source.contains("omg_phase=${phase}"))
        #expect(source.contains("Session shutdown is lifecycle cleanup, not task completion"))
        #expect(source.contains("report(\"idle\", false, context);\n    report(undefined, true, context);"))
        #expect(source.contains("ask_user_question"))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(
                ".pi/agent/extensions/omg-agent-status.ts"
            ).path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
        try installer.uninstall(.pi)
        #expect(!installer.isInstalled(.pi))
    }

    @MainActor
    private func renderedPixelCount(_ image: NSImage) -> Int {
        let size = 32
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return 0
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.draw(in: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<size {
            for x in 0..<size where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                count += 1
            }
        }
        return count
    }

    private func assertUnrelatedHooksPreserved(at url: URL) throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let hooks = try #require(root["hooks"] as? [String: Any])
        for (event, matcher, command) in [
            ("Stop", "other-stop", "preserve stop command verbatim"),
            (
                "Notification",
                "other-notification",
                "preserve notification command verbatim"
            ),
        ] {
            let entries = try #require(hooks[event] as? [[String: Any]])
            let entry = try #require(entries.first {
                $0["matcher"] as? String == matcher
            })
            let commands = try #require(entry["hooks"] as? [[String: Any]])
            #expect(commands.count == 1)
            #expect(commands[0]["command"] as? String == command)
        }
    }

    private func signal(
        agent: SupportedAgent,
        state: String,
        instance: Int? = nil,
        scope: String? = nil,
        liveness: String? = nil,
        attention: TabAttentionKind? = nil
    ) -> Ghostty.ContextSignal {
        let id = "omg-agent-\(agent.rawValue)" + (instance.map { "-\($0)" } ?? "")
        var metadata = "type=app;omg_agent=\(agent.rawValue);omg_state=\(state)"
        if let scope = scope ?? (instance == nil ? nil : "local") {
            metadata += ";omg_scope=\(scope)"
        }
        if let liveness { metadata += ";omg_liveness=\(liveness)" }
        if let attention { metadata += ";omg_attention=\(attention.rawValue)" }
        return .init(action: .start, id: id, metadata: metadata)
    }
}
