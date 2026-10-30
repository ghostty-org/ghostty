import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct SettingsControlsTests {
    @Test func pickerUsesNativeMenuAndPreservesSelectionSemantics() throws {
        var value: String?
        let binding = Binding<String?>(get: { value }, set: { value = $0 })
        let options: [OMGSettingsOption<String?>] = [.init(nil, "Follow Config"), .init("on", "On"), .init("off", "Off")]
        let trigger = OMGSettingsMenuTrigger(title: "Test", selection: binding, options: options, enabled: true)
        let coordinator = trigger.makeCoordinator()
        let menu = coordinator.makeMenu()
        #expect(menu.items.map(\.title) == options.map(\.title))
        #expect(menu.items.map(\.state) == [.on, .off, .off])
        coordinator.choose(try #require(menu.item(at: 1)))
        #expect(value == "on")
        coordinator.choose(try #require(menu.item(at: 0)))
        #expect(value == nil)
        coordinator.parent = .init(title: "Test", selection: binding, options: options, enabled: false)
        coordinator.choose(try #require(menu.item(at: 2)))
        #expect(value == nil)
        // Reordered live options must not turn an open menu's item into a different value.
        coordinator.parent = .init(title: "Test", selection: binding, options: options.reversed(), enabled: true)
        coordinator.choose(try #require(menu.item(at: 1)))
        #expect(value == "on")
        coordinator.parent = .init(title: "Test", selection: binding, options: [.init(nil, "Follow Config")], enabled: true)
        coordinator.choose(try #require(menu.item(at: 2)))
        #expect(value == "on")
    }

    @Test func sshHostPickerUsesNativeItemsAndPreservesHostIdentity() throws {
        var value = "local"
        let binding = Binding(get: { value }, set: { value = $0 })
        let items: [SSHHostPicker.Item] = [
            .init(id: "local", title: "Local", detail: "This Mac", symbol: "desktopcomputer"),
            .init(id: "cloud", title: "cloud", detail: "me@example.test:22", status: "Connected"),
        ]
        let picker = SSHHostPicker(items: items, selection: binding, accessibilityLabel: "SSH target")
        let coordinator = picker.makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.update(button)

        #expect(button.itemTitles == ["Select an SSH host…", "Local · This Mac", "cloud · me@example.test:22 · Connected"])
        #expect(button.selectedItem?.representedObject as? String == "local")
        #expect(button.item(at: 0)?.isEnabled == false)
        #expect(button.menu?.autoenablesItems == false)

        coordinator.parent = .init(items: Array(items.reversed()), selection: binding, accessibilityLabel: "SSH target")
        coordinator.update(button)
        #expect(button.selectedItem?.representedObject as? String == "local")

        coordinator.selectItem(button)
        #expect(value == "local")
        button.selectItem(at: 1)
        coordinator.selectItem(button)
        #expect(value == "cloud")
        button.selectItem(at: 1)
        coordinator.parent = .init(items: items, selection: binding, enabled: false, accessibilityLabel: "SSH target")
        coordinator.selectItem(button)
        #expect(value == "cloud")
    }

    @Test func hostMenuPreservesDistinctIdentitiesWithIdenticalDisplayNames() {
        var value = "second"
        let picker = SSHHostPicker(
            items: [.init(id: "first", title: "cloud"), .init(id: "second", title: "cloud")],
            selection: Binding(get: { value }, set: { value = $0 })
        )
        let coordinator = picker.makeCoordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        coordinator.update(button)
        #expect(button.numberOfItems == 3)
        #expect(button.selectedItem?.representedObject as? String == "second")
        button.selectItem(at: 1)
        coordinator.selectItem(button)
        #expect(value == "first")
    }

    @Test func agentIsOnlyInIntegrationsAndHasConsistentName() {
        #expect(!OhMyGhosttySettingsTab.primary.contains(.agents))
        #expect(OhMyGhosttySettingsTab.integrations.first == .agents)
        for language in [OhMyGhosttyLanguage.english, .simplifiedChinese] {
            let strings = SettingsStrings(language: language)
            #expect(strings.tabTitle(.agents) == "Agent")
            #expect(strings.agentIntegrationSection == "Agent")
        }
    }

    @Test func pickerHasFullWidthNativeAccessibleHitTarget() async throws {
        let host = NSHostingView(rootView: OMGSettingsPicker(title: "Mode", selection: .constant("on"),
            options: [.init("on", "Enabled"), .init("off", "Disabled")], showsTitle: false))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 220, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = try #require(buttons(host).first { $0.accessibilityLabel() == "Mode" })
        #expect(button.frame.width == 180)
        #expect(button.frame.height == OMGSettingsControlMetrics.height)
        #expect(button.accessibilityValue() as? String == "Enabled")
        #expect(button.accessibilityRole() == .popUpButton)
        #expect(button.isEnabled)
    }
}
