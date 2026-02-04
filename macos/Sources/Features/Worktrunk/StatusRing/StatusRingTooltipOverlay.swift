import SwiftUI

/// Root-level overlay that renders the status ring tooltip outside sidebar clipping bounds
struct StatusRingTooltipOverlay: View {
    @ObservedObject var state: StatusRingTooltipState

    var body: some View {
        GeometryReader { geometry in
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
                        windowBounds: geometry.frame(in: .global)
                    )
                )
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.isVisible)
    }

    private func tooltipPosition(anchor: CGRect, windowBounds: CGRect) -> CGPoint {
        let spacing: CGFloat = 8
        let estimatedWidth: CGFloat = 240  // Reasonable estimate for tooltip width

        // Default: right of anchor, vertically centered
        var x = anchor.maxX + spacing + estimatedWidth / 2
        let y = anchor.midY

        // If tooltip would overflow right edge, flip to left
        if anchor.maxX + spacing + estimatedWidth > windowBounds.maxX - 10 {
            x = anchor.minX - spacing - estimatedWidth / 2
        }

        // Clamp vertical position to stay within window
        let clampedY = max(80, min(y, windowBounds.maxY - 80))

        return CGPoint(x: x, y: clampedY)
    }
}

private struct TooltipSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
