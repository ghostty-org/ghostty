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
/// Every pane paints the same colour in every mode, which is what keeps
/// the surface seamless. The system glass material was a third mode until
/// it proved it can't do that: it is applied per-view, so the sidebar and
/// the terminal each got their own and the boundary between them always
/// showed. "Glass" in the settings is the blurred background above.
///
/// The window-level treatment itself is applied by
/// `TerminalWindow.syncAppearance`; the divider by `SidebarSplitView`.
@MainActor
enum AppearanceCoordinator {
    enum BlurStyle {
        case off
        case radius(Int)

        init(configValue: String?) {
            switch configValue ?? "false" {
            case "false", "", "0":
                self = .off
            case "true", "macos-glass-regular", "macos-glass-clear":
                // The glass values are legacy: the system material was an
                // option until it turned out it can't span the two panes
                // without a seam. They read as a blurred background now.
                self = .radius(20)
            case let raw:
                if let value = Int(raw), value > 0 {
                    self = .radius(value)
                } else {
                    self = .off
                }
            }
        }
    }

    static var blurStyle: BlurStyle {
        BlurStyle(configValue: GuiConfigStore.shared.string("background-blur"))
    }

    /// The layer color the sidebar pane paints: the theme's effective
    /// background, which is what the terminal paints too — the two match by
    /// construction, in every effect.
    static func sidebarLayerColor(window: TerminalWindow?) -> NSColor? {
        window?.preferredBackgroundColor
    }
}
