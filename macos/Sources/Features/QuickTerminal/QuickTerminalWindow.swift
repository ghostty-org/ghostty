import Cocoa

class QuickTerminalWindow: NSPanel {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    /// Whether the window is using the decorated style (`.titled` with hidden titlebar).
    private var isDecorated = false

    override var contentView: NSView? {
        get { super.contentView }
        set {
            super.contentView = newValue
            if isDecorated {
                makeTitlebarTransparent()
            }
        }
    }

    override var contentLayoutRect: CGRect {
        if isDecorated {
            var rect = super.contentLayoutRect
            rect.origin.y = 0
            rect.size.height = self.frame.height
            return rect
        }
        return super.contentLayoutRect
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // Note: almost all of this stuff can be done in the nib/xib directly
        // but I prefer to do it programmatically because the properties we
        // care about are less hidden.
        
        // Add a custom identifier so third party apps can use the Accessibility
        // API to apply special rules to the quick terminal. 
        self.identifier = .init(rawValue: "com.mitchellh.ghostty.quickTerminal")
        
        // Set the correct AXSubrole of kAXFloatingWindowSubrole (allows
        // AeroSpace to treat the Quick Terminal as a floating window)
        self.setAccessibilitySubrole(.floatingWindow)

        // We don't want to activate the owning app when quick terminal is triggered.
        self.styleMask.insert(.nonactivatingPanel)
    }

    /// Configures window decoration for the quick terminal.
    ///
    /// When `decorated` is `true`, the window keeps the `.titled` style mask
    /// (from the nib) for native rounded corners, but hides the titlebar and
    /// window buttons. When `false`, the `.titled` mask is removed entirely,
    /// producing a borderless, square window (the legacy behavior).
    func applyDecoration(_ decorated: Bool) {
        if decorated {
            isDecorated = true
            styleMask.insert(.fullSizeContentView)
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            standardWindowButton(.closeButton)?.isHidden = true
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true

            makeTitlebarTransparent()
        } else {
            isDecorated = false
            styleMask.remove(.titled)
            contentView?.additionalSafeAreaInsets.top = 0
        }
    }

    /// Makes the titlebar area visually transparent so glass refracts through
    /// and no opaque gap is visible. We keep the `NSTitlebarContainerView`
    /// itself visible (preserving `safeAreaInsets.top` for the glass effect
    /// constraint) but strip its internal background layers — the same
    /// approach `TransparentTitlebarTerminalWindow` uses for the main window.
    ///
    /// Called from both `applyDecoration` and the `contentView` setter
    /// because replacing the content view can cause macOS to recreate
    /// titlebar background layers.
    private func makeTitlebarTransparent() {
        guard let themeFrame = contentView?.superview else { return }
        guard let titleBarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView") else { return }

        if #available(macOS 26.0, *) {
            // Tahoe: clear the NSTitlebarView layer and hide background view.
            if let titlebarView = titleBarContainer.firstDescendant(withClassName: "NSTitlebarView") {
                titlebarView.wantsLayer = true
                titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            titleBarContainer.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = true
        } else {
            // Ventura/Sonoma/Sequoia: clear the container layer and hide the
            // NSVisualEffectView that forces an opaque compositing layer.
            titleBarContainer.wantsLayer = true
            titleBarContainer.layer?.backgroundColor = NSColor.clear.cgColor
            if let effectView = titleBarContainer.descendants(withClassName: "NSVisualEffectView").first {
                effectView.isHidden = true
            }
        }

        // Negate the top safe area inset so SwiftUI content fills to the top.
        // We read from the themeFrame (not contentView) because its
        // safeAreaInsets.top is stable and unaffected by additionalSafeAreaInsets
        // on the contentView. The glass effect constraint in TerminalViewContainer
        // also reads themeFrame.safeAreaInsets.top, so the glass still extends
        // correctly into the titlebar area.
        let titlebarHeight = themeFrame.safeAreaInsets.top
        if titlebarHeight > 0 {
            contentView?.additionalSafeAreaInsets.top = -titlebarHeight
        }
    }

    // The quick terminal is always positioned programmatically by
    // QuickTerminalPosition, so we disable macOS's built-in frame
    // constraining. Without this, `.titled` windows cannot be placed
    // above the top edge of the screen, breaking the slide animation
    // for `position = top`.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// This is set to the frame prior to setting `contentView`. This is purely a hack to workaround
    /// bugs in older macOS versions (Ventura): https://github.com/ghostty-org/ghostty/pull/8026
    var initialFrame: NSRect? = nil
    
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        // Upon first adding this Window to its host view, older SwiftUI
        // seems to have a "hiccup" and corrupts the frameRect,
        // sometimes setting the size to zero, sometimes corrupting it.
        // If we find we have cached the "initial" frame, use that instead
        // the propagated one through the framework
        //
        // https://github.com/ghostty-org/ghostty/pull/8026
        super.setFrame(initialFrame ?? frameRect, display: flag)
    }
}
