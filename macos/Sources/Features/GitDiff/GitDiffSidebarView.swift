import AppKit
import SwiftUI

struct GitDiffSidebarView: View {
    @ObservedObject var state: GitDiffSidebarState
    let onSelect: (GitDiffEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            HStack {
                Text(state.repoRoot?.abbreviatedPath ?? "No repository")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
        } else if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.repoRoot == nil {
            Text("Not a Git repository")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.entries.isEmpty {
            Text("Working tree clean")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(selection: $state.selectedPath) {
                ForEach(state.entries) { entry in
                    HStack(spacing: 8) {
                        StatusBadge(kind: entry.kind)
                        Text(entry.displayPath)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if entry.additions > 0 || entry.deletions > 0 {
                            WorktreeChangeBadge(additions: entry.additions, deletions: entry.deletions)
                        } else {
                            Text(entry.statusCode)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selectedPath = entry.path
                    }
                    .tag(entry.path)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: state.selectedPath) { newValue in
                guard let newValue else { return }
                guard let entry = state.entries.first(where: { $0.path == newValue }) else { return }
                onSelect(entry)
            }
        }
    }

    private func iconName(for entry: GitDiffEntry) -> String {
        switch entry.kind {
        case .added: return "plus"
        case .deleted: return "trash"
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .untracked: return "questionmark"
        case .conflicted: return "exclamationmark.triangle"
        case .modified: return "pencil"
        case .unknown: return "circle"
        }
    }

    private func color(for entry: GitDiffEntry) -> Color {
        switch entry.kind {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .copied: return .blue
        case .untracked: return .orange
        case .conflicted: return .yellow
        case .modified: return .secondary
        case .unknown: return .secondary
        }
    }
}

private struct StatusBadge: View {
    let kind: GitDiffKind

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    private var label: String {
        switch kind {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "?"
        case .conflicted: return "U"
        case .modified: return "M"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch kind {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .copied: return .blue
        case .untracked: return .orange
        case .conflicted: return .yellow
        case .modified: return .secondary
        case .unknown: return .secondary
        }
    }
}

private struct WorktreeChangeBadge: View {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
