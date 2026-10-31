import AppKit
import Testing
@testable import Ghostty

@MainActor
struct NativeProgressIndicatorTests {
    @Test func detachedLoadingRowsNeverStartThreadedAnimations() {
        let indicators = (0..<100).map { _ in NativeProgressIndicator() }
        for indicator in indicators {
            indicator.style = .spinning
            indicator.setAnimating(true)
            #expect(indicator.animationRequested)
            #expect(!indicator.animationIsRunning)
            #expect(!indicator.usesThreadedAnimation)
            indicator.setAnimating(false)
        }
    }

    @Test func cachedLoadingIntentStopsOnHideOcclusionDetachAndClose() {
        final class Window: NSWindow {
            var exposed = true
            override var isVisible: Bool { true }
            override var occlusionState: NSWindow.OcclusionState { exposed ? [.visible] : [] }
        }
        let window = Window(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        let indicator = NativeProgressIndicator(frame: .init(x: 20, y: 20, width: 16, height: 16))
        indicator.style = .spinning
        root.addSubview(indicator)
        window.contentView = root
        defer { indicator.setAnimating(false); window.contentView = nil; window.close() }
        indicator.setAnimating(true)
        #expect(indicator.animationIsRunning)
        root.isHidden = true
        #expect(indicator.animationRequested && !indicator.animationIsRunning)
        root.isHidden = false
        #expect(indicator.animationIsRunning)
        window.exposed = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!indicator.animationIsRunning)
        window.exposed = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(indicator.animationIsRunning)
        indicator.removeFromSuperview()
        #expect(indicator.animationRequested && !indicator.animationIsRunning)
        root.addSubview(indicator)
        #expect(indicator.animationIsRunning)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!indicator.animationIsRunning)
        indicator.setAnimating(false)
        root.isHidden = true
        root.isHidden = false
        #expect(!indicator.animationRequested && !indicator.animationIsRunning)
    }
}
