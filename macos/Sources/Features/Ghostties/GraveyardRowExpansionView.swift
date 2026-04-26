import SwiftUI

/// Inline expansion panel that appears below a Graveyard row when it is tapped.
///
/// Renders:
/// - Frontmatter chips (source + id, project, relative time)
/// - 1 px divider
/// - First ≤8 lines of the task body, hard-clipped (no fade gradient — D spec)
///
/// D20: no terracotta. Read-only; no action buttons.
/// D26: flat layout — lives directly under `macos/Sources/Features/Ghostties/`.
///
/// Animation grammar (D18 / D19):
/// - Panel reveal: 180ms cubic ease; panel hide: 140ms ease-in.
/// - Reduced-motion: height/translate animations instant; opacity fades 80ms.
struct GraveyardRowExpansionView: View {

    let content: GraveyardExpansionContent

    /// True when reduced-motion accessibility preference is on (D19).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chips
            chipRow

            // Divider
            Divider()
                .overlay(Color.white.opacity(0.14))
                .padding(.vertical, 8)

            // Body preview
            bodyPreview
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.04))
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity.combined(with: .move(edge: .top))
            )
        )
    }

    // MARK: - Chips

    private var chipRow: some View {
        HStack(spacing: 0) {
            FlowLayout(spacing: 6) {
                chip(content.sourceChip)
                chip(content.projectChip)
                chip(content.timeChip)
            }
        }
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    // MARK: - Body preview

    @ViewBuilder
    private var bodyPreview: some View {
        if content.isBodyEmpty {
            Text("No notes.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.28))
        } else {
            // Hard-clip at 8 lines (no fade gradient per D spec: "terminal-honest").
            // Belt-and-suspenders max-height for long single-line wraps.
            Text(content.bodyPreview)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineSpacing(2.5)  // achieves ~16px line-height at 10.5pt
                .lineLimit(8)
                .frame(maxWidth: .infinity, maxHeight: 128, alignment: .topLeading)
                .clipped()
        }
    }
}

// MARK: - FlowLayout

/// Minimal horizontal wrapping layout for the chip row.
/// Wraps chips to a new line when they overflow the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                totalHeight = y
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        _ = maxWidth // suppress unused-variable warning
    }
}
