import SwiftUI

struct DiffFileStatusBadge: View {
    let status: DiffFileStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .frame(width: 18)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var label: String {
        switch status {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .modified: return "M"
        case .binary: return "B"
        case .combinedUnsupported: return "?"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch status {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .modified: return .secondary
        case .binary: return .orange
        case .combinedUnsupported, .unknown: return .secondary
        }
    }
}

struct UnresolvedBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .help("\(count) unresolved comment(s)")
    }
}

struct DiffChangeBadge: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            if additions > 0 {
                Text("+\(additions)")
                    .foregroundStyle(Color.green)
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .foregroundStyle(Color.red)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
