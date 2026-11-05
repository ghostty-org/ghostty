import SwiftUI

struct QuickInputSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }

    var body: some View {
        OMGSettingsRow(strings.quickInputHeightLabel, subtitle: strings.quickInputHeightCaption) {
            HStack {
                Slider(value: $settings.quickInputHeight,
                       in: Double(AgentQuickInputMetrics.minimumHeight)...Double(AgentQuickInputMetrics.maximumHeight), step: 1)
                Text("\(Int(settings.quickInputHeight)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }.frame(width: 200)
        }
        OMGSettingsRow(strings.quickInputControlJNewlineLabel) {
            Toggle("", isOn: $settings.quickInputControlJNewline).labelsHidden()
        }
        OMGSettingsRow(strings.quickInputImportLabel, subtitle: strings.quickInputImportCaption) {
            Toggle("", isOn: Binding(
                get: { !settings.quickInputImportShortcut.isEmpty },
                set: { settings.quickInputImportShortcut = $0 ? "auto" : "" }
            )).labelsHidden()
        }
        if !settings.quickInputImportShortcut.isEmpty,
           settings.quickInputImportShortcut != "auto",
           QuickInputDraftBridge.keys(settings.quickInputImportShortcut) == nil {
            Text(strings.quickInputImportInvalid).font(.caption).foregroundStyle(.orange)
        }
        Divider()
        Text(strings.quickInputHistoryTitle).font(.headline)
        QuickInputHistorySettingsView(settings: settings)
    }
}

struct QuickInputShortcutSettingsView: View {
    @ObservedObject var settings: OhMyGhosttySettings
    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }

    var body: some View {
        OMGSettingsRow(strings.quickInputShortcutLabel, subtitle: strings.quickInputShortcutCaption) {
            HStack(spacing: 8) {
                OMGShortcutRecorder(storageValue: $settings.quickInputShortcut).frame(width: 112, height: 24)
                Button(strings.resetShortcutButton) { settings.quickInputShortcut = OMGKeyboardShortcut.defaultQuickInput.storageValue }
            }
        }
        if let shortcut = OMGKeyboardShortcut(storageValue: settings.quickInputShortcut),
           let conflict = shortcut.conflictingMenuItemTitle() {
            Label(strings.shortcutConflictCaption(conflict), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
