import AppKit
import SwiftUI

/// Search across the folder the explorer is showing.
///
/// Lives over the editor rather than in the sidebar: a result list is wide
/// — path, line and the matched text — and a 240pt column would truncate
/// the part you are reading it for.
@MainActor
final class WorkspaceSearchCenter: ObservableObject {
    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isSearching = false
    @Published var isPresented = false

    /// The folder searched, kept so results can be shown relative to it.
    @Published private(set) var root: String = ""

    private var generation = 0

    func present(root: String) {
        self.root = root
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    /// Runs the search, discarding answers that arrive after a newer one.
    ///
    /// Typing produces a search per keystroke and they finish out of order,
    /// so without the generation check a slow early query can overwrite the
    /// results of the fast later one and leave the list showing matches for
    /// a prefix of what is in the field.
    func search() {
        let query = self.query
        let root = self.root
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            return
        }

        generation += 1
        let generation = self.generation
        isSearching = true

        Task.detached(priority: .userInitiated) {
            let found = WorkspaceSearch.run(query: query, root: root)
            await MainActor.run { [weak self] in
                guard let self, generation == self.generation else { return }
                self.hits = found
                self.isSearching = false
            }
        }
    }
}

struct WorkspaceSearchView: View {
    @ObservedObject var center: WorkspaceSearchCenter
    @ObservedObject private var palette: ThemePalette = .shared

    let onOpen: (SearchHit) -> Void

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
        }
        .frame(width: 520, height: 380)
        .background(Color(nsColor: palette.background ?? .windowBackgroundColor))
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search this folder", text: $center.query)
                .textFieldStyle(.plain)
                .font(palette.font(size: 12))
                .onSubmit { center.search() }

            if center.isSearching {
                ProgressView().controlSize(.small)
            }

            Button("Close") { center.dismiss() }
                .font(palette.font(size: 11))
        }
        .padding(10)
    }

    @ViewBuilder
    private var results: some View {
        if center.hits.isEmpty {
            VStack(spacing: 6) {
                Text(center.query.isEmpty ? "Type to search" : "No matches")
                    .font(palette.font(size: 11))
                    .foregroundStyle(.secondary)
                if !center.root.isEmpty {
                    Text(center.root)
                        .font(palette.font(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(center.hits) { hit in
                        HitRow(hit: hit, root: center.root) { onOpen(hit) }
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit
    let root: String
    let onOpen: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared
    @ObservedObject private var icons: FileIconProvider = .shared
    @State private var isHovered = false

    private var accent: Color { palette.accent ?? .accentColor }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                FileIconView(icon: icons.icon(forFile: hit.name), size: 12)

                Text(hit.relativePath(to: root))
                    .font(palette.font(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(":\(hit.line)")
                    .font(palette.font(size: 10))
                    .foregroundStyle(.tertiary)

                Text(hit.text.trimmingCharacters(in: .whitespaces))
                    .font(palette.font(size: 11))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? accent.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(hit.path)
    }
}
