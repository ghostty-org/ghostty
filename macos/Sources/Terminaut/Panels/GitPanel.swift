import SwiftUI

/// Shows open pull requests for the repository
struct GitPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("OPEN PRs")

            if let prs = state.openPRs, !prs.isEmpty {
                ForEach(prs) { pr in
                    PRRow(pr: pr)
                }
            } else {
                Text("No open PRs")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 8)
        .background(panelBackground)
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
