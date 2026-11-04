import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SurfacePresentationOwnershipTests {
    @Test func retiredScrollContainerCannotResizeTheRemountedSurface() throws {
        let native = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)
        let old = SurfaceScrollView(contentSize: .init(width: 800, height: 600), surfaceView: surface)
        old.setFrameSize(.init(width: 800, height: 600))
        old.layoutSubtreeIfNeeded()
        let current = SurfaceScrollView(contentSize: .init(width: 400, height: 600), surfaceView: surface)
        current.setFrameSize(.init(width: 400, height: 600))
        current.layoutSubtreeIfNeeded()
        let expected = surface.frame
        #expect(expected.width > 300 && expected.height > 500)
        #expect(surface.isDescendant(of: current))
        // SwiftUI can retire the old split leaf after the new leaf has mounted.
        old.setFrameSize(.zero)
        old.layoutSubtreeIfNeeded()
        #expect(surface.frame == expected)
        old.setFrameSize(.init(width: 900, height: 700))
        old.layoutSubtreeIfNeeded()
        #expect(surface.frame == expected)
        current.setFrameSize(.zero)
        current.layoutSubtreeIfNeeded()
        #expect(surface.frame == expected, "A transient zero-size host must preserve the last drawable geometry")
        current.setFrameSize(.init(width: 320, height: 500))
        current.layoutSubtreeIfNeeded()
        #expect(surface.frame.width > 300 && surface.frame.height > 400)
    }

    @Test func originalPaneRemainsMountedAcrossRepeatedSplitAndAccessoryChanges() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        controller.showWindow(nil)
        let original = try #require(controller.surfaceTree.first)
        let window = try #require(controller.window)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        for index in 0..<3 {
            _ = try #require(controller.newSplit(at: original, direction: index % 2 == 0 ? .right : .down, baseConfig: config))
            for presented in [true, false] {
                if presented { controller.quickInputModel.present(for: original.id, requestFocus: false) } else { controller.quickInputModel.dismiss() }
                try await Task.sleep(for: .milliseconds(120))
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(original.window === window)
                #expect(!original.isHiddenOrHasHiddenAncestor)
                #expect(original.bounds.width > 40 && original.bounds.height > 40)
                #expect(controller.surfaceTree.contains { $0 === original })
            }
        }
    }
}
