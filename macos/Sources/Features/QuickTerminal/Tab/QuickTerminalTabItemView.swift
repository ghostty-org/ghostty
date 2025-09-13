import SwiftUI

struct QuickTerminalTabItemView: View {
    @ObservedObject var tab: QuickTerminalTab

    let isHighlighted: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    private var backgroundColor: Color {
        if isHighlighted {
            Color(NSColor.controlBackgroundColor)
        } else if isHovered {
            Color(NSColor.underPageBackgroundColor)
        } else {
            Color(NSColor.windowBackgroundColor)
        }
    }

    var body: some View {
        HStack(spacing: Constants.horizontalSpacing) {
            renderCloseButton()
            renderTitle()
        }
        .padding(.horizontal, Constants.horizontalPadding)
        .frame(height: Constants.height)
        .background(
            Rectangle()
                .fill(backgroundColor)
        )
        .onHover { isHovered in
            self.isHovered = isHovered
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
                .foregroundColor(isHovered ? .primary : .secondary)
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut, value: isHovered)
    }

    @ViewBuilder private func renderTitle() -> some View {
        Text(tab.title)
            .foregroundColor(isHighlighted ? .primary : .secondary)
            .lineLimit(Constants.titleLineLimit)
            .truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}

extension QuickTerminalTabItemView {
    enum Constants {
        static let height: CGFloat = 32
        static let horizontalSpacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let closeButtonFontSize: CGFloat = 11
        static let titleLineLimit: Int = 1
    }
}
