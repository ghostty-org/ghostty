import AppKit

final class NativeSettingsCanvas: NSView {
    var background: NSColor? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        (background ?? window?.backgroundColor ?? .windowBackgroundColor).setFill()
        bounds.intersection(dirtyRect).fill()
    }
}
