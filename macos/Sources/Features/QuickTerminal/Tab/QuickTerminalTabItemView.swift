import SwiftUI

struct QuickTerminalTabItemView: View {
    @ObservedObject var tab: QuickTerminalTab

    let isHighlighted: Bool
    let isGlassEnabled: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let shortcut: KeyboardShortcut?

    @State private var isHovering = false
    @State private var isHoveringCloseButton = false

    private var backgroundColor: Color {
        if isGlassEnabled {
            if isHighlighted {
                Color.white.opacity(0.28)
            } else if isHovering {
                Color.white.opacity(0.18)
            } else {
                Color.white.opacity(0.05)
            }
        } else {
            if isHighlighted {
                Color.white.opacity(0.15)
            } else if isHovering {
                Color(NSColor.underPageBackgroundColor)
            } else {
                Color(NSColor.controlBackgroundColor)
            }
        }
    }

    private var closeButtonBackgroundColor: Color {
        if isGlassEnabled {
            if isHoveringCloseButton {
                Color.white.opacity(0.3)
            } else {
                backgroundColor
            }
        } else {
            if isHoveringCloseButton {
                Color(NSColor.unemphasizedSelectedContentBackgroundColor)
            } else {
                backgroundColor
            }
        }
    }

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
                .foregroundColor(isHovering ? .primary : .secondary)
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
        Text(tab.title)
            .foregroundColor(isHighlighted ? .primary : .secondary)
            .lineLimit(Constants.titleLineLimit)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    @ViewBuilder private func renderShortcut(_ shortcut: KeyboardShortcut) -> some View {
        Text(shortcut.description)
            .font(.system(size: Constants.shortcutFontSize))
            .foregroundColor(isHighlighted ? .primary : .secondary)
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
