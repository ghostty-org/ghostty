// Public API facade for the GhosttyRuntime module.
// This exposes only the types needed by the GhosttyDemo target.

import AppKit
import SwiftUI
import Combine
import GhosttyKit

// Re-export GhosttyKit so consumers get ghostty_app_t etc.
@_exported import struct GhosttyKit.ghostty_app_t

public final class GhosttyApp: ObservableObject {
    private let inner: Ghostty.App

    public init(configPath: String? = nil) {
        inner = Ghostty.App(configPath: configPath)
    }

    public var app: ghostty_app_t? { inner.app }

    // Forward ObservableObject
    public let objectWillChange = ObservableObjectPublisher()
}

public final class GhosttySurfaceView: NSView, ObservableObject {
    private let inner: Ghostty.SurfaceView
    private let scrollView: SurfaceScrollView

    @Published public private(set) var title: String = ""

    private var titleCancellable: Any?

    public init(_ app: ghostty_app_t) {
        inner = Ghostty.SurfaceView(app)
        // Use the same SurfaceScrollView wrapper that Ghostty uses internally
        scrollView = SurfaceScrollView(contentSize: CGSize(width: 800, height: 600), surfaceView: inner)
        super.init(frame: .zero)
        addSubview(scrollView)
        scrollView.autoresizingMask = [.width, .height]
        // Forward title changes
        titleCancellable = inner.$title.sink { [weak self] newTitle in
            self?.title = newTitle
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    public func sendText(_ text: String) {
        inner.surfaceModel?.sendText(text)
    }

    /// Send a synthetic Enter key press via the key event path.
    /// Unlike sendText("\n"), this goes through key encoding (not paste),
    /// so it works correctly with bracketed paste mode enabled.
    public func sendEnter() {
        let event = Ghostty.Input.KeyEvent(key: .enter, action: .press)
        inner.surfaceModel?.sendKeyEvent(event)
    }

    /// The underlying ghostty surface for this view.
    public var surface: ghostty_surface_t? {
        inner.surface
    }

    /// The inner NSView that can become first responder.
    /// Used by TerminalTabManager to transfer focus when switching tabs.
    public var surfaceNSView: NSView { inner }

    /// Notify the surface of focus changes.
    /// Used to pause/resume cursor blinking and release secure input.
    public func focusDidChange(_ focused: Bool) {
        inner.focusDidChange(focused)
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        // Update the surface size when layout changes
        inner.sizeDidChange(bounds.size)
    }
}
