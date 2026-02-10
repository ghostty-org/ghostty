import AppKit
import SwiftUI

struct GitDiffSidebarView: View {
    @ObservedObject var state: GitDiffSidebarState

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var headerModeIndex: Binding<Int> {
        Binding(
            get: {
                switch state.source {
                case .workingTree:
                    switch state.selectedScope {
                    case .all: return 0
                    case .staged: return 1
                    case .unstaged: return 2
                    }
                case .pullRequest:
                    return 3
                }
            },
            set: { newValue in
                switch newValue {
                case 0:
                    state.selectedScope = .all
                    if state.source != .workingTree {
                        state.source = .workingTree
                    }
                case 1:
                    state.selectedScope = .staged
                    if state.source != .workingTree {
                        state.source = .workingTree
                    }
                case 2:
                    state.selectedScope = .unstaged
                    if state.source != .workingTree {
                        state.source = .workingTree
                    }
                case 3:
                    if state.source != .pullRequest {
                        state.source = .pullRequest
                    }
                default:
                    return
                }
            }
        )
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Files changed")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let summary = diffSummary {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            if summary.unresolved > 0 {
                                UnresolvedBadge(count: summary.unresolved)
                            }
                            DiffChangeBadge(additions: summary.additions, deletions: summary.deletions)
                        }
                        DiffChangeBadge(additions: summary.additions, deletions: summary.deletions)
                        EmptyView()
                    }
                }
                Button {
                    Task { await state.setVisible(false, cwd: nil) }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            CapsuleSegmentedControl(
                labels: ["All", "Staged", "Unstaged", "PR"],
                selection: headerModeIndex
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
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
        } else if state.source == .workingTree, state.visibleRows.isEmpty {
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
        } else if state.document == nil || state.document?.files.isEmpty == true {
            if state.isDiffLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else if let diffError = state.diffError, !diffError.isEmpty {
                Text(diffError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(state.source == .workingTree ? emptyMessage : "No file diffs found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            let files = state.document?.files ?? []
            GeometryReader { geo in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files, id: \.id) { file in
                            let unresolved = unresolvedCount(for: file.primaryPath)
                            Button {
                                state.requestScroll(to: file.id)
                            } label: {
                                HStack(spacing: 10) {
                                    DiffFileStatusBadge(status: file.status)
                                    fileTitle(file)
                                        .layoutPriority(1)
                                    Spacer(minLength: 0)
                                    if unresolved > 0 {
                                        UnresolvedBadge(count: unresolved)
                                    }
                                    DiffChangeBadge(additions: file.additions, deletions: file.deletions)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(rowBackground(for: file.id))
                            .contextMenu {
                                Button("Open") {
                                    openFile(file.primaryPath)
                                }
                            }

                            Rectangle()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(height: 1)
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
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
    }

    private var diffSummary: (files: Int, additions: Int, deletions: Int, unresolved: Int)? {
        guard let doc = state.document else { return nil }
        let adds = doc.files.reduce(0) { $0 + $1.additions }
        let dels = doc.files.reduce(0) { $0 + $1.deletions }
        let unresolved = state.commentsEnabled ? state.reviewDraft.threads.filter { !$0.isResolved }.count : 0
        return (doc.files.count, adds, dels, unresolved)
    }

    @ViewBuilder
    private func fileTitle(_ file: DiffFile) -> some View {
        let primary = file.primaryPath
        let pieces = primary.split(separator: "/", omittingEmptySubsequences: true)
        let fileName = pieces.last.map(String.init) ?? primary
        let dir = pieces.dropLast().joined(separator: "/")

        VStack(alignment: .leading, spacing: 1) {
            Text(fileName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if !dir.isEmpty {
                Text(dir)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let old = file.pathOld, let new = file.pathNew, !old.isEmpty, !new.isEmpty, old != new {
                Text("\(old) → \(new)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func openFile(_ path: String) {
        guard let repoRoot = state.repoRoot else { return }
        let url = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
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

    private func rowBackground(for path: String) -> Color {
        let highlight = state.currentVisiblePath ?? state.selectedPath
        guard let highlight, highlight == path else { return Color.clear }
        return Color.accentColor.opacity(0.14)
    }

    private func unresolvedCount(for path: String) -> Int {
        guard state.commentsEnabled else { return 0 }
        return state.reviewDraft.threads.filter { $0.path == path && !$0.isResolved }.count
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

private struct CapsuleSegmentedControl: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        c.segmentStyle = .capsule
        if #available(macOS 26.0, *) {
            c.borderShape = .circle
        }
        c.selectedSegmentBezelColor = NSColor(white: 0.35, alpha: 1.0)
        if #available(macOS 11.0, *) {
            c.segmentDistribution = .fillEqually
        }
        c.controlSize = .small
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.selectedSegment = selection
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        if c.selectedSegment != selection {
            c.selectedSegment = selection
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) {
            self.selection = selection
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            selection.wrappedValue = sender.selectedSegment
        }
    }
}

private struct StatusBadge: View {
    let kind: GitDiffKind

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
