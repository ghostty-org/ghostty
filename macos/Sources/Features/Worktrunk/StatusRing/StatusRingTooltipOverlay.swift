import SwiftUI

/// Root-level overlay that renders the status ring tooltip outside sidebar clipping bounds
struct StatusRingTooltipOverlay: View {
    @ObservedObject var state: StatusRingTooltipState

    var body: some View {
        GeometryReader { geometry in
            let globalFrame = geometry.frame(in: .global)
            if state.isVisible, let content = state.content {
                StatusRingPopover(
                    agentStatus: content.agentStatus,
                    prStatus: content.prStatus,
                    ciState: content.ciState
                )
                .fixedSize()
                .background(GeometryReader { tooltipGeo in
                    Color.clear.preference(
                        key: TooltipSizePreferenceKey.self,
                        value: tooltipGeo.size
                    )
                })
                .position(
                    tooltipPosition(
                        anchor: state.anchorRect,
                        overlayOrigin: globalFrame.origin,
                        overlaySize: geometry.size
                    )
                )
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.isVisible)
    }

    private func tooltipPosition(anchor: CGRect, overlayOrigin: CGPoint, overlaySize: CGSize) -> CGPoint {
        let spacing: CGFloat = 8
        let estimatedWidth: CGFloat = 240

        // Convert anchor from global screen coordinates to overlay's local coordinates
        // Subtract additional offset to correct for window chrome/titlebar
        let localX = anchor.minX - overlayOrigin.x - 50
        let localY = anchor.minY - overlayOrigin.y - 50

        // Position tooltip to the right of anchor, vertically centered
        var x = localX + anchor.width + spacing + estimatedWidth / 2
        let y = localY + anchor.height / 2

        // If tooltip would overflow right edge, flip to left
        if localX + anchor.width + spacing + estimatedWidth > overlaySize.width - 10 {
            x = localX - spacing - estimatedWidth / 2
        }

        // Clamp vertical position
        let clampedY = max(80, min(y, overlaySize.height - 80))

        return CGPoint(x: x, y: clampedY)
    }
}

private struct TooltipSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
