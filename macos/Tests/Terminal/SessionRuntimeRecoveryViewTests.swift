import AppKit
import Testing
@testable import Ghostty

@MainActor
struct SessionRuntimeRecoveryViewTests {
    @Test func updatingRecoveryTargetsOnlyTheLatestActionWithoutTakingTerminalReturn() {
        let view = SessionRuntimeRecoveryView()
        let strings = SettingsStrings(language: .english)
        var actions: [String] = []
        view.update(endpoint: "first", state: .attention(attempt: 3, message: "offline"),
                    strings: strings) { actions.append("first") }
        view.update(endpoint: "second", state: .attention(attempt: 4, message: "offline"),
                    strings: strings) { actions.append("second") }
        view.reconnectButton.performClick(nil)
        #expect(actions == ["second"])
        #expect(view.titleLabel.stringValue.contains("second"))
        #expect(view.reconnectButton.keyEquivalent.isEmpty)
        #expect(view.detailLabel.stringValue.contains("offline"))
        #expect(view.reconnectButton.title == strings.runtimeRetryNow)
        #expect(view.reconnectButton.isHidden == false)
    }

    @Test func narrowPanesWrapTheExplanationAndKeepTheActionBelowIt() {
        let view = SessionRuntimeRecoveryView()
        view.update(endpoint: "cloud", state: .attention(attempt: 2, message: String(repeating: "network unavailable ", count: 12)),
                    strings: SettingsStrings(language: .english)) {}
        let wideHeight = view.height(for: 900)
        let narrowHeight = view.height(for: 240)
        #expect(narrowHeight > wideHeight)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: narrowHeight)
        view.layoutSubtreeIfNeeded()
        #expect(view.detailLabel.frame.maxY < view.reconnectButton.frame.minY)
        #expect(view.reconnectButton.frame.maxY < view.bounds.maxY)
        #expect(view.reconnectButton.frame.maxX <= view.bounds.maxX)
    }

    @Test func runtimeRetryCopyIsLocalizedAndDescribesReattachingTheSameSession() {
        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        #expect(english.runtimeRetryHelp != chinese.runtimeRetryHelp)
        #expect(english.runtimeRetryNow != chinese.runtimeRetryNow)
        #expect(english.runtimeRetryHelp.contains("existing session"))
        #expect(chinese.runtimeRetryHelp.contains("原会话"))
        let view = SessionRuntimeRecoveryView()
        view.update(endpoint: "host", state: .reconnecting(attempt: 2, retryInMilliseconds: 1_000),
                    strings: english) {}
        #expect(view.titleLabel.stringValue.contains("Reconnecting"))
        #expect(view.detailLabel.stringValue.contains("1s"))
    }

    @Test func exitedSessionShowsExitCodeWithoutOfferingReconnect() {
        let view = SessionRuntimeRecoveryView()
        view.update(endpoint: "host", state: .exited(exitCode: 17),
                    strings: SettingsStrings(language: .english)) {}
        #expect(view.titleLabel.stringValue.contains("Session ended"))
        #expect(view.detailLabel.stringValue.contains("17"))
        #expect(view.reconnectButton.isHidden)
    }
}
