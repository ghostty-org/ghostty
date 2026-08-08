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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarPane.allCases) { pane in
                tab(for: pane)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func tab(for pane: SidebarPane) -> some View {
        let isSelected = selection == pane

        return Button {
            guard selection != pane else { return }
            withAnimation(.easeOut(duration: 0.12)) { selection = pane }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pane.icon)
                    .font(.system(size: 10, weight: .medium))
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
