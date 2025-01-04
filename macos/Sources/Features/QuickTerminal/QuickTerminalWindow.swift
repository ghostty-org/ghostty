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

        // We need to set our window level to a high value. In testing, only
        // popUpMenu and above do what we want. This gets it above the menu bar
        // and lets us render off screen.
        self.level = .popUpMenu

        // This plus the level above was what was needed for the animation to work,
        // because it gets the window off screen properly. Plus we add some fields
        // we just want the behavior of.
        self.collectionBehavior = [
            // We want this to be part of every space because it is a singleton.
            .canJoinAllSpaces,

            // We don't want to be part of command-tilde
            .ignoresCycle,

            // We want to show the window on another space if it is visible
            .fullScreenAuxiliary]
    }
}
