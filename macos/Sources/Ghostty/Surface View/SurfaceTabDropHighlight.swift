import AppKit

extension Ghostty {
    /// Outlines the titlebar of the window a dragged surface would become a
    /// tab in. The outline is a click-through child window so the titlebar's
    /// own views are never touched.
    final class SurfaceTabDropHighlight {
        private(set) var target: NSWindow?
        private var tabSelection: NSKeyValueObservation?

        private lazy var overlay: NSWindow = {
            let overlay = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            overlay.isReleasedWhenClosed = false
            overlay.ignoresMouseEvents = true
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false

            let box = NSBox()
            box.boxType = .custom
            box.titlePosition = .noTitle
            box.cornerRadius = 8
            box.borderWidth = 2
            box.borderColor = .controlAccentColor
            box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.2)
            overlay.contentView = box
            return overlay
        }()

        func show(over window: NSWindow) {
            let frame = window.titlebarFrame.insetBy(dx: 4, dy: 3)
            if overlay.frame != frame {
                overlay.setFrame(frame, display: true)
            }

            guard target !== window else { return }
            hide()
            window.addChildWindow(overlay, ordered: .above)
            target = window

            // Holding a drag over a native tab switches to that tab, which
            // orders this window out along with the outline. Follow the switch.
            tabSelection = window.tabGroup?.observe(\.selectedWindow) { [weak self] group, _ in
                guard let selected = group.selectedWindow else { return }
                DispatchQueue.main.async {
                    guard let self, self.target != nil else { return }
                    self.show(over: selected)
                }
            }
        }

        func hide() {
            guard let target else { return }
            tabSelection = nil
            target.removeChildWindow(overlay)
            overlay.orderOut(nil)
            self.target = nil
        }
    }
}
