import AppKit
import Carbon
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct GlobalHotkeysTests {
    @Test func physicalKeysAndModifiersKeepTheirIdentity() throws {
        let config = try TemporaryConfig("keybind = global:ctrl+alt+shift+super+f1=toggle_visibility")
        let keys = try #require(GlobalHotkeys.nativeKeys(for: config.globalKeybinds))
        let key = try #require(keys.first)
        #expect(keys.count == 1)
        #expect(key.keyCode == UInt32(kVK_F1))
        #expect(key.carbonModifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(key.event.keycode == UInt32(kVK_F1))
        #expect(key.event.mods.rawValue == 15)
        #expect(key.event.action == GHOSTTY_ACTION_PRESS)
    }

    @Test func physicalLetterDoesNotDependOnKeyboardLayout() throws {
        let config = try TemporaryConfig("keybind = global:ctrl+key_a=toggle_visibility")
        let key = try #require(GlobalHotkeys.nativeKeys(for: config.globalKeybinds)?.first)
        #expect(key.keyCode == UInt32(kVK_ANSI_A))
    }

    @Test(arguments: [
        "global:ctrl+a=toggle_visibility",
        "global:ctrl+λ=toggle_visibility",
        "global:catch_all=toggle_visibility",
        "global:unconsumed:f2=toggle_visibility",
        "global:performable:f2=toggle_visibility",
    ])
    func unsupportedBindingFallsBackForTheWholeConfig(_ binding: String) throws {
        let config = try TemporaryConfig("""
        keybind = global:f1=toggle_visibility
        keybind = \(binding)
        """)
        #expect(config.globalKeybinds.count == 2)
        #expect(GlobalHotkeys.nativeKeys(for: config.globalKeybinds) == nil)
    }

    @Test func reloadKeepsMultipleBindingsAndDropsLocalReplacements() throws {
        let config = try TemporaryConfig("""
        keybind = global:f1=toggle_visibility
        keybind = chain=toggle_quick_terminal
        keybind = global:f2=toggle_visibility
        """)
        #expect(GlobalHotkeys.nativeKeys(for: config.globalKeybinds)?.count == 2)
        try config.reload("keybind = f1=toggle_visibility")
        #expect(GlobalHotkeys.nativeKeys(for: config.globalKeybinds)?.isEmpty == true)
    }

    @Test func unknownKeysAndModifiersDoNotGetSilentlyRewritten() throws {
        let config = try TemporaryConfig("keybind = global:f1=toggle_visibility")
        var binding = try #require(config.globalKeybinds.first)
        binding.trigger.mods = ghostty_input_mods_e(GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        #expect(GlobalHotkeys.nativeKeys(for: [binding]) == nil)
        binding.trigger.mods = GHOSTTY_MODS_NONE
        binding.trigger.key.physical = GHOSTTY_KEY_UNIDENTIFIED
        #expect(GlobalHotkeys.nativeKeys(for: [binding]) == nil)
    }

    @Test func duplicateNativeChordsFallBack() throws {
        let config = try TemporaryConfig("keybind = global:f1=toggle_visibility")
        let binding = try #require(config.globalKeybinds.first)
        #expect(GlobalHotkeys.nativeKeys(for: [binding, binding]) == nil)
    }

    @Test func focusReloadAndDeinitReleaseNativeRegistrations() throws {
        try #require(probe(keyCode: kVK_F20) == noErr)
        let config = try TemporaryConfig("keybind = global:ctrl+alt+shift+super+f20=ignore")
        do {
            let controller = GlobalHotkeys()
            controller.update(config: config)
            controller.updateActivity(active: false)
            #expect(probe(keyCode: kVK_F20) == eventHotKeyExistsErr)

            controller.updateActivity(active: true)
            #expect(probe(keyCode: kVK_F20) == noErr)
            controller.updateActivity(active: false)
            #expect(probe(keyCode: kVK_F20) == eventHotKeyExistsErr)

            try config.reload("")
            controller.update(config: config)
            #expect(probe(keyCode: kVK_F20) == noErr)
            try config.reload("keybind = global:ctrl+alt+shift+super+f20=ignore")
            controller.update(config: config)
            controller.updateActivity(active: false)
            #expect(probe(keyCode: kVK_F20) == eventHotKeyExistsErr)
        }
        #expect(probe(keyCode: kVK_F20) == noErr)
    }

    @Test func partialFailureReleasesEarlierRegistrationsAndReloadCancelsFallback() throws {
        try #require(probe(keyCode: kVK_F19) == noErr)
        var blocked: EventHotKeyRef?
        try #require(RegisterEventHotKey(UInt32(kVK_F20), modifiers,
                                         EventHotKeyID(signature: 0x54657374, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &blocked) == noErr)
        defer { if let blocked { UnregisterEventHotKey(blocked) } }
        let config = try TemporaryConfig("""
        keybind = global:ctrl+alt+shift+super+f19=ignore
        keybind = global:ctrl+alt+shift+super+f20=ignore
        """)
        let controller = GlobalHotkeys()
        // Keep the permission request deferred; this test never creates an event tap.
        controller.update(config: config, permissionDelay: 60)
        controller.updateActivity(active: false, permissionDelay: 60)
        #expect(probe(keyCode: kVK_F19) == noErr)
        try config.reload("")
        controller.update(config: config)
        #expect(probe(keyCode: kVK_F19) == noErr)
    }

    private var modifiers: UInt32 { UInt32(controlKey | optionKey | shiftKey | cmdKey) }

    private func probe(keyCode: Int) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers,
                                         EventHotKeyID(signature: 0x54657374, id: 2),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status
    }
}
