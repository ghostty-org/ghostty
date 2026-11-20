import SwiftUI

struct QuickTerminalTabItemView: View {
    @ObservedObject var tab: QuickTerminalTab

    let isHighlighted: Bool
    let isGlassEnabled: Bool
    /// The active Ghostty config, used to format the title (bell prefix etc.)
    /// via `QuickTerminalController.computeTitle` — the same rule the window
    /// title uses for regular terminals.
    let config: Ghostty.Config
    /// Passed in from the bar so we can reset hover state when the tab list
    /// changes — SwiftUI sometimes drops the `.onHover` exit when a tab
    /// shifts out from under the cursor during an insertion/removal, which
    /// leaves the previously-hovered tab's close button stuck visible.
    let tabsCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    let shortcut: KeyboardShortcut?

    private var displayTitle: String {
        QuickTerminalController.computeTitle(title: tab.title, bell: tab.surfaceBell, config: config)
    }

    @State private var isHovering = false
    @State private var isHoveringCloseButton = false

    private var surfaceColor: NSColor {
        tab.backgroundColor.map { NSColor($0) } ?? .windowBackgroundColor
    }

    private var surfaceOpacity: Double {
        tab.backgroundOpacity
    }

    /// Color to blend the surface color toward when dimming or highlighting.
    private var contrastColor: NSColor {
        surfaceColor.isLightColor ? .black : .white
    }

    private func tinted(by fraction: CGFloat, opacity: Double = 1) -> Color {
        let blended = surfaceColor.blended(withFraction: fraction, of: contrastColor) ?? surfaceColor
        return Color(blended).opacity(opacity)
    }

    /// Extra opacity applied to inactive states when glass is enabled so the
    /// glass effect bleeds through behind the tab bar. Kept high enough that
    /// the tint isn't washed out by the glass — especially on light themes.
    private var inactiveGlassOpacity: Double { isGlassEnabled ? 0.85 : 1 }

    /// How far to blend the surface color toward the contrast color for
    /// inactive/hover states. Glass needs a heavier tint since the glass
    /// effect behind the tab dilutes the result.
    private var hoverTint: CGFloat { isGlassEnabled ? 0.30 : 0.20 }
    private var inactiveTint: CGFloat { isGlassEnabled ? 0.55 : 0.35 }

    private var backgroundColor: Color {
        if isHighlighted { return Color(surfaceColor).opacity(surfaceOpacity) }
        let opacity = surfaceOpacity * inactiveGlassOpacity
        if isHovering { return tinted(by: hoverTint, opacity: opacity) }
        return tinted(by: inactiveTint, opacity: opacity)
    }

    private var closeButtonBackgroundColor: Color {
        isHoveringCloseButton ? tinted(by: 0.45) : backgroundColor
    }

    private var primaryForeground: Color { Color(contrastColor) }
    private var secondaryForeground: Color { primaryForeground.opacity(0.6) }

    var body: some View {
        HStack(spacing: Constants.horizontalSpacing) {
            renderCloseButton()
            renderTitle()
            renderColorIndicator()
            if let shortcut = shortcut {
                renderShortcut(shortcut)
            }
        }
        .padding(.horizontal, Constants.horizontalPadding)
        .frame(height: Constants.height)
        .frame(minWidth: Constants.minWidth, maxWidth: .infinity)
        .background(
            Rectangle()
                .fill(backgroundColor)
                .onMiddleClick(perform: onClose)
        )
        .onHover { isHovering in
            self.isHovering = isHovering
        }
        .onChange(of: tabsCount) { _ in
            // SwiftUI sometimes drops the `.onHover` exit when a tab shifts
            // out from under the cursor during an insertion/removal, leaving
            // the close button stuck visible. Force a reset; if the cursor
            // really is over this tab the next mouse move will restore it.
            isHovering = false
            isHoveringCloseButton = false
        }
        .onTapGesture {
            DispatchQueue.main.async {
                onSelect()
            }
        }
    }

    @ViewBuilder private func renderCloseButton() -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: Constants.closeButtonFontSize))
                .foregroundColor(isHovering ? primaryForeground : secondaryForeground)
                .padding(Constants.closeButtonPadding)
        }
        .buttonStyle(PlainButtonStyle())
        .background(
            RoundedRectangle(cornerSize: Constants.closeButtonCornerRadius)
                .fill(closeButtonBackgroundColor)
        )
        .onHover { isHoveringCloseButton in
            self.isHoveringCloseButton = isHoveringCloseButton
        }
        .help("Click to close this tab; Option-click to close all tabs except this one")
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut, value: isHovering)
    }

    @ViewBuilder private func renderColorIndicator() -> some View {
        if let color = tab.tabColor.displayColor {
            Circle()
                .fill(Color(color))
                .frame(width: Constants.colorIndicatorSize, height: Constants.colorIndicatorSize)
        }
    }

    @ViewBuilder private func renderTitle() -> some View {
        Text(displayTitle)
            .foregroundColor(isHighlighted ? primaryForeground : secondaryForeground)
            .lineLimit(Constants.titleLineLimit)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    @ViewBuilder private func renderShortcut(_ shortcut: KeyboardShortcut) -> some View {
        Text(shortcut.description)
            .font(.system(size: Constants.shortcutFontSize))
            .foregroundColor(isHighlighted ? primaryForeground : secondaryForeground)
            .opacity(0.7)
    }
}

extension QuickTerminalTabItemView {
    enum Constants {
        static let minWidth: CGFloat = 180
        static let height: CGFloat = 24
        static let horizontalSpacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let closeButtonPadding: CGFloat = 2
        static let closeButtonCornerRadius: CGSize = .init(width: 4, height: 4)
        static let closeButtonFontSize: CGFloat = 10
        static let shortcutFontSize: CGFloat = 11
        static let colorIndicatorSize: CGFloat = 6
        static let titleLineLimit: Int = 1
    }
}
