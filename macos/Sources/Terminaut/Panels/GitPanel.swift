import SwiftUI

/// Shows git branch, uncommitted changes, sync status, and open PRs
struct GitPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("GIT")

            VStack(alignment: .leading, spacing: 10) {
                // Branch name
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)

                    Text(state.gitBranch ?? "---")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                // Stats row
                HStack(spacing: 20) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Open PRs section
            if let prs = state.openPRs, !prs.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 8) {
                    Text("OPEN PRs")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)

                    ForEach(prs) { pr in
                        PRRow(pr: pr)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(panelBackground)
    }

    private func gitStat(icon: String, value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)

            Text("\(value)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

struct PRRow: View {
    let pr: SessionState.PullRequest

    var body: some View {
        HStack(spacing: 8) {
            // PR number
            Text("#\(pr.number)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
                .frame(width: 50, alignment: .leading)

            // Title (truncated)
            Text(pr.title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            // Draft indicator
            if pr.isDraft == true {
                Text("DRAFT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
