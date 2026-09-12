import SwiftUI

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        @Environment(\.appearsActive) var appearsActive
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        @Binding var split: CGFloat

        @State private var isHovered = false
        private let visibleHoverScale: CGFloat = 3

        private var visibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        private var visibleScale: CGSize {
            let identity = CGSize(width: 1, height: 1)
            guard isHovered else {
                return identity
            }
            switch direction {
            case .horizontal:
                return appearsActive ? CGSize(width: visibleHoverScale, height: identity.height) : identity
            case .vertical:
                return appearsActive ? CGSize(width: identity.width, height: visibleHoverScale) : identity
            }
        }

        private var pointerStyle: BackportPointerStyle {
            return switch direction {
            case .horizontal: .resizeLeftRight
            case .vertical: .resizeUpDown
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle()) // Makes it hit testable for pointerStyle
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
                    .scaleEffect(visibleScale)
            }
            .backport.pointerStyle(pointerStyle)
            .animation(.interactiveSpring, value: isHovered && appearsActive)
            .onHover { isHovered in
                self.isHovered = isHovered
                // macOS 15+ we use the pointerStyle helper which is much less
                // error-prone versus manual NSCursor push/pop
                if #available(macOS 15, *) {
                    return
                }

                if isHovered {
                    switch direction {
                    case .horizontal:
                        NSCursor.resizeLeftRight.push()
                    case .vertical:
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 0.025
                switch direction {
                case .increment:
                    split = min(split + adjustment, 0.9)
                case .decrement:
                    split = max(split - adjustment, 0.1)
                @unknown default:
                    break
                }
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return "Horizontal split divider"
            case .vertical:
                return "Vertical split divider"
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return "Drag to resize the left and right panes"
            case .vertical:
                return "Drag to resize the top and bottom panes"
            }
        }
    }
}
