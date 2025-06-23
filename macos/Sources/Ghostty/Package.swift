import os
import SwiftUI
import GhosttyKit

struct Ghostty {
    // The primary logger used by the GhosttyKit libraries.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ghostty"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}

    // The user notification category identifier
    static let userNotificationCategory = "com.mitchellh.ghostty.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.mitchellh.ghostty.userNotification.Show"
}

// MARK: C Extensions

/// A command is fully self-contained so it is Sendable.
extension ghostty_command_s: @unchecked @retroactive Sendable {}

/// A surface is sendable because it is just a reference type. Using the surface in parameters
/// may be unsafe but the value itself is safe to send across threads.
extension ghostty_surface_t: @unchecked @retroactive Sendable {}

// MARK: Build Info

extension Ghostty {
    struct Info {
        var mode: ghostty_build_mode_e
        var version: String
    }

    static var info: Info {
        let raw = ghostty_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: Swift Types for C Types

extension Ghostty {
    enum SetFloatWIndow {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_float_window_e) -> Self? {
            switch (c) {
            case GHOSTTY_FLOAT_WINDOW_ON:
                return .on

            case GHOSTTY_FLOAT_WINDOW_OFF:
                return .off

            case GHOSTTY_FLOAT_WINDOW_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    enum SetSecureInput {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_secure_input_e) -> Self? {
            switch (c) {
            case GHOSTTY_SECURE_INPUT_ON:
                return .on

            case GHOSTTY_SECURE_INPUT_OFF:
                return .off

            case GHOSTTY_SECURE_INPUT_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// Initialize from a Ghostty API enum.
        static func from(direction: ghostty_action_goto_split_e) -> Self? {
            switch (direction) {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS:
                return .previous

            case GHOSTTY_GOTO_SPLIT_NEXT:
                return .next

            case GHOSTTY_GOTO_SPLIT_UP:
                return .up

            case GHOSTTY_GOTO_SPLIT_DOWN:
                return .down

            case GHOSTTY_GOTO_SPLIT_LEFT:
                return .left

            case GHOSTTY_GOTO_SPLIT_RIGHT:
                return .right

            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_goto_split_e {
            switch (self) {
            case .previous:
                return GHOSTTY_GOTO_SPLIT_PREVIOUS

            case .next:
                return GHOSTTY_GOTO_SPLIT_NEXT

            case .up:
                return GHOSTTY_GOTO_SPLIT_UP

            case .down:
                return GHOSTTY_GOTO_SPLIT_DOWN

            case .left:
                return GHOSTTY_GOTO_SPLIT_LEFT

            case .right:
                return GHOSTTY_GOTO_SPLIT_RIGHT
            }
        }
    }

    /// Enum used for resizing splits. This is the direction the split divider will move.
    enum SplitResizeDirection {
        case up, down, left, right

        static func from(direction: ghostty_action_resize_split_direction_e) -> Self? {
            switch (direction) {
            case GHOSTTY_RESIZE_SPLIT_UP:
                return .up;
            case GHOSTTY_RESIZE_SPLIT_DOWN:
                return .down;
            case GHOSTTY_RESIZE_SPLIT_LEFT:
                return .left;
            case GHOSTTY_RESIZE_SPLIT_RIGHT:
                return .right;
            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_resize_split_direction_e {
            switch (self) {
            case .up:
                return GHOSTTY_RESIZE_SPLIT_UP;
            case .down:
                return GHOSTTY_RESIZE_SPLIT_DOWN;
            case .left:
                return GHOSTTY_RESIZE_SPLIT_LEFT;
            case .right:
                return GHOSTTY_RESIZE_SPLIT_RIGHT;
            }
        }
    }

    /// The type of a clipboard request
    enum ClipboardRequest {
        /// A direct paste of clipboard contents
        case paste

        /// An application is attempting to read from the clipboard using OSC 52
        case osc_52_read

        /// An application is attempting to write to the clipboard using OSC 52
        case osc_52_write(OSPasteboard?)

        /// The text to show in the clipboard confirmation prompt for a given request type
        func text() -> String {
            switch (self) {
            case .paste:
                return """
                Pasting this text to the terminal may be dangerous as it looks like some commands may be executed.
                """
            case .osc_52_read:
                return """
                An application is attempting to read from the clipboard.
                The current clipboard contents are shown below.
                """
            case .osc_52_write:
                return """
                An application is attempting to write to the clipboard.
                The content to write is shown below.
                """
            }
        }

        static func from(request: ghostty_clipboard_request_e) -> ClipboardRequest? {
            switch (request) {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                return .paste
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                return .osc_52_read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                return .osc_52_write(nil)
            default:
                return nil
            }
        }
    }

    /// macos-icon
    enum MacOSIcon: String {
        case official
        case blueprint
        case chalkboard
        case glass
        case holographic
        case microchip
        case paper
        case retro
        case xray
        case customStyle = "custom-style"
    }

    /// macos-icon-frame
    enum MacOSIconFrame: String {
        case aluminum
        case beige
        case plastic
        case chrome
    }

    /// Enum for the macos-window-buttons config option
    enum MacOSWindowButtons: String {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }

    /// Enum for auto-update-channel config option
    enum AutoUpdateChannel: String {
        case tip
        case stable
    }
}

// MARK: Surface Notification

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    static let ghosttyConfigDidChange = Notification.Name("com.mitchellh.ghostty.configDidChange")
    static let GhosttyConfigChangeKey = ghosttyConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    static let ghosttyColorDidChange = Notification.Name("com.mitchellh.ghostty.ghosttyColorDidChange")
    static let GhosttyColorChangeKey = ghosttyColorDidChange.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyMoveTab = Notification.Name("com.mitchellh.ghostty.moveTab")
    static let GhosttyMoveTabKey = ghosttyMoveTab.rawValue

    /// Close tab
    static let ghosttyCloseTab = Notification.Name("com.mitchellh.ghostty.closeTab")

    /// Close window
    static let ghosttyCloseWindow = Notification.Name("com.mitchellh.ghostty.closeWindow")

    /// Resize the window to a default size.
    static let ghosttyResetWindowSize = Notification.Name("com.mitchellh.ghostty.resetWindowSize")

    /// Ring the bell
    static let ghosttyBellDidRing = Notification.Name("com.mitchellh.ghostty.ghosttyBellDidRing")
    static let ghosttyCommandPaletteDidToggle = Notification.Name("com.mitchellh.ghostty.commandPaletteDidToggle")

    /// Toggle maximize of current window
    static let ghosttyMaximizeDidToggle = Notification.Name("com.mitchellh.ghostty.maximizeDidToggle")
}

// NOTE: I am moving all of these to Notification.Name extensions over time. This
// namespace was the old namespace.
extension Ghostty.Notification {
    /// Used to pass a configuration along when creating a new tab/window/split.
    static let NewSurfaceConfigKey = "com.mitchellh.ghostty.newSurfaceConfig"

    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let ghosttyNewSplit = Notification.Name("com.mitchellh.ghostty.newSplit")

    /// Close the calling surface.
    static let ghosttyCloseSurface = Notification.Name("com.mitchellh.ghostty.closeSurface")

    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let ghosttyFocusSplit = Notification.Name("com.mitchellh.ghostty.focusSplit")
    static let SplitDirectionKey = ghosttyFocusSplit.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyGotoTab = Notification.Name("com.mitchellh.ghostty.gotoTab")
    static let GotoTabKey = ghosttyGotoTab.rawValue

    /// New tab. Has base surface config requested in userinfo.
    static let ghosttyNewTab = Notification.Name("com.mitchellh.ghostty.newTab")

    /// New window. Has base surface config requested in userinfo.
    static let ghosttyNewWindow = Notification.Name("com.mitchellh.ghostty.newWindow")

    /// Toggle fullscreen of current window
    static let ghosttyToggleFullscreen = Notification.Name("com.mitchellh.ghostty.toggleFullscreen")
    static let FullscreenModeKey = ghosttyToggleFullscreen.rawValue

    /// Notification sent to toggle split maximize/unmaximize.
    static let didToggleSplitZoom = Notification.Name("com.mitchellh.ghostty.didToggleSplitZoom")

    /// Notification
    static let didReceiveInitialWindowFrame = Notification.Name("com.mitchellh.ghostty.didReceiveInitialWindowFrame")
    static let FrameKey = "com.mitchellh.ghostty.frame"

    /// Notification to render the inspector for a surface
    static let inspectorNeedsDisplay = Notification.Name("com.mitchellh.ghostty.inspectorNeedsDisplay")

    /// Notification to show/hide the inspector
    static let didControlInspector = Notification.Name("com.mitchellh.ghostty.didControlInspector")

    static let confirmClipboard = Notification.Name("com.mitchellh.ghostty.confirmClipboard")
    static let ConfirmClipboardStrKey = confirmClipboard.rawValue + ".str"
    static let ConfirmClipboardStateKey = confirmClipboard.rawValue + ".state"
    static let ConfirmClipboardRequestKey = confirmClipboard.rawValue + ".request"

    /// Notification sent to the active split view to resize the split.
    static let didResizeSplit = Notification.Name("com.mitchellh.ghostty.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification sent to the split root to equalize split sizes
    static let didEqualizeSplits = Notification.Name("com.mitchellh.ghostty.didEqualizeSplits")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("com.mitchellh.ghostty.didUpdateRendererHealth")

    /// Notifications related to key sequences
    static let didContinueKeySequence = Notification.Name("com.mitchellh.ghostty.didContinueKeySequence")
    static let didEndKeySequence = Notification.Name("com.mitchellh.ghostty.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"
}

// Make the input enum hashable.
extension ghostty_input_key_e : @retroactive Hashable {}
