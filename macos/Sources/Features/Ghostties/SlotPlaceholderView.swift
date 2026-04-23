import SwiftUI

/// Empty slot in the "Active" zone. Visual capacity indicator — the
/// sidebar reserves `machineCap` slots and fills them with `TaskRowView`s
/// as tasks come online. Placeholders hold the positions so the zone never
/// resizes ( brief §4: spatial stability).
///
/// Height matches `TaskRowMetrics.compactHeight` so an active row replacing
/// a placeholder causes no vertical shift.
struct SlotPlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(
                Color.primary.opacity(0.13),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .frame(height: TaskRowMetrics.compactHeight - 8)
            .padding(.horizontal, TaskRowMetrics.horizontalPadding)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}
