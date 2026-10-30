import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeActionControlsTests {
    @Test func menusKeepTheOriginalActionAndDoNotReenableUnavailableItems() throws {
        var events: [String] = []
        var entries: [NativeMenuEntry] = [
            .action("Unavailable", enabled: false) { events.append("disabled") },
            .action("Original", checked: true) { events.append("original") },
            .submenu("Options", entries: [.action("Nested") { events.append("nested") }])
        ]
        let menu = NativeActionMenu.make(entries)
        entries = [.action("Replacement") { events.append("replacement") }]
        _ = NativeActionMenu.make(entries)
        menu.update()
        #expect(!menu.autoenablesItems)
        let unavailable = try #require(menu.item(at: 0))
        #expect(!unavailable.isEnabled)
        NSApp.sendAction(try #require(unavailable.action), to: unavailable.target, from: unavailable)
        #expect(events.isEmpty)
        let original = try #require(menu.item(at: 1))
        #expect(original.state == .on)
        NSApp.sendAction(try #require(original.action), to: original.target, from: original)
        let nested = try #require(menu.item(at: 2)?.submenu?.item(at: 0))
        NSApp.sendAction(try #require(nested.action), to: nested.target, from: nested)
        #expect(events == ["original", "nested"])
    }

    @Test func nativeButtonHasExplicitTargetAndDisabledActionsAreIgnored() throws {
        let button = NativeActionControl()
        button.configure(title: "Action", symbol: "plus", help: "Create",
                         enabled: true, style: .bordered, identifier: "test.action")
        var presses = 0
        button.onPress = { presses += 1 }
        #expect(button.target === button)
        NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(presses == 1)
        button.isEnabled = false
        NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(presses == 1)
        #expect(button.keyEquivalent.isEmpty)
    }
}
