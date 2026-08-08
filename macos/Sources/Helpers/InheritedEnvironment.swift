import Foundation

enum InheritedEnvironment {
    /// Per-session markers a coding agent exports into its subprocesses.
    ///
    /// They describe the session that launched the terminal, not anything
    /// running inside it: Claude Code reads an inherited `CHILD_SESSION`
    /// marker and turns transcript saving off. Anything the user genuinely
    /// wants set is re-exported by their shell rc, so dropping these only
    /// removes leakage.
    private static let agentSessionMarkers = [
        "CLAUDECODE",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_EFFORT",
        "CLAUDE_PID",
    ]

    /// Drops the markers so terminals don't inherit them.
    ///
    /// Must run before `ghostty_init`: the core snapshots the environment
    /// there, and that snapshot — not the live one at spawn time — is what
    /// every shell is started with.
    static func scrubAgentSessionMarkers() {
        for name in agentSessionMarkers {
            unsetenv(name)
        }
    }
}
