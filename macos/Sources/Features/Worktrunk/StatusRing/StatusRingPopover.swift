import SwiftUI

/// Hover tooltip showing agent status + PR/CI details
struct StatusRingPopover: View {
    let agentStatus: WorktreeAgentStatus?
    let prStatus: PRStatus?
    let ciState: CIState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Agent status section
            if let status = agentStatus {
                agentSection(status: status)
            }

            // PR/CI section
            if let pr = prStatus {
                if agentStatus != nil {
                    Divider()
                }
                prSection(pr: pr)
            } else if ciState != .none {
                if agentStatus != nil {
                    Divider()
                }
                noPRSection()
            }

            // Click hint (only if there's a PR)
            if prStatus != nil {
                Divider()
                Text("Click to open PR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minWidth: 200, maxWidth: 280)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        }
    }

    // MARK: - Agent Section

    @ViewBuilder
    private func agentSection(status: WorktreeAgentStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agentColor(for: status))
                .frame(width: 8, height: 8)

            Text("Agent: \(agentLabel(for: status))")
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func agentColor(for status: WorktreeAgentStatus) -> Color {
        switch status {
        case .working: return .orange
        case .permission: return .red
        case .review: return .green
        }
    }

    private func agentLabel(for status: WorktreeAgentStatus) -> String {
        switch status {
        case .working: return "Working"
        case .permission: return "Needs Input"
        case .review: return "Done"
        }
    }

    // MARK: - PR Section

    @ViewBuilder
    private func prSection(pr: PRStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // PR title and number
            HStack(spacing: 4) {
                Text("PR #\(pr.number)")
                    .font(.caption)
                    .fontWeight(.medium)

                if pr.isMerged {
                    Text("(merged)")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
            }

            Text(pr.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // CI checks summary
            if !pr.checks.isEmpty {
                checksRow(pr: pr)
            }
        }
    }

    @ViewBuilder
    private func checksRow(pr: PRStatus) -> some View {
        let counts = pr.checkCounts

        HStack(spacing: 8) {
            if counts.passed > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(counts.passed)")
                }
            }

            if counts.failed > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(counts.failed)")
                }
            }

            if counts.pending > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.orange)
                    Text("\(counts.pending)")
                }
            }

            if counts.skipped > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.gray)
                    Text("\(counts.skipped)")
                }
            }
        }
        .font(.caption2)
    }

    // MARK: - No PR Section

    @ViewBuilder
    private func noPRSection() -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ciStateColor)
                .frame(width: 8, height: 8)

            Text("CI: \(ciStateLabel)")
                .font(.caption)
        }
    }

    private var ciStateColor: Color {
        switch ciState {
        case .passed: return .green
        case .failed: return .red
        case .pending: return .orange
        case .skipped, .cancelled: return .gray
        case .none: return .clear
        }
    }

    private var ciStateLabel: String {
        switch ciState {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .pending: return "Running"
        case .skipped: return "Skipped"
        case .cancelled: return "Cancelled"
        case .none: return "None"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct StatusRingPopover_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Agent only
            StatusRingPopover(
                agentStatus: .working,
                prStatus: nil,
                ciState: .none
            )

            // PR with checks
            StatusRingPopover(
                agentStatus: .permission,
                prStatus: PRStatus(
                    number: 42,
                    title: "Add user authentication flow",
                    headRefName: "feature-auth",
                    state: "OPEN",
                    url: "https://github.com/org/repo/pull/42",
                    checks: [
                        PRCheck(name: "build", state: "SUCCESS", conclusion: "success", detailsUrl: nil, workflowName: "CI"),
                        PRCheck(name: "test", state: "SUCCESS", conclusion: "success", detailsUrl: nil, workflowName: "CI"),
                        PRCheck(name: "lint", state: "FAILURE", conclusion: "failure", detailsUrl: nil, workflowName: "CI"),
                    ],
                    updatedAt: Date(),
                    fetchedAt: Date()
                ),
                ciState: .failed
            )
        }
        .padding()
    }
}
#endif
