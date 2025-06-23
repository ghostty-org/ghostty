import SwiftUI
import GhosttyKit

extension Ghostty {
    /// Maps to a `ghostty_config_t` and the various operations on that.
    class Config: ObservableObject {
        // The underlying C pointer to the Ghostty config structure. This
        // should never be accessed directly. Any operations on this should
        // be called from the functions on this or another class.
        private(set) var config: ghostty_config_t? = nil {
            didSet {
                // Free the old value whenever we change
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        /// True if the configuration is loaded
        var loaded: Bool { config != nil }

        /// Return the errors found while loading the configuration.
        var errors: [String] {
            guard let cfg = self.config else { return [] }

            var diags: [String] = [];
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            for i in 0..<diagsCount {
                let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                let message = String(cString: diag.message)
                diags.append(message)
            }

            return diags
        }

        init() {
            if let cfg = Self.loadConfig() {
                self.config = cfg
            }
        }

        init(clone config: ghostty_config_t) {
            self.config = ghostty_config_clone(config)
        }

        deinit {
            self.config = nil
        }

        /// Initializes a new configuration and loads all the values.
        static private func loadConfig() -> ghostty_config_t? {
            // Initialize the global configuration.
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                return nil
            }

            // Load our configuration from files, CLI args, and then any referenced files.
            // We only do this on macOS because other Apple platforms do not have the
            // same filesystem concept.
#if os(macOS)
            ghostty_config_load_default_files(cfg);

            // We only load CLI args when not running in Xcode because in Xcode we
            // pass some special parameters to control the debugger.
            if !isRunningInXcode() {
                ghostty_config_load_cli_args(cfg);
            }

            ghostty_config_load_recursive_files(cfg);
#endif

            // TODO: we'd probably do some config loading here... for now we'd
            // have to do this synchronously. When we support config updating we can do
            // this async and update later.

            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)

            // Log any configuration errors. These will be automatically shown in a
            // pop-up window too.
            let diagsCount = ghostty_config_diagnostics_count(cfg)
            if diagsCount > 0 {
                logger.warning("config error: \(diagsCount) configuration errors on reload")
                var diags: [String] = [];
                for i in 0..<diagsCount {
                    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
                    let message = String(cString: diag.message)
                    diags.append(message)
                    logger.warning("config error: \(message)")
                }
            }

            return cfg
        }

#if os(macOS)
        // MARK: - Keybindings

        /// Return the key equivalent for the given action. The action is the name of the action
        /// in the Ghostty configuration. For example `keybind = cmd+q=quit` in Ghostty
        /// configuration would be "quit" action.
        ///
        /// Returns nil if there is no key equivalent for the given action.
        func keyboardShortcut(for action: String) -> KeyboardShortcut? {
            guard let cfg = self.config else { return nil }

            let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
            return Ghostty.keyboardShortcut(for: trigger)
        }
#endif

        // MARK: - Configuration Values

        /// For all of the configuration values below, see the associated Ghostty documentation for
        /// details on what each means. We only add documentation if there is a strange conversion
        /// due to the embedded library and Swift.

        var bellFeatures: BellFeatures {
            guard let config = self.config else { return .init() }
            var v: CUnsignedInt = 0
            let key = "bell-features"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .init() }
            return .init(rawValue: v)
        }

        var initialWindow: Bool {
            guard let config = self.config else { return true }
            var v = true;
            let key = "initial-window"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var shouldQuitAfterLastWindowClosed: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "quit-after-last-window-closed"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var title: String? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "title"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            return String(cString: ptr)
        }

        var windowSaveState: String {
            guard let config = self.config else { return "" }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-save-state"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return "" }
            guard let ptr = v else { return "" }
            return String(cString: ptr)
        }

        var windowPositionX: Int16? {
            guard let config = self.config else { return nil }
            var v: Int16 = 0
            let key = "window-position-x"
            return ghostty_config_get(config, &v, key, UInt(key.count)) ? v : nil
        }
        
        var windowPositionY: Int16? {
            guard let config = self.config else { return nil }
            var v: Int16 = 0
            let key = "window-position-y"
            return ghostty_config_get(config, &v, key, UInt(key.count)) ? v : nil
        }

        var windowNewTabPosition: String {
            guard let config = self.config else { return "" }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-new-tab-position"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return "" }
            guard let ptr = v else { return "" }
            return String(cString: ptr)
        }

        var windowDecorations: Bool {
            let defaultValue = true
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-decoration"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return WindowDecoration(rawValue: str)?.enabled() ?? defaultValue
        }

        var windowTheme: String? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-theme"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            return String(cString: ptr)
        }

        var windowStepResize: Bool {
            guard let config = self.config else { return true }
            var v = false
            let key = "window-step-resize"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var windowFullscreen: Bool {
            guard let config = self.config else { return true }
            var v = false
            let key = "fullscreen"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        #if canImport(AppKit)
        var windowFullscreenMode: FullscreenMode {
            let defaultValue: FullscreenMode = .native
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-non-native-fullscreen"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return switch str {
            case "false":
                    .native
            case "true":
                    .nonNative
            case "visible-menu":
                    .nonNativeVisibleMenu
            case "padded-notch":
                    .nonNativePaddedNotch
            default:
                defaultValue
            }
        }
        #endif

        var windowTitleFontFamily: String? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-title-font-family"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            return String(cString: ptr)
        }

        var macosWindowButtons: MacOSWindowButtons {
            let defaultValue = MacOSWindowButtons.visible
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-window-buttons"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return MacOSWindowButtons(rawValue: str) ?? defaultValue
        }

        var macosTitlebarStyle: String {
            let defaultValue = "transparent"
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-titlebar-style"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            return String(cString: ptr)
        }

        var macosTitlebarProxyIcon: MacOSTitlebarProxyIcon {
            let defaultValue = MacOSTitlebarProxyIcon.visible
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-titlebar-proxy-icon"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return MacOSTitlebarProxyIcon(rawValue: str) ?? defaultValue
        }

        var macosWindowShadow: Bool {
            guard let config = self.config else { return false }
            var v = false;
            let key = "macos-window-shadow"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var macosIcon: MacOSIcon {
            let defaultValue = MacOSIcon.official
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-icon"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return MacOSIcon(rawValue: str) ?? defaultValue
        }

        var macosIconFrame: MacOSIconFrame {
            let defaultValue = MacOSIconFrame.aluminum
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-icon-frame"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return MacOSIconFrame(rawValue: str) ?? defaultValue
        }

        var macosIconGhostColor: OSColor? {
            guard let config = self.config else { return nil }
            var v: ghostty_config_color_s = .init()
            let key = "macos-icon-ghost-color"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            return .init(ghostty: v)
        }

        var macosIconScreenColor: [OSColor]? {
            guard let config = self.config else { return nil }
            var v: ghostty_config_color_list_s = .init()
            let key = "macos-icon-screen-color"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard v.len > 0 else { return nil }
            let buffer = UnsafeBufferPointer(start: v.colors, count: v.len)
            return buffer.map { .init(ghostty: $0) }
        }

        var macosHidden: MacHidden {
            guard let config = self.config else { return .never }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-hidden"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .never }
            guard let ptr = v else { return .never }
            let str = String(cString: ptr)
            return MacHidden(rawValue: str) ?? .never
        }

        var focusFollowsMouse : Bool {
            guard let config = self.config else { return false }
            var v = false;
            let key = "focus-follows-mouse"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var backgroundColor: Color {
            var color: ghostty_config_color_s = .init();
            let bg_key = "background"
            if (!ghostty_config_get(config, &color, bg_key, UInt(bg_key.count))) {
#if os(macOS)
                return Color(NSColor.windowBackgroundColor)
#elseif os(iOS)
                return Color(UIColor.systemBackground)
#else
#error("unsupported")
#endif
            }

            return .init(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }

        var backgroundOpacity: Double {
            guard let config = self.config else { return 1 }
            var v: Double = 1
            let key = "background-opacity"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }

        var backgroundBlurRadius: Int {
            guard let config = self.config else { return 1 }
            var v: Int = 0
            let key = "background-blur"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }

        var unfocusedSplitOpacity: Double {
            guard let config = self.config else { return 1 }
            var opacity: Double = 0.85
            let key = "unfocused-split-opacity"
            _ = ghostty_config_get(config, &opacity, key, UInt(key.count))
            return 1 - opacity
        }

        var unfocusedSplitFill: Color {
            guard let config = self.config else { return .white }

            var color: ghostty_config_color_s = .init();
            let key = "unfocused-split-fill"
            if (!ghostty_config_get(config, &color, key, UInt(key.count))) {
                let bg_key = "background"
                _ = ghostty_config_get(config, &color, bg_key, UInt(bg_key.count));
            }

            return .init(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }

        var splitDividerColor: Color {
            let backgroundColor = OSColor(backgroundColor)
            let isLightBackground = backgroundColor.isLightColor
            let newColor = isLightBackground ? backgroundColor.darken(by: 0.08) : backgroundColor.darken(by: 0.4)

            guard let config = self.config else { return Color(newColor) }

            var color: ghostty_config_color_s = .init();
            let key = "split-divider-color"
            if (!ghostty_config_get(config, &color, key, UInt(key.count))) {
                return Color(newColor)
            }

            return .init(
                red: Double(color.r) / 255,
                green: Double(color.g) / 255,
                blue: Double(color.b) / 255
            )
        }

        #if canImport(AppKit)
        var quickTerminalPosition: QuickTerminalPosition {
            guard let config = self.config else { return .top }
            var v: UnsafePointer<Int8>? = nil
            let key = "quick-terminal-position"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .top }
            guard let ptr = v else { return .top }
            let str = String(cString: ptr)
            return QuickTerminalPosition(rawValue: str) ?? .top
        }

        var quickTerminalScreen: QuickTerminalScreen {
            guard let config = self.config else { return .main }
            var v: UnsafePointer<Int8>? = nil
            let key = "quick-terminal-screen"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .main }
            guard let ptr = v else { return .main }
            let str = String(cString: ptr)
            return QuickTerminalScreen(fromGhosttyConfig: str) ?? .main
        }

        var quickTerminalAnimationDuration: Double {
            guard let config = self.config else { return 0.2 }
            var v: Double = 0.2
            let key = "quick-terminal-animation-duration"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var quickTerminalAutoHide: Bool {
            guard let config = self.config else { return true }
            var v = true
            let key = "quick-terminal-autohide"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var quickTerminalSpaceBehavior: QuickTerminalSpaceBehavior {
            guard let config = self.config else { return .move }
            var v: UnsafePointer<Int8>? = nil
            let key = "quick-terminal-space-behavior"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .move }
            guard let ptr = v else { return .move }
            let str = String(cString: ptr)
            return QuickTerminalSpaceBehavior(fromGhosttyConfig: str) ?? .move
        }
        #endif

        var resizeOverlay: ResizeOverlay {
            guard let config = self.config else { return .after_first }
            var v: UnsafePointer<Int8>? = nil
            let key = "resize-overlay"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return .after_first }
            guard let ptr = v else { return .after_first }
            let str = String(cString: ptr)
            return ResizeOverlay(rawValue: str) ?? .after_first
        }

        var resizeOverlayPosition: ResizeOverlayPosition {
            let defaultValue = ResizeOverlayPosition.center
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "resize-overlay-position"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return ResizeOverlayPosition(rawValue: str) ?? defaultValue
        }

        var resizeOverlayDuration: UInt {
            guard let config = self.config else { return 1000 }
            var v: UInt = 0
            let key = "resize-overlay-duration"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
        }

        var undoTimeout: Duration {
            guard let config = self.config else { return .seconds(5) }
            var v: UInt = 0
            let key = "undo-timeout"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return .milliseconds(v)
        }

        var autoUpdate: AutoUpdate? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "auto-update"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            let str = String(cString: ptr)
            return AutoUpdate(rawValue: str)
        }

        var autoUpdateChannel: AutoUpdateChannel {
            let defaultValue = AutoUpdateChannel.stable
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "auto-update-channel"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return AutoUpdateChannel(rawValue: str) ?? defaultValue
        }

        var autoSecureInput: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "macos-auto-secure-input"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var secureInputIndication: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "macos-secure-input-indication"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var maximize: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "maximize"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }

        var macosShortcuts: MacShortcuts {
            let defaultValue = MacShortcuts.ask
            guard let config = self.config else { return defaultValue }
            var v: UnsafePointer<Int8>? = nil
            let key = "macos-shortcuts"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return defaultValue }
            guard let ptr = v else { return defaultValue }
            let str = String(cString: ptr)
            return MacShortcuts(rawValue: str) ?? defaultValue
        }
    }
}

// MARK: Configuration Enums

extension Ghostty.Config {
    enum AutoUpdate : String {
        case off
        case check
        case download
    }

    struct BellFeatures: OptionSet {
        let rawValue: CUnsignedInt

        static let system = BellFeatures(rawValue: 1 << 0)
        static let audio = BellFeatures(rawValue: 1 << 1)
        static let attention = BellFeatures(rawValue: 1 << 2)
        static let title = BellFeatures(rawValue: 1 << 3)
    }

    enum MacHidden : String {
        case never
        case always
    }

    enum MacShortcuts: String {
        case allow
        case deny
        case ask
    }

    enum ResizeOverlay : String {
        case always
        case never
        case after_first = "after-first"
    }

    enum ResizeOverlayPosition : String {
        case center
        case top_left = "top-left"
        case top_center = "top-center"
        case top_right = "top-right"
        case bottom_left = "bottom-left"
        case bottom_center = "bottom-center"
        case bottom_right = "bottom-right"

        func top() -> Bool {
            switch (self) {
            case .top_left, .top_center, .top_right: return true;
            default: return false;
            }
        }

        func bottom() -> Bool {
            switch (self) {
            case .bottom_left, .bottom_center, .bottom_right: return true;
            default: return false;
            }
        }

        func left() -> Bool {
            switch (self) {
            case .top_left, .bottom_left: return true;
            default: return false;
            }
        }

        func right() -> Bool {
            switch (self) {
            case .top_right, .bottom_right: return true;
            default: return false;
            }
        }
    }

    enum WindowDecoration: String {
        case none
        case client
        case server
        case auto

        func enabled() -> Bool {
            switch self {
            case .client, .server, .auto: return true
            case .none: return false
            }
        }
    }
}
