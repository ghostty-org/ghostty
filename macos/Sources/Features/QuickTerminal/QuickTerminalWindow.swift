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
