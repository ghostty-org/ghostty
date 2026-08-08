import Foundation
@testable import Ghostty
import Testing

/// Where a file opens, and the rule that keeps reuse safe.
@Suite(.serialized)
struct FileOpenTargetTests {
    private func withTarget(_ raw: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: FileOpenTarget.defaultsKey)
        defer { defaults.set(saved, forKey: FileOpenTarget.defaultsKey) }
        defaults.set(raw, forKey: FileOpenTarget.defaultsKey)
        body()
    }

    /// A new terminal can never go wrong; reuse is a claim about the user's
    /// habits that shouldn't be made for them.
    @Test func aFreshInstallAlwaysOpensANewTerminal() {
        withTarget(nil) {
            #expect(FileOpenTarget.current == .alwaysNewTerminal)
        }
    }

    @Test func theSettingRoundTrips() {
        withTarget(FileOpenTarget.reuseIdleTerminal.rawValue) {
            #expect(FileOpenTarget.current == .reuseIdleTerminal)
        }
    }

    /// A value written by a future version, or corrupted by hand, must not
    /// silently turn into reuse — the riskier of the two.
    @Test func anUnknownValueFallsBackToTheSafeOption() {
        withTarget("someday-in-a-preview-pane") {
            #expect(FileOpenTarget.current == .alwaysNewTerminal)
        }
    }

    @Test func everyTargetIsOfferedInSettings() {
        #expect(FileOpenTarget.allCases.count == 2)
        #expect(FileOpenTarget.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

/// The idle test is what makes reuse safe: a terminal is only free to take
/// a command when its foreground process is the shell itself. Anything
/// else owns the keyboard — including the editor opened for the *previous*
/// file, which is how "make sure the last one was closed" is answered
/// without having to ask.
struct TerminalIdleCheckTests {
    @Test func theCommonShellsCountAsIdle() {
        for shell in ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh"] {
            #expect(TerminalIdleCheck.isShell(shell), "\(shell) should read as idle")
        }
    }

    /// The exact processes that made reuse unsafe in the first place.
    @Test func anEditorOrServerDoesNotCountAsIdle() {
        for busy in ["vim", "nvim", "nano", "hx", "node", "claude", "git", "npm", "less"] {
            #expect(!TerminalIdleCheck.isShell(busy), "\(busy) should not read as idle")
        }
    }

    /// No foreground process means the state is unknown, and unknown has to
    /// resolve to "not idle" — being wrong that way costs one extra
    /// terminal, being wrong the other way loses a command inside an editor.
    @Test func anUnknownForegroundProcessIsNotIdle() {
        #expect(!TerminalIdleCheck.isIdle(foregroundPID: nil))
    }

    /// PID 0 is never a real foreground process group.
    @Test func anImpossiblePIDIsNotIdle() {
        #expect(!TerminalIdleCheck.isIdle(foregroundPID: 0))
    }

    /// The test runner is not a shell, which makes this a live check that
    /// the name lookup actually reaches a process rather than always
    /// failing open.
    @Test func aRealProcessIsInspected() {
        #expect(!TerminalIdleCheck.isIdle(foregroundPID: Int(ProcessInfo.processInfo.processIdentifier)))
    }
}
