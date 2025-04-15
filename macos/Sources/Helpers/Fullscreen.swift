import Cocoa
import GhosttyKit

/// The fullscreen modes we support define how the fullscreen behaves.
enum FullscreenMode {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch

    /// Initializes the fullscreen style implementation for the mode. This will not toggle any
    /// fullscreen properties. This may fail if the window isn't configured properly for a given
    /// mode.
    func style(for window: NSWindow) -> FullscreenStyle? {
        switch self {
        case .native:
            return NativeFullscreen(window)

        case .nonNative:
            return NonNativeFullscreen(window)

        case  .nonNativeVisibleMenu:
            return NonNativeFullscreenVisibleMenu(window)

        case .nonNativePaddedNotch:
            return NonNativeFullscreenPaddedNotch(window)
        }
    }
}

/// Protocol that must be implemented by all fullscreen styles.
protocol FullscreenStyle {
    var delegate: FullscreenDelegate? { get set }
    var isFullscreen: Bool { get }
    var supportsTabs: Bool { get }
    init?(_ window: NSWindow)
    func enter()
    func exit()
}

/// Delegate that can be implemented for fullscreen implementations.
protocol FullscreenDelegate: AnyObject {
    /// Called whenever the fullscreen state changed. You can call isFullscreen to see
    /// the current state.
    func fullscreenDidChange()
}

extension FullscreenDelegate {
    func fullscreenDidChange() {}
}

/// The base class for fullscreen implementations, cannot be used as a FullscreenStyle on its own.
class FullscreenBase {
    let window: NSWindow
    weak var delegate: FullscreenDelegate?

    required init?(_ window: NSWindow) {
        self.window = window

        // We want to trigger delegate methods on window native fullscreen
        // changes (didEnterFullScreenNotification, etc.) no matter what our
        // fullscreen style is.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didEnterFullScreenNotification),
            name: NSWindow.didEnterFullScreenNotification,
            object: window)
        center.addObserver(
            self,
            selector: #selector(didExitFullScreenNotification),
            name: NSWindow.didExitFullScreenNotification,
            object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didEnterFullScreenNotification(_ notification: Notification) {
        delegate?.fullscreenDidChange()
    }

    @objc private func didExitFullScreenNotification(_ notification: Notification) {
        delegate?.fullscreenDidChange()
    }
}

/// macOS native fullscreen. This is the typical behavior you get by pressing the green fullscreen
/// button on regular titlebars.
class NativeFullscreen: FullscreenBase, FullscreenStyle {
    var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }
    var supportsTabs: Bool { true }

    required init?(_ window: NSWindow) {
        // TODO: There are many requirements for native fullscreen we should
        // check here such as the stylemask.
        super.init(window)
    }

    func enter() {
        guard !isFullscreen else { return }

        // The titlebar separator shows up erroneously in fullscreen if the tab bar
        // is made to appear and then disappear by opening and then closing a tab.
        // We get rid of the separator while in fullscreen to prevent this.
        window.titlebarSeparatorStyle = .none

        // Enter fullscreen
        window.toggleFullScreen(self)

        // Note: we don't call our delegate here because the base class
        // will always trigger the delegate on native fullscreen notifications
        // and we don't want to double notify.
    }

    func exit() {
        guard isFullscreen else { return }

        // Restore titlebar separator style. See enter for explanation.
        window.titlebarSeparatorStyle = .automatic

        window.toggleFullScreen(nil)

        // Note: we don't call our delegate here because the base class
        // will always trigger the delegate on native fullscreen notifications
        // and we don't want to double notify.
    }
}

class NonNativeFullscreen: FullscreenBase, FullscreenStyle {
    // Non-native fullscreen never supports tabs because tabs require
    // the "titled" style and we don't have it for non-native fullscreen.
    var supportsTabs: Bool { false }

    // isFullscreen is dependent on if we have saved state currently. We
    // could one day try to do fancier stuff like inspecting the window
    // state but there isn't currently a need for it.
    var isFullscreen: Bool { savedState != nil }

    // The default properties. Subclasses can override this to change
    // behavior. This shouldn't be written to (only computed) because
    // it must be immutable.
    var properties: Properties { Properties() }

    struct Properties {
        var hideMenu: Bool = true
        var paddedNotch: Bool = false
    }

    private var savedState: SavedState?

    func enter() {
        // If we are in fullscreen we don't do it again.
        guard !isFullscreen else { return }

        // If we are in native fullscreen, exit native fullscreen. This is counter
        // intuitive but if we entered native fullscreen (through the green max button
        // or an external event) and we press the fullscreen keybind, we probably
        // want to EXIT fullscreen.
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }

        // This is the screen that we're going to go fullscreen on. We use the
        // screen the window is currently on.
        guard let screen = window.screen else { return }

        // Save the state that we need to exit again
        guard let savedState = SavedState(window) else { return }
        self.savedState = savedState

        // We hide the dock if the window is on a screen with the dock.
        // We must hide the dock FIRST then hide the menu:
        // If you specify autoHideMenuBar, it must be accompanied by either hideDock or autoHideDock.
        // https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct
        if (savedState.dock) {
            hideDock()
        }

        // Hide the menu if requested
        if (properties.hideMenu && savedState.menu) {
            hideMenu()
        }

        // When we change screens we need to redo everything.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: window)

        // Being untitled let's our content take up the full frame.
        window.styleMask.remove(.titled)

        // We dont' want the non-native fullscreen window to be resizable
        // from the edges.
        window.styleMask.remove(.resizable)

        // Focus window
        window.makeKeyAndOrderFront(nil)

        // Set frame to screen size, accounting for any elements such as the menu bar.
        // We do this async so that all the style edits above (title removal, dock
        // hide, menu hide, etc.) take effect. This fixes:
        // https://github.com/ghostty-org/ghostty/issues/1996
        DispatchQueue.main.async {
            self.window.setFrame(self.fullscreenFrame(screen), display: true)
            self.delegate?.fullscreenDidChange()
        }
    }

    func exit() {
        guard isFullscreen else { return }
        guard let savedState else { return }

        // Remove all our notifications. We remove them one by one because
        // we don't want to remove the observers that our superclass sets.
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)

        // Unhide our elements
        if savedState.dock {
            unhideDock()
        }
        if (properties.hideMenu && savedState.menu) {
            unhideMenu()
        }

        // Restore our saved state
        window.styleMask = savedState.styleMask
        window.setFrame(window.frameRect(forContentRect: savedState.contentFrame), display: true)

        // This is a hack that I want to remove from this but for now, we need to
        // fix up the titlebar tabs here before we do everything below.
        if let window = window as? TerminalWindow,
           window.titlebarTabs {
            window.titlebarTabs = true
        }

        // If the window was previously in a tab group that isn't empty now,
        // we re-add it. We have to do this because our process of doing non-native
        // fullscreen removes the window from the tab group.
        if let tabGroup = savedState.tabGroup,
           let tabIndex = savedState.tabGroupIndex,
            !tabGroup.windows.isEmpty {
            if tabIndex == 0 {
                // We were previously the first tab. Add it before ("below")
                // the first window in the tab group currently.
                tabGroup.windows.first!.addTabbedWindow(window, ordered: .below)
            } else if tabIndex <= tabGroup.windows.count {
                // We were somewhere in the middle
                tabGroup.windows[tabIndex - 1].addTabbedWindow(window, ordered: .above)
            } else {
                // We were at the end
                tabGroup.windows.last!.addTabbedWindow(window, ordered: .below)
            }
        }

        // Unset our saved state, we're restored!
        self.savedState = nil

        // Focus window
        window.makeKeyAndOrderFront(nil)

        // Notify the delegate
        self.delegate?.fullscreenDidChange()
    }

    private func fullscreenFrame(_ screen: NSScreen) -> NSRect {
        // It would make more sense to use "visibleFrame" but visibleFrame
        // will omit space by our dock and isn't updated until an event
        // loop tick which we don't have time for. So we use frame and
        // calculate this ourselves.
        var frame = screen.frame

        if (!NSApp.presentationOptions.contains(.autoHideMenuBar) &&
            !NSApp.presentationOptions.contains(.hideMenuBar)) {
            // We need to subtract the menu height since we're still showing it.
            frame.size.height -= NSApp.mainMenu?.menuBarHeight ?? 0

            // NOTE on macOS bugs: macOS used to have a bug where menuBarHeight
            // didn't account for the notch. I reported this as a radar and it
            // was fixed at some point. I don't know when that was so I can't
            // put an #available check, but it was in a bug fix release so I think
            // if a bug is reported to Ghostty we can just advise the user to
            // update.
        } else if (properties.paddedNotch) {
            // We are hiding the menu, we may need to avoid the notch.
            frame.size.height -= screen.safeAreaInsets.top
        }

        return frame
    }

    // MARK: Window Events

    @objc func windowDidChangeScreen(_ notification: Notification) {
        guard isFullscreen else { return }
        guard let savedState else { return }

        // This should always be true due to how we register but just be sure
        guard let object = notification.object as? NSWindow,
              object == window else { return }

        // Our screens must have changed
        guard savedState.screenID != window.screen?.displayID else { return }

        // When we change screens, we simply exit fullscreen. Changing
        // screens shouldn't naturally be possible, it can only happen
        // through external window managers. There's a lot of accounting
        // to do to get the screen change right so instead of breaking
        // we just exit out. The user can re-enter fullscreen thereafter.
        exit()
    }

    // MARK: Dock

    private func hideDock() {
        NSApp.acquirePresentationOption(.autoHideDock)
    }

    private func unhideDock() {
        NSApp.releasePresentationOption(.autoHideDock)
    }

    // MARK: Menu

    func hideMenu() {
        NSApp.acquirePresentationOption(.autoHideMenuBar)
    }

    func unhideMenu() {
        NSApp.releasePresentationOption(.autoHideMenuBar)
    }

    /// The state that must be saved for non-native fullscreen to exit fullscreen.
    class SavedState {
        let screenID: UInt32?
        let tabGroup: NSWindowTabGroup?
        let tabGroupIndex: Int?
        let contentFrame: NSRect
        let styleMask: NSWindow.StyleMask
        let dock: Bool
        let menu: Bool

        init?(_ window: NSWindow) {
            guard let contentView = window.contentView else { return nil }

            self.screenID = window.screen?.displayID
            self.tabGroup = window.tabGroup
            self.tabGroupIndex = window.tabGroup?.windows.firstIndex(of: window)
            self.contentFrame = window.convertToScreen(contentView.frame)
            self.styleMask = window.styleMask
            self.dock = window.screen?.hasDock ?? false

            // We hide the menu only if this window is not on any fullscreen
            // spaces. We do this because fullscreen spaces already hide the
            // menu and if we insert/remove this presentation option we get
            // issues (see #7075)
            let activeSpace = CGSSpace.active()
            let spaces = CGSSpace.list(for: window.cgWindowId)
            if spaces.contains(activeSpace) {
                self.menu = activeSpace.type != .fullscreen
            } else {
                self.menu = spaces.allSatisfy { $0.type != .fullscreen }
            }
        }
    }
}

class NonNativeFullscreenVisibleMenu: NonNativeFullscreen {
    override var properties: Properties { Properties(hideMenu: false) }
}

class NonNativeFullscreenPaddedNotch: NonNativeFullscreen {
    override var properties: Properties { Properties(paddedNotch: true) }
}
