import Cocoa

/// Floating NSPanel for popup terminals.
/// Created programmatically — no XIB needed.
class PopupWindow: NSPanel {
    let profileName: String

    /// True when this popup corresponds to the built-in "quick" profile.
    var isQuickProfile: Bool { profileName == PopupManager.quickProfileName }

    init(profileName: String, contentRect: NSRect) {
        self.profileName = profileName
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Remove titlebar chrome but keep .titled for native rounded corners,
        // then add nonactivatingPanel so showing the popup doesn't steal focus.
        styleMask.insert(.nonactivatingPanel)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Hide the traffic light buttons (close/minimize/zoom)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Accessibility: give the window a unique identifier and the correct
        // floating-window subrole so tools like AeroSpace can handle it.
        identifier = NSUserInterfaceItemIdentifier(
            "com.mitchellh.ghostty.popup.\(profileName)"
        )
        setAccessibilitySubrole(.floatingWindow)

        // Panel behavior: float above normal windows, stay visible when the
        // app deactivates, and allow dragging by the background.
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        level = .floating
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Both overrides are required so a panel without a title bar can still
    // receive keyboard events and act as the key/main window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
