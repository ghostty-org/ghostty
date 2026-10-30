import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct AgentQuickInputDockContainerTests {
    private struct MountProbe: NSViewRepresentable {
        let create: () -> NSView
        func makeNSView(context: Context) -> NSView { create() }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    @Test func smallWindowClampsAccessoriesAndRestoresRequestedHeightsOnResize() {
        let container = AgentQuickInputDockContainer.Container(frame: .init(x: 0, y: 0, width: 800, height: 100))
        container.update(content: AnyView(Color.clear), composer: AnyView(Color.clear), queue: AnyView(Color.clear),
                         composerHeight: 253, queueHeight: 61)
        container.layoutSubtreeIfNeeded()
        #expect(container.contentHost.frame.height >= -0.001)
        #expect(abs(container.composerHost.frame.height - 39) < 0.001)
        container.setFrameSize(.init(width: 800, height: 600))
        container.layoutSubtreeIfNeeded()
        #expect(abs(container.composerHost.frame.height - 253) < 0.001)
        #expect(abs(container.contentHost.frame.height - 286) < 0.001)
    }

    @Test func togglingAccessoriesRetainsTheTerminalAndComposerAtTheirFinalGeometry() async throws {
        let terminal = NSView()
        let editor = NSTextView()
        editor.string = "draft / 草稿"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        var terminalMounts = 0
        var composerMounts = 0
        let container = AgentQuickInputDockContainer.Container()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        for (composerHeight, queueHeight) in [(253.0, 61.0), (0, 61), (0, 0), (253, 0), (300, 61)] {
            container.update(
                content: AnyView(MountProbe { terminalMounts += 1; return terminal }),
                composer: AnyView(MountProbe { composerMounts += 1; return editor }),
                queue: AnyView(Color.clear),
                composerHeight: composerHeight,
                queueHeight: queueHeight
            )
            container.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            container.layoutSubtreeIfNeeded()
            #expect(terminalMounts == 1)
            #expect(composerMounts == 1)
            #expect(abs(container.contentHost.frame.height - (600 - composerHeight - queueHeight)) < 0.001)
            #expect(abs(container.composerHost.frame.height - composerHeight) < 0.001)
            #expect(abs(container.queueHost.frame.height - queueHeight) < 0.001)
            #expect(container.composerHost.isHidden == (composerHeight == 0))
            #expect(container.queueHost.isHidden == (queueHeight == 0))
            #expect(editor.string == "draft / 草稿")
            #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        }
    }
}
