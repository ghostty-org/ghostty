import SwiftUI

/// Shows git branch, uncommitted changes, and sync status
struct GitPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("GIT")

            VStack(alignment: .leading, spacing: 8) {
                // Branch name
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)

                    Text(state.gitBranch ?? "---")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                // Stats row
                HStack(spacing: 16) {
                    gitStat(
                        icon: "circle.fill",
                        value: state.gitUncommitted ?? 0,
                        label: "uncommitted",
                        color: state.gitUncommitted ?? 0 > 0 ? .yellow : .gray
                    )

                    if let ahead = state.gitAhead, ahead > 0 {
                        gitStat(
                            icon: "arrow.up",
                            value: ahead,
                            label: "ahead",
                            color: .green
                        )
                    }

                    if let behind = state.gitBehind, behind > 0 {
                        gitStat(
                            icon: "arrow.down",
                            value: behind,
                            label: "behind",
                            color: .orange
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(panelBackground)
    }

    private func gitStat(icon: String, value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)

            Text("\(value)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}
