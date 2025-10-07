import Cocoa

extension NSScreen {
    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    // Returns true if the given screen has a visible dock. This isn't
    // point-in-time visible, this is true if the dock is always visible
    // AND present on this screen.
    var hasDock: Bool {
        // If the dock autohides then we don't have a dock ever.
        if let dockAutohide = UserDefaults.standard.persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool {
            if (dockAutohide) { return false }
        }

        // There is no public API to directly ask about dock visibility, so we have to figure it out
        // by comparing the sizes of visibleFrame (the currently usable area of the screen) and
        // frame (the full screen size). We also need to account for the menubar, any inset caused
        // by the notch on macbooks, and a little extra padding to compensate for the boundary area
        // which triggers showing the dock.

        // If our visible width is less than the frame we assume its the dock.
        if (visibleFrame.width < frame.width) {
            return true
        }

        // We need to see if our visible frame height is less than the full
        // screen height minus the menu and notch and such.
        let menuHeight = NSApp.mainMenu?.menuBarHeight ?? 0
        let notchInset: CGFloat = safeAreaInsets.top
        let boundaryAreaPadding = 5.0

        return visibleFrame.height < (frame.height - max(menuHeight, notchInset) - boundaryAreaPadding)
    }

    /// Returns true if the screen has a visible notch (i.e., a non-zero safe area inset at the top).
    var hasNotch: Bool {
        // We assume that a top safe area means notch, since we don't currently
        // know any other situation this is true.
        return safeAreaInsets.top > 0
    }
    
    /// Converts top-left offset coordinates to bottom-left origin coordinates for window positioning.
    /// - Parameters:
    ///   - x: X offset from top-left corner
    ///   - y: Y offset from top-left corner  
    ///   - windowSize: Size of the window to be positioned
    /// - Returns: CGPoint suitable for setFrameOrigin that positions the window as requested
    func origin(fromTopLeftOffsetX x: CGFloat, offsetY y: CGFloat, windowSize: CGSize) -> CGPoint {
        let vf = visibleFrame
        
        // Convert top-left coordinates to bottom-left origin
        let originX = vf.minX + x
        let originY = vf.maxY - y - windowSize.height
        
        return CGPoint(x: originX, y: originY)
    }
}
