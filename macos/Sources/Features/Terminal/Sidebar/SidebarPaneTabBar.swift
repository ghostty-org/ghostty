import SwiftUI

/// The panel switcher at the top of the sidebar.
///
/// Deliberately draws no opaque background of its own. The sidebar pane's
/// color comes from an AppKit layer *behind* the SwiftUI content
/// (`TerminalController.syncSidebarBackground`), and every pane in the
/// window paints that same color so the sidebar↔terminal boundary stays
/// seamless under transparency and blur. An opaque strip here would put a
/// visible band back at the top of the sidebar.
struct SidebarPaneTabBar: View {
    @Binding var selection: SidebarPane

    @ObservedObject private var palette: ThemePalette = .shared

    private var accent: Color { palette.accent ?? .accentColor }

    /// Which panels to offer. Owned by `SidebarView`, which also decides
    /// whether this bar appears at all.
    let panes: [SidebarPane]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(panes) { pane in
                tab(for: pane)
            }

            if DevelopmentBuild.isActive {
                developmentBadge
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Marks a locally built copy.
    ///
    /// Here rather than in the title bar because this strip is present in
    /// every panel and every window style, and because the title already
    /// carries the folder — the one thing a reader looks at it for. It
    /// takes its own width instead of stretching, so the three tabs keep
    /// the space they had.
    private var developmentBadge: some View {
        Text(DevelopmentBuild.label)
            .font(palette.font(size: 9, weight: .bold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.orange.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
            .help("This is a local development build, not the installed app.")
            .accessibilityLabel("Development build")
    }

    private func tab(for pane: SidebarPane) -> some View {
        let isSelected = selection == pane

        return Button {
            guard selection != pane else { return }
            withAnimation(.easeOut(duration: 0.12)) { selection = pane }
        } label: {
            HStack(spacing: 5) {
                SidebarPaneIcon(pane: pane)
                Text(pane.title)
                    .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? accent.opacity(0.22) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent)
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pane.title)
    }
}
