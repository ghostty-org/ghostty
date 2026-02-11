import Cocoa

class QuickTerminalWindow: NSPanel {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

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

        // Remove the title completely. This will make the window square. One
        // downside is it also hides the cursor indications of resize but the
        // window remains resizable.
        self.styleMask.remove(.titled)

        // We don't want to activate the owning app when quick terminal is triggered.
        self.styleMask.insert(.nonactivatingPanel)
    }

    /// When set, any setFrame call from SwiftUI layout will have its size
    /// replaced with this locked size. This prevents SwiftUI's NSHostingView
    /// from corrupting the window dimensions during content setup and animation.
    /// The origin is still allowed to change (for animation positioning).
    ///
    /// This is especially important when initial-window=false because the quick
    /// terminal is the first window in the process and SwiftUI's initial layout
    /// can be more aggressive about resizing.
    var lockedSize: NSSize? = nil

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if let lockedSize {
            // Allow origin changes but enforce the locked size. This lets
            // animation positioning work while preventing SwiftUI from
            // corrupting the window dimensions.
            super.setFrame(NSRect(origin: frameRect.origin, size: lockedSize), display: flag)
        } else {
            super.setFrame(frameRect, display: flag)
        }
    }
}
