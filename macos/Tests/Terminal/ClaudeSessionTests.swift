@testable import Ghostty
import Testing

struct ClaudeSessionTests {
    /// The regression: a command submitted with a line feed sat unexecuted
    /// at the prompt, because a line editor that treats injected text as a
    /// paste inserts a `\n` literally instead of submitting. Enter sends a
    /// carriage return.
    @Test func commandLineEndsInCarriageReturnNotLineFeed() {
        let line = ClaudeSession.commandLine(for: "claude --continue")
        #expect(line == "claude --continue\r")
        #expect(!line.contains("\n"))
    }

    @Test func commandLinePreservesTheCommandVerbatim() {
        #expect(ClaudeSession.commandLine(for: "claude").hasPrefix("claude"))
    }
}
