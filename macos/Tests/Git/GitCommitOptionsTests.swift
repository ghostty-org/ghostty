import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct GitCommitOptionsTests {
    private func controls(in view: NSView) -> [NativeActionControl] {
        (view as? NativeActionControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test func optionsPreserveFocusDisabledActionsAndLiveTheme() throws {
        let entries: [NativeMenuEntry] = [
            .action("Commit Staged", symbol: "checkmark", enabled: false) {},
            .action("Stage All and Commit", symbol: "plus") {},
            .separator,
            .action("Amend Last Commit", symbol: "arrow.uturn.backward") {},
        ]
        let controller = NativeActionPopoverController(entries: entries)
        let window = NSWindow(contentRect: .init(origin: .zero, size: controller.preferredContentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        let buttons = controls(in: controller.view)
        #expect(buttons.count == 3)
        #expect(!buttons[0].isEnabled)
        var selected: [Int] = []
        var cancelled = false
        controller.onSelect = { selected.append($0) }
        controller.onCancel = { cancelled = true }
        controller.focusFirstOption()
        #expect(window.firstResponder === buttons[1])
        buttons[1].keyDown(with: try key(125))
        #expect(window.firstResponder === buttons[2])
        buttons[2].keyDown(with: try key(125))
        #expect(window.firstResponder === buttons[1])
        buttons[1].keyDown(with: try key(126))
        #expect(window.firstResponder === buttons[2])
        buttons[2].keyDown(with: try key(36))
        #expect(selected == [3])
        buttons[0].performClick(nil)
        #expect(selected == [3])
        controller.update(entries)
        #expect(controls(in: controller.view)[2] === buttons[2])
        #expect(window.firstResponder === buttons[2])
        buttons[2].keyDown(with: try key(53))
        #expect(cancelled)
        for (name, theme) in [
            ("dark", OMGNativeTheme(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                                    foreground: NSColor(white: 0.85, alpha: 1))),
            ("light", OMGNativeTheme(background: NSColor(white: 0.96, alpha: 1),
                                     foreground: NSColor(white: 0.15, alpha: 1))),
        ] {
            controller.surface.applyTheme(theme)
            controller.view.layoutSubtreeIfNeeded()
            #expect(buttons.allSatisfy { $0.theme == theme })
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/omg-commit-options-\(name).png"))
        }
    }

    @Test func popoverOpensAboveAnchorAndClosesBeforeActionOrContextChange() throws {
        let window = NSWindow(contentRect: .init(x: 200, y: 180, width: 480, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = GitCommitOptionsControl(frame: .init(x: 220, y: 140, width: 28, height: 28))
        try #require(window.contentView).addSubview(button)
        defer { button.close(); window.close() }
        window.orderFront(nil)
        var didCommit = false
        button.update(enabled: true, repository: nil, entries: [.action("Commit") {
            #expect(!button.isExpanded)
            didCommit = true
        }])
        button.toggle()
        try #require(button.isExpanded)
        let popup = try #require(button.optionsController?.view.window)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        #expect(popup.frame.midY > anchor.maxY)
        #expect(button.isMenuOpen)
        #expect(button.layer?.sublayers?.contains { $0.animation(forKey: "disclosure") != nil } == true ||
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let option = try #require(button.optionsController.flatMap { controls(in: $0.view).first })
        option.performClick(nil)
        #expect(didCommit)
        #expect(!button.isExpanded)
        #expect(!button.isMenuOpen)
        button.toggle()
        try #require(button.isExpanded)
        // A status refresh must update enabled actions without preserving stale closures.
        var updatedAction = false
        button.update(enabled: true, repository: nil, entries: [.action("Updated") { updatedAction = true }])
        try #require(button.optionsController.flatMap { controls(in: $0.view).first }).performClick(nil)
        #expect(updatedAction)
        #expect(!button.isExpanded)
        button.toggle()
        try #require(button.isExpanded)
        button.update(enabled: false, repository: nil, entries: [.action("Unavailable", enabled: false) {}])
        #expect(!button.isExpanded)
        button.toggle()
        #expect(!button.isExpanded)
        button.update(enabled: true, repository: nil, entries: [.action("Commit") {}])
        button.toggle()
        try #require(button.isExpanded)
        let changed = GitRepositoryIdentity(worktreePath: "/other", gitDirPath: "/other/.git", commonGitDirPath: "/other/.git")
        button.update(enabled: true, repository: changed, entries: [.action("Other repo") {}])
        #expect(!button.isExpanded)
        button.toggle()
        try #require(button.isExpanded)
        button.removeFromSuperview()
        #expect(!button.isExpanded)
    }
}
