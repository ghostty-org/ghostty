import AppKit
import Testing
@testable import Ghostty

@MainActor
struct SessionRuntimeRecoveryViewTests {
    @Test func updatingRecoveryTargetsOnlyTheLatestActionWithoutTakingTerminalReturn() {
        let view = SessionRuntimeRecoveryView()
        let strings = SettingsStrings(language: .english)
        var actions: [String] = []
        view.update(endpoint: "first", strings: strings) { actions.append("first") }
        view.update(endpoint: "second", strings: strings) { actions.append("second") }
        view.reconnectButton.performClick(nil)
        #expect(actions == ["second"])
        #expect(view.titleLabel.stringValue.contains("second"))
        #expect(view.reconnectButton.keyEquivalent.isEmpty)
        #expect(view.detailLabel.stringValue == strings.runtimeRecoveryHelp)
        #expect(view.detailLabel.stringValue != strings.sshRecoveryReconnectHereHelp)
    }

    @Test func narrowPanesWrapTheExplanationAndKeepTheActionBelowIt() {
        let view = SessionRuntimeRecoveryView()
        view.update(endpoint: "cloud", strings: SettingsStrings(language: .english)) {}
        let wideHeight = view.height(for: 900)
        let narrowHeight = view.height(for: 240)
        #expect(narrowHeight > wideHeight)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: narrowHeight)
        view.layoutSubtreeIfNeeded()
        #expect(view.detailLabel.frame.maxY < view.reconnectButton.frame.minY)
        #expect(view.reconnectButton.frame.maxY < view.bounds.maxY)
        #expect(view.reconnectButton.frame.maxX <= view.bounds.maxX)
    }

    @Test func runtimeRecoveryCopyIsLocalizedAndDistinctFromReplacingTheSession() {
        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        #expect(english.runtimeRecoveryHelp != chinese.runtimeRecoveryHelp)
        #expect(english.runtimeRecoveryReconnect != chinese.runtimeRecoveryReconnect)
        #expect(english.runtimeRecoveryHelp != english.sshRecoveryReconnectHereHelp)
        #expect(chinese.runtimeRecoveryHelp != chinese.sshRecoveryReconnectHereHelp)
    }
}
