import AppKit
import SwiftUI
import GhosttyKit
import IOSurface
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SurfacePresentationOwnershipTests {
    @Test func retiredScrollContainerCannotResizeTheRemountedSurface() throws {
        let native = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)
        let lease = SurfacePresentationLease()
        surface.presentation.authorize(lease)
        let old = SurfaceScrollView(contentSize: .init(width: 800, height: 600), surfaceView: surface, lease: lease)
        old.setFrameSize(.init(width: 800, height: 600))
        old.layoutSubtreeIfNeeded()
        let current = SurfaceScrollView(contentSize: .init(width: 400, height: 600), surfaceView: surface, lease: lease)
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
        old.mount(lease: lease)
        old.unmount()
        #expect(surface.isDescendant(of: current))
        #expect(surface.frame == expected)
        current.setFrameSize(.zero)
        current.layoutSubtreeIfNeeded()
        #expect(surface.frame == expected, "A transient zero-size host must preserve the last drawable geometry")
        current.setFrameSize(.init(width: 320, height: 500))
        current.layoutSubtreeIfNeeded()
        #expect(surface.frame.width > 300 && surface.frame.height > 400)
    }

    @Test func movingBetweenControllersRejectsTheSourceTreeAndAllowsReturn() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let source = try fixture.tab()
        let target = try fixture.tab()
        let surface = try #require(source.surfaceTree.first)
        let sourceLease = source.surfacePresentationLease
        let size = CGSize(width: 400, height: 600)
        let old = SurfaceScrollView(contentSize: size, surfaceView: surface, lease: sourceLease)
        target.surfaceTree = .init(view: surface)
        let current = SurfaceScrollView(
            contentSize: size, surfaceView: surface, lease: target.surfacePresentationLease
        )
        source.surfaceTree = .init()
        let late = SurfaceScrollView(contentSize: size, surfaceView: surface, lease: sourceLease)
        old.unmount()
        late.layoutSubtreeIfNeeded()
        #expect(surface.isDescendant(of: current))
        source.surfaceTree = .init(view: surface)
        let returned = SurfaceScrollView(
            contentSize: size, surfaceView: surface, lease: source.surfacePresentationLease
        )
        target.surfaceTree = .init()
        current.unmount()
        #expect(surface.isDescendant(of: returned))
    }

    @Test func terminalInspectorInvalidatesThePreviousLeafPresentation() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        let lease = controller.surfacePresentationLease
        surface.inspectorVisible = true
        #expect(controller.surfacePresentationLease !== lease)
        #expect(surface.presentation.lease === controller.surfacePresentationLease)
        let inspectorLease = controller.surfacePresentationLease
        surface.inspectorVisible = false
        #expect(controller.surfacePresentationLease !== inspectorLease)
    }

    @Test func retainedSurfaceProducesAnImageAfterHistoryAndRepeatedRemounts() async throws {
        let native = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'i=0; while [ $i -lt 1000 ]; do echo HISTORY-$i; i=$((i+1)); done; echo VISIBLE-PANE; exec /bin/sleep 60'"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)
        let core = try #require(surface.surface)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<100 where !surface.cachedScreenContents.get().contains("VISIBLE-PANE") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(surface.cachedScreenContents.get().contains("VISIBLE-PANE"))
        for index in 0..<6 {
            let lease = SurfacePresentationLease()
            surface.presentation.authorize(lease)
            let size = CGSize(width: index % 2 == 0 ? 400 : 600, height: 500)
            let wrapper = SurfaceScrollView(contentSize: size, surfaceView: surface, lease: lease)
            window.contentView = wrapper
            window.setContentSize(size)
            wrapper.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            ghostty_surface_draw(core)
            let image = try #require(surface.layer?.contents as? IOSurface)
            let layer = try #require(surface.layer)
            #expect(image.width == Int(layer.bounds.width * layer.contentsScale))
            #expect(image.height == Int(layer.bounds.height * layer.contentsScale))
            image.lock(options: .readOnly, seed: nil)
            let pixels = image.baseAddress.assumingMemoryBound(to: UInt32.self)
            let first = pixels[0]
            let stride = image.bytesPerRow / MemoryLayout<UInt32>.stride
            let hasTextPixels = (0..<image.height).contains { row in
                (0..<image.width).contains { column in pixels[row * stride + column] != first }
            }
            image.unlock(options: .readOnly, seed: nil)
            #expect(hasTextPixels, "The retained IOSurface must contain drawn terminal cells")
            #expect(surface.window === window)
            #expect(surface.cachedScreenContents.get().contains("VISIBLE-PANE"))
        }
    }

    @Test func retiredHostingTreeCannotStealSurfaceDuringDelayedReconstruction() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        let size = CGSize(width: 400, height: 600)
        let oldLease = controller.surfacePresentationLease
        let retiredContent = TerminalSplitTreeView(
            tree: controller.surfaceTree, presentationLease: oldLease, action: { _ in }
        )
        .environmentObject(fixture.app)
        .environment(\.editorTerminalController, controller)
        let retired = NSHostingView(rootView: retiredContent.id(0))
        retired.frame.size = size
        retired.layoutSubtreeIfNeeded()

        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        _ = try #require(controller.newSplit(at: surface, direction: .right, baseConfig: config))
        let lease = controller.surfacePresentationLease
        #expect(lease !== oldLease)
        let content = TerminalSplitTreeView(
            tree: controller.surfaceTree, presentationLease: lease, action: { _ in }
        )
        .environmentObject(fixture.app)
        .environment(\.editorTerminalController, controller)
        let current = NSHostingView(rootView: content.id(0))
        current.frame.size = size
        current.layoutSubtreeIfNeeded()
        #expect(surface.isDescendant(of: current))

        for generation in 1...5 {
            retired.rootView = retiredContent.id(generation)
            retired.layoutSubtreeIfNeeded()
            #expect(surface.isDescendant(of: current), "A retired tree must not acquire a new mount")
            current.rootView = content.id(0)
            current.layoutSubtreeIfNeeded()
            #expect(surface.isDescendant(of: current))
        }
        #expect(surface.frame.width > 40 && surface.frame.height > 40)
    }

    @Test func leaseSurvivesRatioChangesButNotZoomOrTreeReplacement() throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let controller = try fixture.tab()
        let surface = try #require(controller.surfaceTree.first)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        _ = try #require(controller.newSplit(at: surface, direction: .right, baseConfig: config))
        let lease = controller.surfacePresentationLease
        let root = try #require(controller.surfaceTree.root)
        controller.surfaceTree = .init(root: root.resizing(to: 0.3), zoomed: nil)
        #expect(controller.surfacePresentationLease === lease)
        controller.surfaceTree = .init(root: controller.surfaceTree.root, zoomed: .leaf(view: surface))
        #expect(controller.surfacePresentationLease !== lease)
        #expect(surface.presentation.lease === controller.surfacePresentationLease)
        let zoomLease = controller.surfacePresentationLease
        controller.surfaceTree = .init(view: surface)
        #expect(controller.surfacePresentationLease !== zoomLease)
    }

    @Test(arguments: [TerminalResizeRenderingMode.duringDrag, .onRelease], [false, true])
    func remountCommitsGeometryToTheActualPTY(mode: TerminalResizeRenderingMode, renewLease: Bool) async throws {
        let native = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)
        let lease = SurfacePresentationLease()
        surface.presentation.authorize(lease)
        let old = SurfaceScrollView(contentSize: .init(width: 800, height: 600), surfaceView: surface, lease: lease)
        old.frame.size = .init(width: 800, height: 600)
        old.layoutSubtreeIfNeeded()
        for _ in 0..<100 where surface.surfaceModel?.ttyName == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let tty = try #require(surface.surfaceModel?.ttyName)
        let fd = open(tty, O_RDONLY | O_NOCTTY)
        try #require(fd >= 0)
        defer { close(fd) }
        let initial = ghostty_surface_size(try #require(surface.surface))
        var actual = winsize()
        for _ in 0..<100 {
            try #require(ioctl(fd, TIOCGWINSZ, &actual) == 0)
            if actual.ws_col == initial.columns && actual.ws_row == initial.rows { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(actual.ws_col == initial.columns && actual.ws_row == initial.rows)
        // Drain the initial ordinary resize, whose coalescing otherwise also
        // commits the live size and masks a lost handoff commit.
        try await Task.sleep(for: .milliseconds(100))
        let originalMode = OhMyGhosttySettings.shared.terminalResizeRendering
        defer { OhMyGhosttySettings.shared.terminalResizeRendering = originalMode }
        OhMyGhosttySettings.shared.terminalResizeRendering = mode
        surface.presentation.beginResize()
        old.frame.size = .init(width: 400, height: 600)
        old.layoutSubtreeIfNeeded()
        // No await: take ownership before the 50 ms stable-size commit can run.
        let nextLease = renewLease ? SurfacePresentationLease() : lease
        if renewLease { surface.presentation.authorize(nextLease) }
        let current = SurfaceScrollView(contentSize: old.frame.size, surfaceView: surface, lease: nextLease)
        current.frame.size = old.frame.size
        current.layoutSubtreeIfNeeded()
        old.unmount()
        let expected = ghostty_surface_size(try #require(surface.surface))
        #expect(expected.columns != initial.columns)
        for _ in 0..<100 {
            try #require(ioctl(fd, TIOCGWINSZ, &actual) == 0)
            if actual.ws_col == expected.columns && actual.ws_row == expected.rows { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(actual.ws_col == expected.columns)
        #expect(actual.ws_row == expected.rows)
        #expect(surface.isDescendant(of: current))
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
