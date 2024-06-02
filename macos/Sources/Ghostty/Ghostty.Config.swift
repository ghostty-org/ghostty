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
            
            var errors: [String] = [];
            let errCount = ghostty_config_errors_count(cfg)
            for i in 0..<errCount {
                let err = ghostty_config_get_error(cfg, UInt32(i))
                let message = String(cString: err.message)
                errors.append(message)
            }
            
            return errors
        }
        
        init() {
            if let cfg = Self.loadConfig() {
                self.config = cfg
            }
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
            ghostty_config_load_cli_args(cfg);
            ghostty_config_load_recursive_files(cfg);
#endif
            
            // TODO: we'd probably do some config loading here... for now we'd
            // have to do this synchronously. When we support config updating we can do
            // this async and update later.
            
            // Finalize will make our defaults available.
            ghostty_config_finalize(cfg)
            
            // Log any configuration errors. These will be automatically shown in a
            // pop-up window too.
            let errCount = ghostty_config_errors_count(cfg)
            if errCount > 0 {
                logger.warning("config error: \(errCount) configuration errors on reload")
                var errors: [String] = [];
                for i in 0..<errCount {
                    let err = ghostty_config_get_error(cfg, UInt32(i))
                    let message = String(cString: err.message)
                    errors.append(message)
                    logger.warning("config error: \(message)")
                }
            }
            
            return cfg
        }
        
#if os(macOS)
        // MARK: - Keybindings
        
        /// A convenience struct that has the key + modifiers for some keybinding.
        struct KeyEquivalent: CustomStringConvertible {
            let key: String
            let modifiers: NSEvent.ModifierFlags
            
            var description: String {
                var key = self.key
                
                // Note: the order below matters; it matches the ordering modifiers
                // shown for macOS menu shortcut labels.
                if modifiers.contains(.command) { key = "⌘\(key)" }
                if modifiers.contains(.shift) { key = "⇧\(key)" }
                if modifiers.contains(.option) { key = "⌥\(key)" }
                if modifiers.contains(.control) { key = "⌃\(key)" }
                
                return key
            }
        }
        
        /// Return the key equivalent for the given action. The action is the name of the action
        /// in the Ghostty configuration. For example `keybind = cmd+q=quit` in Ghostty
        /// configuration would be "quit" action.
        ///
        /// Returns nil if there is no key equivalent for the given action.
        func keyEquivalent(for action: String) -> KeyEquivalent? {
            guard let cfg = self.config else { return nil }
            
            let trigger = ghostty_config_trigger(cfg, action, UInt(action.count))
            let equiv: String
            switch (trigger.tag) {
            case GHOSTTY_TRIGGER_TRANSLATED:
                if let v = Ghostty.keyEquivalent(key: trigger.key.translated) {
                    equiv = v
                } else {
                    return nil
                }
                
            case GHOSTTY_TRIGGER_PHYSICAL:
                if let v = Ghostty.keyEquivalent(key: trigger.key.physical) {
                    equiv = v
                } else {
                    return nil
                }
                
            case GHOSTTY_TRIGGER_UNICODE:
                equiv = String(trigger.key.unicode)
                
            default:
                return nil
            }
            
            return KeyEquivalent(
                key: equiv,
                modifiers: Ghostty.eventModifierFlags(mods: trigger.mods)
            )
        }
#endif
        
        // MARK: - Configuration Values
        
        /// For all of the configuration values below, see the associated Ghostty documentation for
        /// details on what each means. We only add documentation if there is a strange conversion
        /// due to the embedded library and Swift.
        
        var shouldQuitAfterLastWindowClosed: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "quit-after-last-window-closed"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }
        
        var windowColorspace: String {
            guard let config = self.config else { return "" }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-colorspace"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return "" }
            guard let ptr = v else { return "" }
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
        
        var windowNewTabPosition: String {
            guard let config = self.config else { return "" }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-new-tab-position"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return "" }
            guard let ptr = v else { return "" }
            return String(cString: ptr)
        }
        
        var windowDecorations: Bool {
            guard let config = self.config else { return true }
            var v = false;
            let key = "window-decoration"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v;
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

        var windowTitleFontFamily: String? {
            guard let config = self.config else { return nil }
            var v: UnsafePointer<Int8>? = nil
            let key = "window-title-font-family"
            guard ghostty_config_get(config, &v, key, UInt(key.count)) else { return nil }
            guard let ptr = v else { return nil }
            return String(cString: ptr)
        }

        var macosTitlebarTabs: Bool {
            guard let config = self.config else { return false }
            var v = false;
            let key = "macos-titlebar-tabs"
            _ = ghostty_config_get(config, &v, key, UInt(key.count))
            return v
        }
        
        var backgroundColor: Color {
            var rgb: UInt32 = 0
            let bg_key = "background"
            if (!ghostty_config_get(config, &rgb, bg_key, UInt(bg_key.count))) {
#if os(macOS)
                return Color(NSColor.windowBackgroundColor)
#elseif os(iOS)
                return Color(UIColor.systemBackground)
#else
#error("unsupported")
#endif
            }
            
            let red = Double(rgb & 0xff)
            let green = Double((rgb >> 8) & 0xff)
            let blue = Double((rgb >> 16) & 0xff)
            
            return Color(
                red: red / 255,
                green: green / 255,
                blue: blue / 255
            )
        }
        
        var backgroundOpacity: Double {
            guard let config = self.config else { return 1 }
            var v: Double = 1
            let key = "background-opacity"
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
            
            var rgb: UInt32 = 16777215  // white default
            let key = "unfocused-split-fill"
            if (!ghostty_config_get(config, &rgb, key, UInt(key.count))) {
                let bg_key = "background"
                _ = ghostty_config_get(config, &rgb, bg_key, UInt(bg_key.count));
            }
            
            let red = Double(rgb & 0xff)
            let green = Double((rgb >> 8) & 0xff)
            let blue = Double((rgb >> 16) & 0xff)
            
            return Color(
                red: red / 255,
                green: green / 255,
                blue: blue / 255
            )
        }
        
        // This isn't actually a configurable value currently but it could be done day.
        // We put it here because it is a color that changes depending on the configuration.
        var splitDividerColor: Color {
            let backgroundColor = OSColor(backgroundColor)
            let isLightBackground = backgroundColor.isLightColor
            let newColor = isLightBackground ? backgroundColor.darken(by: 0.08) : backgroundColor.darken(by: 0.4)
            return Color(newColor)
        }
    }
}
