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

    /// Every git repository at or under a project group's root.
    ///
    /// A project group's root is often a *workspace* — a plain folder that
    /// holds several repos side by side (`~/Projects/Aurora/aurora-backend`,
    /// `.../front-app-aurora`) — rather than a repo itself. Only tabs whose
    /// pwd happens to be open inside one of those repos showed up in the
    /// group's PR list before; a repo nobody has a tab open in didn't, even
    /// though it belongs to the group just as much.
    ///
    /// Bounded to a shallow walk (workspace / repo, or workspace / team /
    /// repo) so this stays a quick popover-open check rather than a real
    /// filesystem crawl, and stops descending the moment a repo is found —
    /// a discovered repo's own contents (which can be enormous) are never
    /// looked inside.
    nonisolated static func discoverRepoRoots(
        under root: String,
        maxDepth: Int = 2
    ) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)

        func isRepo(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent(".git").path)
        }

        func scan(_ url: URL, depth: Int) -> [String] {
            if isRepo(url) { return [url.path] }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            else { return [] }

            return entries.flatMap { entry -> [String] in
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return [] }
                return scan(entry, depth: depth + 1)
            }
        }

        return scan(rootURL, depth: 0)
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

    /// The accent for app controls, so a selection in settings is the same
    /// colour as a selection in the sidebar rather than the system's.
    var accent: Color? {
        primary.map { Color(nsColor: $0) }
    }

    /// Whether the theme reads as light, which decides whether app windows
    /// take light or dark chrome regardless of the system setting.
    var isLightBackground: Bool {
        background?.isLightColor ?? false
    }

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
