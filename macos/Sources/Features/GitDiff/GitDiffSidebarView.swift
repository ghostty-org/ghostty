import AppKit
import SwiftUI

struct GitDiffSidebarView: View {
    @ObservedObject var state: GitDiffSidebarState
    let onSelect: (GitDiffEntry, GitDiffScope) -> Void

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
            Picker("Scope", selection: $state.selectedScope) {
                Text("All (\(state.allCount))")
                    .tag(GitDiffScope.all)
                Text("Staged (\(state.stagedCount))")
                    .tag(GitDiffScope.staged)
                Text("Unstaged (\(state.unstagedCount))")
                    .tag(GitDiffScope.unstaged)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.repoRoot == nil {
            if state.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                Text("Not a Git repository")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if state.visibleRows.isEmpty {
            if state.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            List(selection: $state.selectedEntry) {
                ForEach(state.visibleRows) { row in
                    let stats = row.entry.stats(for: row.scope)
                    HStack(spacing: 8) {
                        StatusBadge(kind: row.entry.kind(for: row.scope))
                        Text(row.entry.displayPath)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if stats.0 > 0 || stats.1 > 0 {
                            WorktreeChangeBadge(additions: stats.0, deletions: stats.1)
                        } else {
                            Text(row.entry.statusCode)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selectedEntry = row.id
                    }
                    .tag(row.id)
                    .contextMenu {
                        if row.entry.hasUnstagedChanges {
                            Button("Stage") {
                                Task { await state.stage(row.entry) }
                            }
                        }
                        if row.entry.hasStagedChanges {
                            Button("Unstage") {
                                Task { await state.unstage(row.entry) }
                            }
                        }
                        Button("Open") {
                            openFile(row.entry)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: state.selectedEntry) { newValue in
                guard let newValue else { return }
                guard let entry = state.entries.first(where: { $0.path == newValue.path }) else { return }
                onSelect(entry, newValue.scope)
            }
            .overlay(alignment: .topTrailing) {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
        }
    }

    private func openFile(_ entry: GitDiffEntry) {
        guard let repoRoot = state.repoRoot else { return }
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(entry.path)
        let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension) ?? NSWorkspace.shared.defaultTextEditor
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var emptyMessage: String {
        switch state.selectedScope {
        case .all:
            return "Working tree clean"
        case .staged:
            return "No staged changes"
        case .unstaged:
            return "No unstaged changes"
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
