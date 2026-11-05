import AppKit
import Combine
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalLinkHoverTests {
    private func makeController(split: Bool, command: String = "/bin/sleep 30") throws -> TerminalController {
        let app = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = "/tmp"
        let controller = TerminalController(app.ghostty, withBaseConfig: config, tabLayout: .vertical)
        if split {
            let surface = try #require(controller.focusedSurface)
            _ = try #require(controller.newSplit(at: surface, direction: .right, baseConfig: config))
        }
        controller.showWindow(nil)
        return controller
    }

    @Test(arguments: [false, true])
    func trackingAreasSurviveHoverAndGeometryUpdates(split: Bool) async throws {
        let controller = try makeController(split: split)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        try await Task.sleep(for: .milliseconds(100))
        surface.updateTrackingAreas()
        let areas = surface.trackingAreas
        #expect(areas.contains { $0.options.contains([.cursorUpdate, .inVisibleRect, .activeInKeyWindow]) })
        #expect(areas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways]) })
        for shape in [GHOSTTY_MOUSE_SHAPE_POINTER, GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_POINTER] {
            surface.setCursorShape(shape)
            surface.hoverUrl = shape == GHOSTTY_MOUSE_SHAPE_POINTER ? "https://example.com" : nil
            surface.updateTrackingAreas()
            #expect(surface.trackingAreas == areas, "Hover must not replace tracking areas and synthesize mouse exits")
        }
        surface.setFrameSize(CGSize(width: surface.frame.width + 10, height: surface.frame.height + 10))
        surface.updateTrackingAreas()
        #expect(surface.trackingAreas == areas, "inVisibleRect already follows geometry changes")
    }

    @Test func cursorUpdateUsesCurrentCoreShape() throws {
        let controller = try makeController(split: false)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: surface.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        for shape in [GHOSTTY_MOUSE_SHAPE_POINTER, GHOSTTY_MOUSE_SHAPE_TEXT] {
            surface.setCursorShape(shape)
            NSCursor.arrow.set() // Simulate an ancestor/hosting view resetting the cursor.
            surface.cursorUpdate(with: event)
            #expect(NSCursor.current == surface.pointerStyle.cursor)
        }
    }

    @Test func linkHoverShowsHintWithoutChangingCursor() throws {
        let controller = try makeController(split: false)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        var styles = 0
        var hovers = 0
        let styleToken = surface.$pointerStyle.dropFirst().sink { _ in styles += 1 }
        let hoverToken = surface.$isHoveringLink.dropFirst().sink { _ in hovers += 1 }
        defer { styleToken.cancel(); hoverToken.cancel() }
        for _ in 0..<10 { surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_POINTER) }
        #expect(styles == 0, "Links must not switch the cursor to a pointing hand")
        #expect(surface.pointerStyle == .horizontalText)
        #expect(surface.isHoveringLink)
        #expect(hovers == 1, "Moving across one link must not republish per cell")
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        #expect(!surface.isHoveringLink)
        #expect(hovers == 2)
        #expect(styles == 0)
    }

    @Test func modifierReleaseClearsHintWhileComposerOwnsFirstResponder() async throws {
        let controller = try makeController(split: true)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let window = try #require(controller.window)
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(composer)
        window.makeFirstResponder(composer)
        surface.updateLinkHoverModifiers(.command)
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_POINTER)
        surface.hoverUrl = "https://example.com"
        #expect(surface.isHoveringLink && surface.linkHintCommandPressed)
        let release = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37))
        NSApp.sendEvent(release)
        #expect(window.firstResponder === composer)
        #expect(!surface.linkHintCommandPressed)
        #expect(!surface.isHoveringLink)
        #expect(surface.hoverUrl == nil)
        // A delayed core cursor callback cannot bring the chip back after key-up.
        surface.setCursorShape(GHOSTTY_MOUSE_SHAPE_POINTER)
        #expect(!surface.linkHintCommandPressed)
        surface.updateLinkHoverModifiers(.command)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!surface.linkHintCommandPressed && !surface.isHoveringLink)
    }

    @Test func linkHintStaysInsideSurface() {
        let container = CGSize(width: 400, height: 300)
        let chip = CGSize(width: 90, height: 20)
        // AppKit y=290 is near the top; the chip sits below-right of the cursor.
        let normal = SurfaceLinkHint.origin(for: CGPoint(x: 100, y: 290), chip: chip, container: container)
        #expect(normal == CGPoint(x: 114, y: 28))
        // Near the bottom-right corner it flips to the top-left of the cursor.
        let corner = SurfaceLinkHint.origin(for: CGPoint(x: 390, y: 5), chip: chip, container: container)
        #expect(corner.x + chip.width <= 390)
        #expect(corner.y + chip.height <= 295)
        #expect(corner.x >= SurfaceLinkHint.edgeInset && corner.y >= SurfaceLinkHint.edgeInset)
    }

    @Test(arguments: [false, true])
    func linkHoverKeepsSurfaceAsHitTarget(split: Bool) async throws {
        let controller = try makeController(split: split)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let content = try #require(controller.window?.contentView)
        try await Task.sleep(for: .milliseconds(100))
        for url in [nil, "https://example.com", nil] as [String?] {
            surface.hoverUrl = url
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            for fraction in [0.25, 0.5, 0.75] {
                let point = NSPoint(x: surface.bounds.midX, y: surface.bounds.height * fraction)
                #expect(content.hitTest(surface.convert(point, to: content)) === surface,
                    "Hover banner must not intercept terminal mouse events")
            }
        }
    }

    @Test func linkCheckResolvesAgainstSourcePaneFilesystem() async throws {
        let controller = try makeController(split: false)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appending(path: "env"))
        let existing = TerminalPathOpener.resolve("env", from: surface, baseDirectory: dir.path)
        #expect(existing?.path == dir.appending(path: "env").path)
        let kind = try await existing?.filesystem.itemType(at: existing?.path ?? "")
        #expect(kind == .file)
        let missing = try #require(TerminalPathOpener.resolve("missing.swift", from: surface, baseDirectory: dir.path))
        #expect(try await missing.filesystem.itemType(at: missing.path) == nil)
        // Unknown output cwd: relative candidates never resolve, so they stay unlinked.
        #expect(TerminalPathOpener.resolve("env", from: surface, baseDirectory: "") == nil)
        // Replies for candidates the core never requested are ignored safely.
        TerminalLinkChecker.check(url: "env", baseDirectory: dir.path, from: surface)
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test(arguments: [false, true])
    func releasingCommandDuringPreeditClearsLinkHover(split: Bool) async throws {
        // OSC8 requires Command independently of user-configured URL regexes.
        let controller = try makeController(split: split,
            command: "/bin/sh -c 'printf \"\\033]8;;https://example.com\\007hover-target\\033]8;;\\007\\n\"; sleep 30'")
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let surface = try #require(controller.focusedSurface)
        for _ in 0..<100 {
            if surface.cachedScreenContents.get().contains("hover-target") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(surface.cachedScreenContents.get().contains("hover-target"))
        surface.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(surface.hasMarkedText())
        // Locate the rendered link without assuming the user's font or padding.
        var location = NSPoint.zero
        for offset in stride(from: 5.0, through: 150.0, by: 5.0) {
            location = surface.convert(NSPoint(x: 80, y: surface.bounds.height - offset), to: nil)
            let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
                modifierFlags: .command, timestamp: 0, windowNumber: surface.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            surface.mouseMoved(with: move)
            try await Task.sleep(for: .milliseconds(20))
            if surface.isHoveringLink { break }
        }
        try #require(surface.isHoveringLink)
        let release = try #require(NSEvent.keyEvent(with: .flagsChanged, location: location,
            modifierFlags: [], timestamp: 1, windowNumber: surface.window?.windowNumber ?? 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37))
        surface.flagsChanged(with: release)
        for _ in 0..<100 {
            if !surface.isHoveringLink && surface.hoverUrl == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!surface.isHoveringLink)
        #expect(surface.hoverUrl == nil)
        #expect(surface.hasMarkedText(), "Updating hover must not cancel IME composition")
        surface.unmarkText()
        #expect(!surface.isHoveringLink)
    }

    @Test(.tags(.interactiveDesktop))
    func commandHoverRemainsStable() async throws {
        for split in [false, true] {
            try await checkCommandHover(split: split)
        }
    }

    private func checkCommandHover(split: Bool) async throws {
        try #require(CGPreflightPostEventAccess(),
                     "Desktop hover test requires permission to post mouse and keyboard events.")
        let controller = try makeController(split: split,
            command: "/bin/sh -c 'printf \"https://example.com\\n\"; sleep 30'")
        let window = try #require(controller.window)
        defer { window.delegate = nil; window.close() }
        for _ in 0..<20 {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            if NSApp.isActive && window.isKeyWindow { break }
        }
        try #require(NSApp.isActive && window.isKeyWindow && window.isOnActiveSpace,
            "Desktop hover test needs an unlocked desktop and the test window in foreground")
        let surface = try #require(controller.focusedSurface)
        try await waitForAppKit { surface.cachedScreenContents.get().contains("https://example.com") }
        window.contentView?.layoutSubtreeIfNeeded()
        let point = window.convertPoint(toScreen: surface.convert(NSPoint(x: 30, y: surface.bounds.height - 10), to: nil))
        let screenHeight = try #require(NSScreen.screens.first).frame.height
        let original = NSEvent.mouseLocation
        defer {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: original.x, y: screenHeight - original.y),
                mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        for _ in 0..<20 {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: screenHeight - point.y), mouseButton: .left))
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
            #expect(surface.isHoveringLink)
            #expect(surface.pointerStyle != .link)
            #expect(surface.mouseOverSurface)
        }
        let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: false))
        release.type = .flagsChanged
        release.flags = []
        release.post(tap: .cghidEventTap)
        try await waitForAppKit { !surface.linkHintCommandPressed && !surface.isHoveringLink }
        #expect(surface.hoverUrl == nil, "Command release must hide the hint without moving the pointer.")
    }
}
