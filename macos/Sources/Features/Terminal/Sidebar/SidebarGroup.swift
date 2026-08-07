import AppKit
import SwiftUI

/// A group of tabs shown as a section in the sidebar.
///
/// Groups come in two kinds: manual groups the user creates and assigns
/// tabs to freely, and project groups that automatically claim any tab
/// whose working directory lives under the project root.
struct SidebarGroup: Identifiable, Codable, Equatable {
    /// How tabs become members of a group.
    enum Kind: Codable, Equatable {
        /// Tabs are assigned explicitly by the user.
        case manual

        /// Tabs whose pwd is inside `root` belong to this group.
        case project(root: String)
    }

    let id: UUID
    var name: String

    /// Optional secondary line rendered under the name in the header.
    var details: String?

    /// A single emoji or an SF Symbol name. `SidebarGroupIcon` resolves
    /// which of the two it is at render time.
    var icon: String

    var color: TerminalTabColor

    /// A theme-palette (or otherwise custom) color; wins over `color`.
    var colorHex: String?

    var collapsed: Bool
    var kind: Kind

    /// The effective accent: custom hex first, then the preset color.
    var accentColor: Color? {
        if let colorHex, let nsColor = NSColor(hex: colorHex) {
            return Color(nsColor: nsColor)
        }
        return color.sidebarAccent
    }

    init(
        id: UUID = UUID(),
        name: String,
        details: String? = nil,
        icon: String = "folder",
        color: TerminalTabColor = .none,
        collapsed: Bool = false,
        kind: Kind = .manual
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.icon = icon
        self.color = color
        self.collapsed = collapsed
        self.kind = kind
    }

    /// Whether a tab with the given pwd is claimed by this group's project rule.
    func claims(pwd: String?) -> Bool {
        guard case .project(let root) = kind else { return false }
        guard let pwd, !pwd.isEmpty else { return false }
        let normalizedRoot = (root as NSString).expandingTildeInPath
        return pwd == normalizedRoot || pwd.hasPrefix(normalizedRoot + "/")
    }
}

/// Resolves a group icon string into a SwiftUI view: a single-grapheme
/// non-ASCII string renders as emoji text, anything else as an SF Symbol.
struct SidebarGroupIcon: View {
    let icon: String
    var size: CGFloat = 12

    private var isEmoji: Bool {
        icon.count == 1 && !(icon.unicodeScalars.first?.isASCII ?? true)
    }

    var body: some View {
        if isEmoji {
            Text(icon)
                .font(.system(size: size))
        } else {
            Image(systemName: icon.isEmpty ? "folder" : icon)
                .font(.system(size: size - 1, weight: .medium))
        }
    }
}

extension TerminalTabColor {
    /// The group accent color for sidebar tinting, nil when `.none`.
    var sidebarAccent: Color? {
        guard let nsColor = displayColor else { return nil }
        return Color(nsColor: nsColor)
    }

    /// A small filled-circle swatch for menu rows, where SF Symbols
    /// render as templates and lose their tint.
    var menuSwatch: NSImage {
        Self.menuSwatch(for: displayColor)
    }

    static func menuSwatch(for color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The current theme's palette, shared app-wide so color pickers can
/// offer theme colors next to the preset ones. Reloads whenever the
/// GUI settings apply (theme switches, config reloads).
@MainActor
final class ThemePalette: ObservableObject {
    static let shared = ThemePalette()

    @Published private(set) var colors: [NSColor] = []
    @Published private(set) var background: NSColor?

    /// The theme's primary/accent swatch — ANSI index 4 (Blue) by
    /// convention, matching the accent already used in theme previews.
    var primary: NSColor? { colors.count > 4 ? colors[4] : nil }

    static let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]

    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: GuiConfigStore.didApply,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        let store = GuiConfigStore.shared
        guard let url = store.currentThemeURL,
              let theme = ThemeCatalog.parse(url: url, source: .user)
        else {
            colors = []
            background = nil
            return
        }

        colors = (0..<16).compactMap { theme.palette[$0] }
        background = theme.background
    }
}
