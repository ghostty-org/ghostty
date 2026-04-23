import SwiftUI

/// Monitor zone — "Active". Middle of the sidebar, expands to fill
/// available space.
///
/// Renders one compact `TaskRowView` per running task, then fills the
/// remaining slots up to `taskStore.machineCap` with `SlotPlaceholderView`.
/// Total slot count stays constant so the zone never resizes as agents come
/// and go (brief §4: spatial stability).
///
/// The "machine ok" hint in the header is hardcoded for v0; a later revision
/// will read thermal state / pressure and drive the color.
struct ActiveZoneView: View {
    @ObservedObject var taskStore: TaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 0) {
                ForEach(taskStore.active) { task in
                    TaskRowView(task: task, style: .compact)
                    Divider()
                        .overlay(Color.primary.opacity(0.06))
                }

                let filled = taskStore.active.count
                let placeholderCount = max(0, taskStore.machineCap - filled)
                if placeholderCount > 0 {
                    ForEach(0..<placeholderCount, id: \.self) { _ in
                        SlotPlaceholderView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Active".uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Text("· \(taskStore.active.count) of ~\(taskStore.machineCap)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            Spacer(minLength: 0)

            Text("machine ok")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, TaskRowMetrics.horizontalPadding)
        .padding(.vertical, 6)
    }
}
