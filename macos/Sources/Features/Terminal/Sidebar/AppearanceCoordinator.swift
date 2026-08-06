import AppKit

/// Single source of truth for how every pane paints its background.
///
/// Style state lives in three places (the ghostty config via
/// GuiConfigStore, the current theme, and sidebar defaults); this
/// coordinator is the only component that combines them, so each pane
/// asks for its treatment instead of deciding locally.
///
/// The resolution map:
///
///     blur = off / radius, opacity = 1
///       window: solid effective background
///       terminal: theme background (opaque)
///       sidebar: theme → effective background; window → nothing;
///                custom → tint color at tint opacity
///
///     blur = off / radius, opacity < 1
///       window: near-transparent (CGS blur when radius), desktop shows
///       terminal: theme background at opacity (Metal)
///       sidebar: same rules as above — theme mode mirrors the terminal
///
///     blur = glass (regular)
///       window: glass material tinted with the effective background
///       terminal: transparent, glass shows through
///       sidebar: ALWAYS nothing — the tinted glass is the shared
///                background, painting anything on top breaks the pane
///                uniformity (custom tint is still honored)
///
///     blur = glass (clear)
///       window: colorless glass
///       terminal & sidebar: same as glass regular, without tint
///
/// The window-level treatment itself is applied by
/// `TerminalWindow.syncAppearance`; the divider by `SidebarSplitView`.
@MainActor
enum AppearanceCoordinator {
    enum BlurStyle {
        case off
        case radius(Int)
        case glassRegular
        case glassClear

        init(configValue: String?) {
            switch configValue ?? "false" {
            case "false", "", "0":
                self = .off
            case "true":
                self = .radius(20)
            case "macos-glass-regular":
                self = .glassRegular
            case "macos-glass-clear":
                self = .glassClear
            case let raw:
                if let value = Int(raw), value > 0 {
                    self = .radius(value)
                } else {
                    self = .off
                }
            }
        }

        var isGlass: Bool {
            switch self {
            case .glassRegular, .glassClear: return true
            default: return false
            }
        }
    }

    static var blurStyle: BlurStyle {
        BlurStyle(configValue: GuiConfigStore.shared.string("background-blur"))
    }

    /// The layer color the sidebar pane should paint, per the map above.
    /// `window` supplies the live effective background (theme or
    /// override, at the configured opacity).
    static func sidebarLayerColor(window: TerminalWindow?) -> NSColor? {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "SidebarBackgroundMode") ?? "theme"

        if mode == "custom" {
            let opacity = defaults.double(forKey: "SidebarTintOpacity")
            guard opacity > 0.001,
                  let hex = defaults.string(forKey: "SidebarTintHex"),
                  let color = NSColor(hex: hex)
            else { return nil }
            return color.withAlphaComponent(opacity)
        }

        // Under glass the window carries the (tinted) background for
        // every pane; any extra layer breaks the uniform look.
        if blurStyle.isGlass { return nil }

        switch mode {
        case "window":
            return nil
        default:
            return window?.preferredBackgroundColor
        }
    }
}
