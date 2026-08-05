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

    /// A single emoji or an SF Symbol name. `SidebarGroupIcon` resolves
    /// which of the two it is at render time.
    var icon: String

    var color: TerminalTabColor
    var collapsed: Bool
    var kind: Kind

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        color: TerminalTabColor = .none,
        collapsed: Bool = false,
        kind: Kind = .manual
    ) {
        self.id = id
        self.name = name
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
}
