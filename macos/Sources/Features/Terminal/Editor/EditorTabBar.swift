import SwiftUI

/// The row of open files above the editor.
///
/// Reuses `FileIconView` and the icon theme the explorer, the Git panel and
/// the terminal tabs already use, so a file looks the same everywhere it
/// appears.
struct EditorTabBar: View {
    let tabs: [EditorTab]
    let selection: String?
    let needsDirectory: (EditorTab) -> Bool
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        isSelected: tab.id == selection,
                        showsDirectory: needsDirectory(tab),
                        onSelect: { onSelect(tab.id) },
                        onClose: { onClose(tab.id) }
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .scrollIndicators(.never)
        .frame(height: 30)
    }
}

private struct EditorTabItem: View {
    let tab: EditorTab
    let isSelected: Bool
    let showsDirectory: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        HStack(spacing: 5) {
            FileIconView(icon: icons.icon(forFile: tab.name), size: 13)

            Text(tab.name)
                .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            if showsDirectory {
                Text((tab.directory as NSString).lastPathComponent)
                    .font(palette.font(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            closeControl
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isSelected ? accent.opacity(0.18) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(accent)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(tab.path)
    }

    /// A dot for unsaved changes that becomes the close button on hover —
    /// the VS Code behavior, which keeps one slot doing both jobs instead
    /// of widening every tab to fit two.
    @ViewBuilder
    private var closeControl: some View {
        if tab.isDirty && !isHovered {
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)
        } else {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    )
            }
            .buttonStyle(.plain)
            .opacity(isHovered || tab.isDirty ? 1 : 0.35)
        }
    }
}
