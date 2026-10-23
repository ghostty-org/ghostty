import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TabSidebarCellViewTests {
    /// A click only reaches the close button if hit testing finds it where it is drawn.
    /// Short titles stretch the accessory stack, which used to leave the button outside of
    /// the trailing slot it lives in, so clicks on it went to the row instead.
    @Test(arguments: [false, true], ["zsh", String(repeating: "x", count: 80)])
    func closeButtonReceivesClicks(isZoomed: Bool, title: String) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        let contentView = try #require(window.contentView)

        let cell = TabSidebarCellView(frame: contentView.bounds)
        cell.autoresizingMask = [.width, .height]
        contentView.addSubview(cell)

        cell.configure(with: TabSidebarRowContent(title: title, subtitle: "~", shortcut: "⌘1", isZoomed: isZoomed))
        cell.isHovered = true
        contentView.layoutSubtreeIfNeeded()

        let button = try #require(Self.closeButton(in: cell))
        #expect(!button.isHidden)

        // `hitTest` takes the point in the coordinate system of the superview.
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let point = contentView.superview?.convert(center, from: nil) ?? center
        #expect(contentView.hitTest(point) === button)
    }

    private static func closeButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "TabSidebarCloseButton" {
            return button
        }

        for subview in view.subviews {
            if let button = closeButton(in: subview) { return button }
        }

        return nil
    }
}
