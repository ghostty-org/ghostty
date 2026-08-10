import AppKit
import SwiftUI

/// The row of open files above the editor.
///
/// Reuses `FileIconView` and the icon theme the explorer, the Git panel and
/// the terminal tabs already use, so a file looks the same everywhere it
/// appears.
struct EditorTabBar: View {
    let tabs: [EditorTab]
    let selection: EditorSelection
    let needsDirectory: (EditorTab) -> Bool
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    /// The title of the terminal this pane belongs to, for its own tab.
    let terminalTitle: String
    let onSelectTerminal: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    /// How tall a tab is, and how much room is left under it for the
    /// scroller. Named because three places have to agree on them: the row,
    /// the scroll view around it, and the inset the terminal below is pushed
    /// down by.
    static let tabHeight: CGFloat = 30
    static let scrollerStrip: CGFloat = 8

    static var height: CGFloat { tabHeight + scrollerStrip }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // First, always, and not closable: the pane belongs to the
                // terminal, and the files are guests in it. A close button
                // here would offer to remove the thing that owns the window.
                TerminalTabItem(
                    title: terminalTitle,
                    isSelected: selection == .terminal,
                    onSelect: onSelectTerminal
                )

                ForEach(tabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        isSelected: selection == .file(tab.id),
                        showsDirectory: needsDirectory(tab),
                        onSelect: { onSelect(tab.id) },
                        onClose: { onClose(tab.id) }
                    )
                }

                // Overlay, not legacy. With "show scroll bars: always" in
                // System Settings a legacy scroller is permanent and claims a
                // strip of layout for itself, and there was no such strip —
                // so it was drawn clipped, over the bottom edge of the bar and
                // the rule under it. Overlay draws thin, over the content, and
                // fades when the scrolling stops.
                OverlayScrollers()

                // Wheel down scrolls the row sideways, because reaching for a
                // tab off the right edge with a mouse otherwise means a
                // horizontal gesture nobody has on a wheel.
                WheelScrollsHorizontally()
            }
            .frame(height: Self.tabHeight)
            // No `Spacer` here on purpose: a spacer stretches the row to the
            // viewport's width, so the content never overflows and a scroll
            // view with nothing to overflow does not scroll. The row is as
            // wide as its tabs; the background behind it fills the rest.
        }
        // Visible while scrolling, not never: with enough tabs to fill the
        // bar there was no way to reach the rest and nothing to say they were
        // there. `.never` hid the only affordance the row had.
        .scrollIndicators(.automatic)
        // Taller than the tabs by exactly the strip the overlay scroller
        // needs. Two things come out of that gap: the scroller stops being
        // drawn over the tab labels and over the rule at the bottom of the
        // bar, and the row stops being *vertically* scrollable — content
        // taller than its viewport is what made a wheel event scroll a few
        // invisible points up and down instead of moving the tabs.
        .frame(height: Self.tabHeight + Self.scrollerStrip)
    }
}

/// The terminal's own tab.
///
/// Deliberately not an `EditorTabItem` with a fake path: it has no dirty
/// dot, no close button and no directory to disambiguate, and modelling it
/// as a file would mean every rule in there growing a special case.
private struct TerminalTabItem: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 11))

                Text(title)
                    .font(palette.font(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isSelected ? accent.opacity(0.18) : (isHovered ? Color.secondary.opacity(0.10) : .clear))
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(accent).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(title)
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
        // The I-beam has to be pushed back explicitly: it belongs to the
        // text view underneath, and AppKit keeps it while the pointer is
        // over a SwiftUI view that never says otherwise — so a tab looked
        // like something to select text in rather than something to click.
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
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
