import SwiftUI

/// The two top-level views the sidebar can display.
///
/// Stored in `@AppStorage("ghostties.sidebarTab")` so the selection persists
/// across launches. Conforms to `String` so `@AppStorage` can read/write it
/// directly (SwiftUI supports `RawRepresentable` enums with `String` raw values).
enum SidebarTab: String {
    case projects
    case sessions
}

/// Compact two-segment tab picker that sits in the sidebar titlebar row.
///
/// Renders as a lozenge with two icon+label buttons. The selected segment gets
/// a subtle filled background; unselected buttons use a muted foreground.
/// Height is intentionally small so it fits within the traffic-light toolbar row.
struct SidebarTabPicker: View {
    @Binding var selectedTab: SidebarTab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(.projects, icon: "square.grid.2x2", label: "Projects")
            tabButton(.sessions, icon: "clock", label: "Sessions")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func tabButton(_ tab: SidebarTab, icon: String, label: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedTab == tab ? Color.primary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selectedTab == tab ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
#Preview("SidebarTabPicker") {
    VStack(spacing: 16) {
        StatefulPreviewWrapper(SidebarTab.projects) { tab in
            SidebarTabPicker(selectedTab: tab)
        }
        StatefulPreviewWrapper(SidebarTab.sessions) { tab in
            SidebarTabPicker(selectedTab: tab)
        }
    }
    .padding(24)
    .preferredColorScheme(.dark)
}

/// Thin wrapper so previews can own mutable state for a `@Binding`.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initialValue: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self._value = State(initialValue: initialValue)
        self.content = content
    }

    var body: some View { content($value) }
}
#endif
