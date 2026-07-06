import Cocoa

struct ScreenBoundsSnapshot: Equatable {
    let displayUUID: UUID?
    let frame: NSRect
    let visibleFrame: NSRect
    let topInset: CGFloat

    init(_ screen: NSScreen) {
        self.init(
            displayUUID: screen.displayUUID,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            topInset: max(NSApp.mainMenu?.menuBarHeight ?? 0, screen.safeAreaInsets.top))
    }

    init(
        displayUUID: UUID? = nil,
        frame: NSRect,
        visibleFrame: NSRect,
        topInset: CGFloat
    ) {
        self.displayUUID = displayUUID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.topInset = topInset
    }

    func stableVisibleFrame(
        dockOrientation: DockOrientation? = Dock.orientation
    ) -> NSRect {
        NSScreen.normalizeVisibleFrame(
            frame: frame,
            visibleFrame: visibleFrame,
            topInset: topInset,
            dockOrientation: dockOrientation,
            includeDock: true)
    }

    func isDockVisibleFrameChange(
        comparedTo previous: Self,
        dockOrientation: DockOrientation? = Dock.orientation
    ) -> Bool {
        guard displayUUID == previous.displayUUID else { return false }
        guard frame == previous.frame else { return false }
        guard visibleFrame != previous.visibleFrame else { return false }

        return stableVisibleFrame(dockOrientation: dockOrientation) ==
            previous.stableVisibleFrame(dockOrientation: dockOrientation)
    }

    func isTransientVisibleFrameChange(
        comparedTo previous: Self,
        dockAutohides: Bool,
        dockOrientation: DockOrientation? = Dock.orientation
    ) -> Bool {
        dockAutohides && isDockVisibleFrameChange(
            comparedTo: previous,
            dockOrientation: dockOrientation)
    }
}

extension NSRect {
    func approximatelyEqual(to other: NSRect, tolerance: CGFloat = 1) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}

extension NSScreen {
    static var dockAutohides: Bool {
        if let dockAutohide = UserDefaults.ghostty
            .persistentDomain(forName: "com.apple.dock")?["autohide"] as? Bool
        {
            return dockAutohide
        }

        return Dock.autoHideEnabled
    }

    static func normalizeVisibleFrame(
        frame: NSRect,
        visibleFrame: NSRect,
        topInset: CGFloat,
        dockOrientation: DockOrientation?,
        includeDock: Bool
    ) -> NSRect {
        guard includeDock else { return visibleFrame }

        let leftInset = max(0, visibleFrame.minX - frame.minX)
        let rightInset = max(0, frame.maxX - visibleFrame.maxX)
        let bottomInset = max(0, visibleFrame.minY - frame.minY)
        let topDockInset = max(0, frame.maxY - visibleFrame.maxY - topInset)

        let effectiveOrientation: DockOrientation? = dockOrientation ?? {
            if bottomInset > 0 { return .bottom }
            if leftInset > 0 { return .left }
            if rightInset > 0 { return .right }
            if topDockInset > 0 { return .top }
            return nil
        }()

        var rect = visibleFrame
        switch effectiveOrientation {
        case .bottom:
            guard bottomInset > 0 else { return rect }
            rect.origin.y = frame.minY
            rect.size.height += bottomInset
        case .left:
            guard leftInset > 0 else { return rect }
            rect.origin.x = frame.minX
            rect.size.width += leftInset
        case .right:
            guard rightInset > 0 else { return rect }
            rect.size.width += rightInset
        case .top:
            guard topDockInset > 0 else { return rect }
            rect.size.height += topDockInset
        case nil:
            break
        }

        return rect
    }

    var visibleFrameIgnoringHiddenDock: NSRect {
        Self.normalizeVisibleFrame(
            frame: frame,
            visibleFrame: visibleFrame,
            topInset: max(NSApp.mainMenu?.menuBarHeight ?? 0, safeAreaInsets.top),
            dockOrientation: Dock.orientation,
            includeDock: Self.dockAutohides)
    }

    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    /// The stable UUID for this display, suitable for tracking across reconnects and NSScreen garbage collection.
    var displayUUID: UUID? {
        guard let displayID = displayID else { return nil }
        guard let cfuuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return UUID(cfuuid)
    }

    // Returns true if the given screen has a visible dock. This isn't
    // point-in-time visible, this is true if the dock is always visible
    // AND present on this screen.
    var hasDock: Bool {
        // If the dock autohides then we don't have a dock ever.
        if Self.dockAutohides { return false }

        // There is no public API to directly ask about dock visibility, so we have to figure it out
        // by comparing the sizes of visibleFrame (the currently usable area of the screen) and
        // frame (the full screen size). We also need to account for the menubar, any inset caused
        // by the notch on macbooks, and a little extra padding to compensate for the boundary area
        // which triggers showing the dock.

        // If our visible width is less than the frame we assume its the dock.
        if visibleFrame.width < frame.width {
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
