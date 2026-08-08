import AppKit

/// Starting a Claude Code session inside a terminal surface — both for a
/// tab opened from the sidebar and for one resuming after a restore.
enum ClaudeSession {
    /// How long to give the shell before typing into it. Text sent before
    /// the prompt is ready is swallowed.
    private static let shellStartupDelay: TimeInterval = 2.0

    /// The exact bytes sent to the surface: a carriage return, not a line
    /// feed, which is the byte Enter actually sends. A line feed is not:
    /// line editors that treat injected text as a paste insert it
    /// literally, leaving the command sitting at the prompt unexecuted.
    ///
    /// Pulled out of `run` so this one detail — the whole reason a prior
    /// version of this sat unexecuted — is covered by a test rather than
    /// only a comment.
    static func commandLine(for command: String) -> String {
        "\(command)\r"
    }

    /// Types `command` into the surface and submits it once the shell is up.
    @MainActor
    static func run(_ command: String, in surface: Ghostty.SurfaceView) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + shellStartupDelay
        ) { [weak surface] in
            surface?.surfaceModel?.sendText(Self.commandLine(for: command))
        }
    }
}
