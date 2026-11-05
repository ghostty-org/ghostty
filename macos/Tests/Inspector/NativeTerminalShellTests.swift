import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct NativeTerminalShellTests {
    @Test func oneNativeBackdropPaintsOnlyVisibleSidebars() throws {
        let shell = TerminalShellNativeView(frame: .init(x: 0, y: 0, width: 1_000, height: 600))
        let fill = NSColor(displayP3Red: 26 / 217, green: 26 / 217, blue: 38 / 217, alpha: 217 / 255)
        func update(_ left: Bool, _ right: Bool) {
            shell.update(leading: AnyView(Color.clear), center: AnyView(Color.clear), trailing: AnyView(Color.clear),
                         layout: .init(leadingWidth: 201, trailingWidth: 320,
                                       leadingVisible: left, trailingVisible: right), background: fill)
            shell.layoutSubtreeIfNeeded()
        }
        update(true, true)
        let path = try #require(shell.chromeBackdrop.path)
        #expect(shell.chromeBackdrop.fillColor == fill.cgColor)
        #expect(path.contains(.init(x: 100, y: 300)))
        #expect(path.contains(.init(x: 900, y: 300)))
        #expect(!path.contains(.init(x: 500, y: 300)), "The terminal must not receive a second background fill")
        update(false, true)
        let rightOnly = try #require(shell.chromeBackdrop.path)
        #expect(!rightOnly.contains(.init(x: 100, y: 300)))
        #expect(rightOnly.contains(.init(x: 900, y: 300)))
        update(false, false)
        #expect(shell.chromeBackdrop.isHidden)
        #expect(shell.chromeBackdrop.path?.isEmpty == true)
    }

    private struct InputProbe: NSViewRepresentable {
        let input: NSTextView
        func makeNSView(context: Context) -> NSTextView { input }
        func updateNSView(_ view: NSTextView, context: Context) {}
    }

    @Test func hidingInspectorRestoresTheOwningContentResponder() async throws {
        let shell = TerminalShellNativeView()
        let contentInput = NSTextView(), inspectorInput = NSTextView()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.contentView = nil; window.close() }
        func update(_ visible: Bool) {
            shell.update(leading: AnyView(Color.clear),
                         center: AnyView(InputProbe(input: contentInput)),
                         trailing: AnyView(InputProbe(input: inspectorInput)),
                         layout: .init(leadingWidth: 200, trailingWidth: 320,
                                       leadingVisible: false, trailingVisible: visible))
            shell.layoutSubtreeIfNeeded()
        }
        update(true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(window.makeFirstResponder(contentInput))
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(window.makeFirstResponder(inspectorInput))
        update(false)
        #expect(window.firstResponder === contentInput)
        #expect(shell.trailingHost?.isHidden == true)
    }

    @Test func accessoryTogglesRetainContentAndInspectorWhileReleasingTheSharedSidebar() throws {
        let shell = TerminalShellNativeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        func update(_ left: Bool, _ right: Bool) {
            shell.update(leading: AnyView(Color.red), center: AnyView(Color.clear), trailing: AnyView(Color.blue),
                         layout: .init(leadingWidth: 201, trailingWidth: 320, leadingVisible: left, trailingVisible: right))
            shell.layoutSubtreeIfNeeded()
        }
        update(false, false)
        #expect(shell.leadingHost == nil)
        #expect(shell.trailingHost == nil)
        #expect(shell.centerHost.frame == shell.bounds)
        update(true, true)
        let left = try #require(shell.leadingHost)
        let right = try #require(shell.trailingHost)
        let center = shell.centerHost
        #expect(center.frame.width == 478)
        update(false, false)
        #expect(center.frame == shell.bounds)
        #expect(left.isHidden && right.isHidden)
        update(true, true)
        #expect(shell.centerHost === center)
        #expect(shell.leadingHost !== left)
        #expect(shell.trailingHost === right)
        shell.setFrameSize(NSSize(width: 700, height: 400))
        shell.layoutSubtreeIfNeeded()
        #expect(center.frame.width >= TerminalShellStyle.minimumTerminalWidth)
        #expect(right.frame.maxX == shell.bounds.maxX)
        #expect(center.frame.maxX == right.frame.minX)
        // An unusually small restored window must never assign negative sizes.
        shell.setFrameSize(NSSize(width: 100, height: 100))
        shell.layoutSubtreeIfNeeded()
        #expect(center.frame.width >= 0)
        #expect(right.frame.width >= 0)
    }

    @Test func removedProviderEvictsCachedNativeContentWhileHidden() {
        let deck = InspectorPaneDeck.Container()
        let tab = UUID()
        deck.show(AnyView(Color.red), paneID: "one", tabID: tab, availableIDs: ["one", "two"])
        deck.show(AnyView(Color.blue), paneID: "two", tabID: tab, availableIDs: ["one", "two"])
        deck.reconcile(tabID: tab, availableIDs: ["one"])
        #expect(Set(deck.hosts.keys) == ["one"])
        deck.reconcile(tabID: UUID(), availableIDs: ["one"])
        #expect(deck.hosts.isEmpty)
    }
}
