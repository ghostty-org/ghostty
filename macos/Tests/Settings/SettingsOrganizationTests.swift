import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

@MainActor
struct SettingsOrganizationTests {
    @Test func everyDescriptorHasOneSearchDestinationAndNavigationRemainsReachable() {
        let navigation = OhMyGhosttySettingsTab.navigationOrder
        #expect(Set(navigation) == Set(OhMyGhosttySettingsTab.allCases))
        #expect(navigation.count == Set(navigation).count)
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let entries = SettingsSearchCatalog.entries(strings: .init(language: language))
            #expect(entries.count == Set(entries.map(\.id)).count)
            let ids = entries.flatMap(\.settingIDs)
            #expect(Set(ids) == Set(OhMyGhosttySettings.descriptors.map(\.id)))
            #expect(ids.count == Set(ids).count)
            for descriptor in OhMyGhosttySettings.descriptors {
                #expect(entries.contains { $0.matches(descriptor.id) })
            }
            #expect(entries.first { $0.settingIDs.contains("agents.historyLimit") }?.tab == .agents)
            #expect(entries.first { $0.settingIDs.contains("sessions.startupMode") }?.tab == .terminal)
            #expect(entries.first { $0.settingIDs.contains("keyboard.quickInputHistoryScope") }?.tab == .controls)
            #expect(entries.first { $0.settingIDs.contains("keyboard.quickInput") }?.tab == .keyboard)
            #expect(entries.first { $0.settingIDs.contains("appearance.tabIconSize") }?.tab == .tabs)
            #expect(entries.contains { $0.matches("clipboard paste") && $0.tab == .controls })
            #expect(entries.contains { $0.matches("粘贴") && $0.tab == .controls })
            #expect(entries.contains { $0.matches("Shell 集成") && $0.tab == .terminal })
            #expect(!entries.contains { $0.matches("   ") })
            #expect(!entries.contains { $0.matches("not-a-setting-xyz") })
        }
    }

    @Test func coreOverridesRoundTripWithoutChangingExistingSettingsOrInheritedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        try #"{"general.language":"zh-Hans","editor.tabWidth":8,"future.key":"preserved"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let baseline = root.appendingPathComponent("user.ghostty")
        let source = "focus-follows-mouse = false\n"
        try source.write(to: baseline, atomically: true, encoding: .utf8)
        let settings = OhMyGhosttySettings(fileURL: url)
        let overlay = root.appendingPathComponent("appearance.ghostty")
        #expect(settings.coreOverrides.isEmpty)
        #expect(settings.setCoreOverride("focus-follows-mouse", value: "true"))
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.coreOverrides["focus-follows-mouse"] == "true")
        #expect(restored.editorTabWidth == 8)
        #expect(restored.language == .simplifiedChinese)
        let loaded = Ghostty.Config(at: baseline.path, overrideAt: overlay.path)
        #expect(loaded.errors.isEmpty)
        var enabled = false
        let key = "focus-follows-mouse"
        #expect(ghostty_config_get(loaded.config, &enabled, key, UInt(key.utf8.count)))
        #expect(enabled)
        #expect(restored.setCoreOverride(key, value: nil))
        let inherited = Ghostty.Config(at: baseline.path, overrideAt: overlay.path)
        #expect(ghostty_config_get(inherited.config, &enabled, key, UInt(key.utf8.count)))
        #expect(!enabled)
        #expect(try String(contentsOf: baseline, encoding: .utf8) == source)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["future.key"] as? String == "preserved")
        #expect(json["core.focus-follows-mouse"] == nil)
    }

    @Test func coreOverrideCatalogAcceptsOnlyValidatedValuesAndParsesWithRealCore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let settings = OhMyGhosttySettings(fileURL: url)
        let overlay = root.appendingPathComponent("appearance.ghostty")
        #expect(CoreSetting.all.count == Set(CoreSetting.all.map(\.key)).count)
        #expect(!settings.setCoreOverride("command", value: "echo unexpected"))
        #expect(!settings.setCoreOverride("clipboard-read", value: "allow\ncommand = echo unexpected"))
        for field in CoreSetting.all {
            for value in field.values {
                #expect(settings.setCoreOverride(field.key, value: value))
                let config = Ghostty.Config(at: overlay.path)
                #expect(config.loaded)
                #expect(config.errors.isEmpty, "\(field.key)=\(value): \(config.errors)")
            }
            #expect(settings.setCoreOverride(field.key, value: ""))
        }
        #expect(settings.coreOverrides.isEmpty)
        // Hand-edited unknown/invalid keys remain preserved but never reach the core overlay.
        try #"{"core.clipboard-read":"allow\ncommand = bad","core.command":"bad"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        settings.reloadFromDisk()
        #expect(settings.coreOverrides.isEmpty)
        #expect(!(try String(contentsOf: overlay, encoding: .utf8)).contains("command ="))
    }
}
