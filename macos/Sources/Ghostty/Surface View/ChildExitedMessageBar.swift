import SwiftUI

struct ChildExitedMessageBar: View {
    let msg: Ghostty.ChildExitedMessage
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(msg.level.backgroundStyle)
        .foregroundColor(msg.level.foregroundColor)
        .contentShape(.rect)
        .accessibilityLabel(msg.text)
        .transition(.move(edge: .bottom))
        .opacity(isHovered ? 0 : 1)
        .allowsHitTesting(false)
        .overlay {
            Color.clear
                .onHover {
                    isHovered = $0
                }
        }
    }

    private var message: AttributedString {
        (try? AttributedString(markdown: msg.text)) ?? AttributedString(msg.text)
    }
}

private extension Ghostty.ChildExitedMessage.Level {
    var foregroundColor: Color {
        .primary
    }

    var backgroundStyle: AnyShapeStyle {
        switch self {
        case .success:
            AnyShapeStyle(.background)
        case .error:
            AnyShapeStyle(.red.opacity(0.5))
        }
    }
}
