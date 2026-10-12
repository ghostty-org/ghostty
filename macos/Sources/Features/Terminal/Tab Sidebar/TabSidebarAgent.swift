import AppKit
import Darwin

/// A well-known coding agent that can run in a tab. The tab sidebar shows the agent's
/// icon when it is the foreground process of the focused surface of a tab.
enum TabSidebarAgent: String, CaseIterable {
    case claude
    case codex
    case gemini
    case copilot

    /// Executable names of the agent, lowercased and without extension.
    var executableNames: Set<String> {
        switch self {
        case .claude: return ["claude", "claude-code"]
        case .codex: return ["codex"]
        case .gemini: return ["gemini"]
        case .copilot: return ["copilot"]
        }
    }

    /// Substrings of the executable path or arguments that identify the agent. This
    /// matches agents launched through an interpreter (e.g. `node .../cli.js`) and
    /// installs whose executable isn't named after the agent.
    var pathMarkers: [String] {
        switch self {
        case .claude: return ["@anthropic-ai/claude-code", "/claude/versions/"]
        case .codex: return ["@openai/codex"]
        case .gemini: return ["@google/gemini-cli"]
        case .copilot: return ["@github/copilot"]
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "GitHub Copilot CLI"
        }
    }

    /// The template image of the agent in the asset catalog.
    var imageName: String {
        switch self {
        case .claude: return "AgentClaude"
        case .codex: return "AgentOpenAI"
        case .gemini: return "AgentGemini"
        case .copilot: return "AgentCopilot"
        }
    }

    /// The brand color of the icon, or nil to use the label color.
    var tintColor: NSColor? {
        switch self {
        case .claude: return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .gemini: return NSColor(srgbRed: 0x8E / 255, green: 0x75 / 255, blue: 0xB2 / 255, alpha: 1)
        case .codex, .copilot: return nil
        }
    }

    /// Returns the agent running as the given process, if any.
    static func detect(pid: Int) -> TabSidebarAgent? {
        guard let pid = pid_t(exactly: pid), pid > 0 else { return nil }
        let info = TabSidebarProcessInfo(pid: pid)
        return detect(path: info.path, arguments: info.arguments)
    }

    /// Returns the agent identified by the executable path and arguments of a process.
    static func detect(path: String?, arguments: [String]) -> TabSidebarAgent? {
        var values: [String] = []
        if let path { values.append(path) }
        values.append(contentsOf: arguments.prefix(1))

        // Interpreters and launchers run the agent as one of their first arguments
        // (`node /usr/local/bin/codex`, `npx @openai/codex`). We only look at those
        // for interpreters so that e.g. `cat claude` isn't detected as an agent.
        let launchers = values.map(executableName)
        if launchers.contains(where: isInterpreter) {
            values.append(contentsOf: arguments.dropFirst().filter { !$0.hasPrefix("-") }.prefix(2))
        }

        let candidates = Set(values.map(executableName))
        if let agent = allCases.first(where: { !$0.executableNames.isDisjoint(with: candidates) }) {
            return agent
        }

        let haystack = values.joined(separator: "\n")
        return allCases.first { agent in
            agent.pathMarkers.contains { haystack.contains($0) }
        }
    }

    private static let interpreters: Set<String> = [
        "node", "bun", "deno", "npx", "bunx", "pnpm", "pnpx", "npm", "yarn", "uv", "uvx", "gh",
    ]

    private static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python")
    }

    /// The lowercased last path component of an executable path or name, without
    /// a script extension.
    private static func executableName(_ value: String) -> String {
        var name = (value as NSString).lastPathComponent.lowercased()
        for ext in [".js", ".mjs", ".cjs", ".ts", ".exe"] where name.hasSuffix(ext) {
            name.removeLast(ext.count)
        }
        return name
    }
}

/// The executable path and arguments of a process.
private struct TabSidebarProcessInfo {
    private(set) var path: String?
    private(set) var arguments: [String] = []

    /// Reads the process with `KERN_PROCARGS2`. The buffer holds argc, the executable
    /// path, NUL padding and then the NUL-separated arguments (and environment).
    init(pid: pid_t) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return }

        func nextString(from index: inout Int) -> String {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        let path = nextString(from: &index)
        self.path = path.isEmpty ? nil : path
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < size, arguments.count < argc {
            arguments.append(nextString(from: &index))
        }
        self.arguments = arguments
    }
}
