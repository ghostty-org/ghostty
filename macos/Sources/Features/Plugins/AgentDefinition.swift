import AppKit
import Foundation

enum SupportedAgent: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude
    case pi
    case qoder
    case reasonix
    case omp
    case opencode
    case amp
    case antigravity
    case cline
    case copilot
    case crush
    case cursor
    case droid
    case grok
    case hermes
    case kimi
    case qwen

    var id: String { rawValue }
    var definition: AgentDefinition { AgentCatalog.shared.definition(for: self) }
    var displayName: String { definition.displayName }
    var assetName: String { definition.iconAsset }
    /// Tab-only monochrome silhouette. Falls back to `assetName` when the
    /// manifest declares no glyph, so every agent renders one uniform shape.
    var glyphAssetName: String { definition.iconGlyph ?? definition.iconAsset }
    var icon: PluginTabIcon { .init(kind: .bundledAsset, name: glyphAssetName) }

    func normalizedTitle(_ title: String) -> String {
        switch self {
        case .codex, .qoder, .reasonix, .opencode, .amp, .antigravity,
             .cline, .copilot, .crush, .cursor, .droid, .grok, .hermes,
             .kimi, .qwen:
            return title
        case .claude:
            guard title.contains("Claude Code") else { return title }
            let trimmed = title.drop(while: { character in
                character.isWhitespace || character == "✳" || character == "✻" ||
                    character == "✶" || character == "*"
            })
            return trimmed.isEmpty ? displayName : String(trimmed)
        case .pi, .omp:
            let prefixes = ["π - ", "Pi - ", "pi - ", "OMP - ", "omp - "]
            guard let prefix = prefixes.first(where: { title.hasPrefix($0) }) else {
                return title
            }
            let normalized = title.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            return normalized.isEmpty ? displayName : normalized
        }
    }
}

struct AgentConversationID: Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value) ||
                      (65...90).contains(value) ||
                      (97...122).contains(value) ||
                      scalar == "." || scalar == "_" || scalar == "-"
              }) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let validated = Self(value) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid agent conversation ID"
            ))
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentExecutionScope: String, Codable, Sendable {
    case local
    case remote
}

struct AgentResumeDescriptor: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let agent: SupportedAgent
    var conversationID: AgentConversationID?
    let scope: AgentExecutionScope
    var workingDirectory: String?
    var sshReplay: SSHReplayDescriptor?
    /// History-provided fallback, independent of a user's explicit tab name.
    var restoredTitle: String?

    init(
        agent: SupportedAgent,
        conversationID: AgentConversationID? = nil,
        scope: AgentExecutionScope,
        workingDirectory: String?,
        sshReplay: SSHReplayDescriptor? = nil,
        restoredTitle: String? = nil
    ) {
        self.version = Self.currentVersion
        self.agent = agent
        self.conversationID = conversationID
        self.scope = scope
        self.workingDirectory = workingDirectory
        self.sshReplay = sshReplay
        self.restoredTitle = restoredTitle
    }

    var isValid: Bool {
        version == Self.currentVersion &&
            (workingDirectory.map { !$0.contains("\0") && $0.utf8.count <= 4_096 } ?? true) &&
            (restoredTitle.map { !$0.contains("\0") && $0.utf8.count <= 4_096 } ?? true)
    }

    func restorationCommand(
        executablePath: String,
        verifyLocalStore: Bool = true
    ) -> String? {
        guard isValid else { return nil }
        switch scope {
        case .local:
            return localCommand(verifyStore: verifyLocalStore)
        case .remote:
            guard let sshReplay else { return nil }
            let resumableConversation = agent.definition.resume.resumeArguments.isEmpty
                ? nil
                : conversationID
            // When the conversation ID is gone (agent exited back to a remote
            // shell), reconnect SSH without restarting the agent so the pane
            // restores to the remote shell instead of a local one.
            return sshReplay.command(
                executablePath: executablePath,
                remoteWorkingDirectory: workingDirectory,
                remoteAgent: resumableConversation != nil ? agent : nil,
                conversationID: resumableConversation
            )
        }
    }

    private func localCommand(verifyStore: Bool) -> String? {
        guard scope == .local else { return nil }
        let definition = agent.definition
        var argv = [definition.command]
        let hasStoreProbe = definition.resume.store != nil ||
            definition.resume.discover != nil ||
            definition.resume.commandDiscovery != nil
        if let conversationID,
           !verifyStore || !hasStoreProbe || definition.resume.discover != nil ||
           definition.resume.commandDiscovery != nil ||
           AgentConversationStore.contains(
               agent: agent,
               conversationID: conversationID
           ) {
            argv.append(contentsOf: definition.resume.resumeArguments.map {
                $0.replacingOccurrences(of: "{id}", with: conversationID.rawValue)
            })
        }
        guard argv.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
            return nil
        }
        let invocation = argv.map(Self.shellQuote).joined(separator: " ")
        // Ghostty executes surface commands through /bin/sh, whose PATH does
        // not include shell-managed tools (Homebrew, mise, npm, etc.). Run the
        // allowlisted Agent invocation inside the user's login+interactive
        // shell so its normal PATH is available. When the Agent exits, the
        // outer /bin/sh replaces itself with a login shell so the pane remains
        // usable instead of showing a child-exited message.
        let shell = "\"${SHELL:-/bin/zsh}\""
        return "\(shell) -l -i -c \(Self.shellQuote(invocation)); " +
            "exec \(shell) -l"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AgentDefinition: Codable, Equatable, Sendable {
    struct ProcessSpec: Codable, Equatable, Sendable {
        let executables: [String]
        let runtimeMarkers: [String]
    }

    struct ResumeSpec: Codable, Equatable, Sendable {
        struct Store: Codable, Equatable, Sendable {
            let root: String
            let entryPattern: String
        }

        struct CommandDiscovery: Codable, Equatable, Sendable {
            let executable: String
            let arguments: [String]
            let listKey: String
            let idKey: String
            let createdAtKey: String
        }

        struct Discovery: Codable, Equatable, Sendable {
            enum Format: String, Codable, Sendable {
                case json
                case jsonl
            }

            let root: String
            /// Extra stores holding the same record format, such as Codex's
            /// compressed `archived_sessions` directory.
            let additionalRoots: [String]?
            let format: Format
            let idKeyPath: String
            let cwdKeyPath: String
        }

        let createArguments: [String]?
        let resumeArguments: [String]
        let store: Store?
        let discover: Discovery?
        let commandDiscovery: CommandDiscovery?
        let seed: String?
    }

    struct HookSpec: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case none
            case json
            case plugin
            case toml
            case scripts
            /// Marker-delimited YAML block holding shell commands, used by Agents
            /// whose lifecycle hooks live in a YAML config but offer no programmatic
            /// API (Hermes `hooks:`).
            case yaml
        }

        enum Dialect: String, CaseIterable, Codable, Sendable {
            case amp
            case antigravity
            case cline
            case copilot
            case cursor
            case flat
            case kimi
            case nested
            case opencode
            case pi
        }

        struct Event: Codable, Equatable, Sendable {
            let name: String
            let state: TabActivityState?
            let matcher: String?
        }

        let kind: Kind
        let dialect: Dialect?
        let path: String
        let conversationField: String?
        let transcriptField: String?
        let toolField: String?
        let promptTitleField: String?
        let events: [Event]
    }

    struct StatusSpec: Codable, Equatable, Sendable {
        let working: [String]?
        let attention: [String]?
    }

    let id: String
    let displayName: String
    let command: String
    /// The agent's identity mark, rendered by Settings and the Inspector. Must be a
    /// monochrome template so those surfaces follow the system foreground colour.
    let iconAsset: String
    /// Optional additional silhouette for tab presentation, where the host tints
    /// the alpha channel by activity state. Raster brand art with an opaque
    /// background tints into a solid block, so an agent that needs a different tab
    /// shape declares a transparent glyph here; otherwise tabs reuse `iconAsset`.
    let iconGlyph: String?
    let opticalScale: Double?
    let process: ProcessSpec
    let resume: ResumeSpec
    let hook: HookSpec
    let status: StatusSpec?
    let titleStatus: StatusSpec?

    var iconScale: CGFloat {
        CGFloat(min(max(opticalScale ?? 0.86, 0.7), 1.1))
    }

    var expandedHookURL: URL {
        URL(fileURLWithPath: (hook.path as NSString).expandingTildeInPath)
    }

    static func fallback(_ agent: SupportedAgent) -> AgentDefinition {
        AgentDefinition(
            id: agent.rawValue,
            displayName: agent.rawValue.capitalized,
            command: agent.rawValue,
            iconAsset: "AgentOpenAI",
            iconGlyph: nil,
            opticalScale: 0.86,
            process: .init(executables: [agent.rawValue], runtimeMarkers: []),
            resume: .init(
                createArguments: nil,
                resumeArguments: [],
                store: nil,
                discover: nil,
                commandDiscovery: nil,
                seed: nil
            ),
            hook: .init(
                kind: .none,
                dialect: nil,
                path: "",
                conversationField: nil,
                transcriptField: nil,
                toolField: nil,
                promptTitleField: nil,
                events: []
            ),
            status: nil,
            titleStatus: nil
        )
    }
}

enum AgentTitleStatusReconciler {
    /// Claude Code animates its title between the idle and the working glyph
    /// while a turn runs, so the idle form must persist before a stale
    /// "working" state may be cleared.
    static let idleConfirmationDelay: TimeInterval = 2
    /// A working Agent keeps its title moving; a title that stopped changing
    /// is the stronger signal that the turn already ended. The window is
    /// generous so a long tool call cannot clear a real working state.
    static let idleStallDelay: TimeInterval = 20

    static func nextState(
        status: AgentDefinition.StatusSpec?,
        title: String,
        current: TabActivityState?,
        typedHookOwnsContext: Bool
    ) -> TabActivityState? {
        guard !typedHookOwnsContext, status != nil else { return nil }
        let detected = AgentScreenStatusDetector.detect(status: status, text: title)
        if let detected, detected != .idle { return detected }
        return current == .working ? .idle : nil
    }
}

/// Tracks the terminal title of an Agent surface. Hooks stay authoritative for
/// starting work, but a hook that never delivered its terminal event would
/// otherwise pin the tab to "working" forever, so a sustained idle title may
/// clear it.
struct AgentTitleIdleWatcher: Equatable, Sendable {
    private(set) var detected: TabActivityState?
    private(set) var idleSince: Date?
    private(set) var lastTitle: String?
    private(set) var lastChangedAt: Date?

    mutating func observe(
        title: String,
        status: AgentDefinition.StatusSpec?,
        now: Date
    ) {
        let detected = AgentScreenStatusDetector.detect(status: status, text: title)
        if title != lastTitle {
            lastTitle = title
            lastChangedAt = now
        }
        if detected == .idle {
            // Only a continuous idle title counts; any working glyph restarts
            // the window.
            if self.detected != .idle { idleSince = now }
        } else {
            idleSince = nil
        }
        self.detected = detected
    }

    /// True once the title shows the Agent is no longer busy. The idle glyph
    /// is enough on its own, but an animation that ends on its working frame
    /// is only caught by the title having stopped changing.
    func confirmsIdle(now: Date, delay: TimeInterval, stallDelay: TimeInterval) -> Bool {
        // Without a title status there is no title channel to trust.
        guard detected != nil else { return false }
        if detected == .idle, let idleSince, now.timeIntervalSince(idleSince) >= delay {
            return true
        }
        if let lastChangedAt, now.timeIntervalSince(lastChangedAt) >= stallDelay {
            return true
        }
        return false
    }

    mutating func reset() {
        detected = nil
        idleSince = nil
        lastTitle = nil
        lastChangedAt = nil
    }
}

enum AgentScreenStatusDetector {
    static func detect(
        definition: AgentDefinition,
        screen: String
    ) -> TabActivityState? {
        detect(status: definition.status, text: screen)
    }

    static func detect(
        status: AgentDefinition.StatusSpec?,
        text: String
    ) -> TabActivityState? {
        guard let status else { return nil }
        if status.attention?.contains(where: {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) == true { return .needsAttention }
        if status.working?.contains(where: {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) == true { return .working }
        return .idle
    }
}

final class AgentCatalog: @unchecked Sendable {
    static let shared = AgentCatalog()

    private let definitions: [SupportedAgent: AgentDefinition]

    init(bundle: Bundle = .main) {
        let assetNames: [SupportedAgent: String] = [
            .codex: "AgentCodexManifest",
            .claude: "AgentClaudeManifest",
            .pi: "AgentPiManifest",
            .qoder: "AgentQoderManifest",
            .reasonix: "AgentReasonixManifest",
            .omp: "AgentOMPManifest",
            .opencode: "AgentOpenCodeManifest",
            .amp: "AgentAmpManifest",
            .antigravity: "AgentAntigravityManifest",
            .cline: "AgentClineManifest",
            .copilot: "AgentCopilotManifest",
            .crush: "AgentCrushManifest",
            .cursor: "AgentCursorManifest",
            .droid: "AgentDroidManifest",
            .grok: "AgentGrokManifest",
            .hermes: "AgentHermesManifest",
            .kimi: "AgentKimiManifest",
            .qwen: "AgentQwenManifest",
        ]
        definitions = Dictionary(uniqueKeysWithValues: SupportedAgent.allCases.map { agent in
            guard let assetName = assetNames[agent],
                  let data = NSDataAsset(name: assetName, bundle: bundle)?.data,
                  let definition = try? JSONDecoder().decode(AgentDefinition.self, from: data),
                  definition.id == agent.rawValue else {
                return (agent, .fallback(agent))
            }
            return (agent, definition)
        })
    }

    func definition(for agent: SupportedAgent) -> AgentDefinition {
        definitions[agent] ?? .fallback(agent)
    }
}
