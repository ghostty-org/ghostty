import AppKit
import SwiftUI

struct GitDiffMainView: View {
    @ObservedObject var state: GitDiffSidebarState

    @State private var hoveredLineID: String? = nil
    @State private var composer: ComposerLocation? = nil
    @State private var composerText: String = ""
    @State private var lastVisibleFileID: String? = nil

    var body: some View {
        content
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let doc = state.document, !doc.files.isEmpty {
            DiffDocumentView(
                files: doc.files,
                state: state,
                hoveredLineID: $hoveredLineID,
                composer: $composer,
                composerText: $composerText,
                lastVisibleFileID: $lastVisibleFileID
            )
        } else {
            Text("No diff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiffDocumentView: View {
    let files: [DiffFile]
    @ObservedObject var state: GitDiffSidebarState

    @Binding var hoveredLineID: String?
    @Binding var composer: ComposerLocation?
    @Binding var composerText: String
    @Binding var lastVisibleFileID: String?

    private let lineNumberWidth: CGFloat = 36
    private let changeMarkerWidth: CGFloat = 3
    @State private var highlightCache = DiffHighlightCache()
    @State private var headerOffsetsUpdateTask: Task<Void, Never>? = nil
    @State private var latestHeaderOffsets: [String: CGFloat] = [:]
    @State private var scrollTask: Task<Void, Never>? = nil
    @State private var isScrolling: Bool = false
    @State private var scrollIdleTask: Task<Void, Never>? = nil

    private let initialRenderedFiles: Int = 12
    private let renderStep: Int = 8
    private let renderAhead: Int = 4

    var body: some View {
        GeometryReader { containerGeo in
            let minContentWidth = containerGeo.size.width
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                            Section {
                                // Anchor for sidebar jump-to-file. Keeping it in section content (not the header)
                                // makes scrolling more reliable with pinned section headers.
                                Color.clear
                                    .frame(height: 0)
                                    .id(file.id)
                                if shouldRenderFileBody(fileID: file.id, index: idx),
                                   !state.collapsedFileIDs.contains(file.id) {
                                    DiffFileBodyView(
                                        file: file,
                                        state: state,
                                        hoveredLineID: $hoveredLineID,
                                        composer: $composer,
                                        composerText: $composerText,
                                        highlightCache: highlightCache,
                                        minContentWidth: minContentWidth,
                                        isScrolling: isScrolling,
                                        lineNumberWidth: lineNumberWidth,
                                        changeMarkerWidth: changeMarkerWidth
                                    )
                                }
                            } header: {
                                DiffFileHeaderView(
                                    file: file,
                                    state: state,
                                    unresolvedCount: unresolvedCount(for: file.primaryPath)
                                )
                                .frame(minWidth: minContentWidth, alignment: .leading)
                                .background(
                                    GeometryReader { headerGeo in
                                        let minY = headerGeo.frame(in: .named("diffScroll")).minY
                                        // Avoid emitting offsets for every file header on every scroll tick.
                                        // We only need headers near the top edge to compute the "current visible file".
                                        let window = max(600, containerGeo.size.height * 1.25)
                                        Color.clear.preference(
                                            key: DiffFileHeaderOffsetPreferenceKey.self,
                                            value: abs(minY) <= window ? [file.id: minY] : [:]
                                        )
                                    }
                                )
                            }
                        }
                    }
                    // When a ScrollView supports horizontal scrolling, its content tends to collapse to
                    // its intrinsic width (making the diff look "iphone sized"). Enforce a minimum width
                    // so the diff fills the available space.
                    .frame(minWidth: minContentWidth, minHeight: containerGeo.size.height, alignment: .topLeading)
                }
                .coordinateSpace(name: "diffScroll")
                .onChange(of: state.scrollRequest?.nonce ?? 0) { _ in
                    guard let req = state.scrollRequest else { return }
                    scrollTask?.cancel()
                    scrollTask = Task { @MainActor in
                        // ScrollViewReader can be flaky with Lazy* stacks; doing an immediate scroll and a
                        // next-runloop scroll makes it much more reliable for large diffs.
                        proxy.scrollTo(req.path, anchor: .top)
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(req.path, anchor: .top)
                        }
                    }
                }
                .onPreferenceChange(DiffFileHeaderOffsetPreferenceKey.self) { offsets in
                    latestHeaderOffsets = offsets
                    isScrolling = true
                    scrollIdleTask?.cancel()
                    scrollIdleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        isScrolling = false
                    }
                    // Coalesce preference churn (these values update during scrolling/layout).
                    if headerOffsetsUpdateTask == nil {
                        headerOffsetsUpdateTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000) // ~20Hz
                            updateVisibleFile(latestHeaderOffsets)
                            headerOffsetsUpdateTask = nil
                        }
                    }
                }
            }
        }
    }

    private func shouldRenderFileBody(fileID: String, index: Int) -> Bool {
        if index < max(state.renderedFileCount, min(initialRenderedFiles, files.count)) { return true }
        if state.selectedPath == fileID { return true }
        if state.currentVisiblePath == fileID { return true }
        return false
    }

    private func unresolvedCount(for path: String) -> Int {
        guard state.commentsEnabled else { return 0 }
        return state.reviewDraft.threads.filter { $0.path == path && !$0.isResolved }.count
    }

    private func updateVisibleFile(_ offsets: [String: CGFloat]) {
        guard !offsets.isEmpty else { return }
        // Prefer the header that's at (or just above) the top edge. This avoids jitter where we
        // oscillate between two headers around the midpoint.
        let best: String? = offsets
            .filter { $0.value <= 1 }
            .max(by: { $0.value < $1.value })?
            .key
            ?? offsets.min(by: { abs($0.value) < abs($1.value) })?.key
        guard let best else { return }
        guard best != lastVisibleFileID else { return }
        lastVisibleFileID = best
        if state.currentVisiblePath != best {
            state.currentVisiblePath = best
        }
        maybeIncreaseRenderedFiles(visibleFileID: best)
    }

    private func maybeIncreaseRenderedFiles(visibleFileID: String) {
        guard !files.isEmpty else { return }
        guard let idx = files.firstIndex(where: { $0.id == visibleFileID }) else { return }
        let rendered = max(state.renderedFileCount, min(initialRenderedFiles, files.count))
        guard idx >= max(0, rendered - renderAhead) else { return }

        // Avoid jumping from 12 -> 200+ when a user jumps directly to a far file via the sidebar.
        guard idx <= rendered + (renderStep * 2) else { return }

        let next = min(files.count, max(rendered, idx + renderStep))
        if next != state.renderedFileCount {
            state.renderedFileCount = next
        }
    }
}

private struct DiffFileHeaderView: View {
    let file: DiffFile
    @ObservedObject var state: GitDiffSidebarState
    let unresolvedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    state.toggleFileCollapsed(file.id)
                } label: {
                    Image(systemName: state.collapsedFileIDs.contains(file.id) ? "chevron.right" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(state.collapsedFileIDs.contains(file.id) ? "Expand" : "Collapse")

                DiffFileStatusBadge(status: file.status)

                Text(file.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if state.commentsEnabled, unresolvedCount > 0 {
                            UnresolvedBadge(count: unresolvedCount)
                        }
                        DiffChangeBadge(additions: file.additions, deletions: file.deletions)
                    }
                    DiffChangeBadge(additions: file.additions, deletions: file.deletions)
                    EmptyView()
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.primaryPath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
                .disabled(!isOpenablePath(file.primaryPath))

                Button {
                    openFile(file.primaryPath)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open file")
                .disabled(!isOpenablePath(file.primaryPath))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Use an opaque background so the pinned header doesn't "change styles" as content scrolls beneath it.
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
    }

    private func isOpenablePath(_ path: String) -> Bool {
        !path.hasPrefix(".gitdiff/")
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
}

private struct DiffFileBodyView: View {
    let file: DiffFile
    @ObservedObject var state: GitDiffSidebarState
    @Binding var hoveredLineID: String?
    @Binding var composer: ComposerLocation?
    @Binding var composerText: String
    let highlightCache: DiffHighlightCache

    let minContentWidth: CGFloat
    let isScrolling: Bool
    let lineNumberWidth: CGFloat
    let changeMarkerWidth: CGFloat

    var body: some View {
        if file.isBinary || file.isCombinedUnsupported || file.hunks.isEmpty {
            let fallback = file.fallbackText ?? (file.isBinary ? "Binary file not shown." : "No diff to render.")
            VStack(alignment: .leading, spacing: 0) {
                Text(fallback)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                Divider()
            }
            .frame(minWidth: minContentWidth, alignment: .leading)
        } else {
            let language = DiffSyntaxHighlighter.Language.from(filePath: file.primaryPath)
            let threadsByNewLine = state.commentsEnabled
                ? mapThreadsByNewLine(threads: state.reviewDraft.threads, path: file.primaryPath)
                : [:]

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(file.hunks, id: \.id) { hunk in
                    DiffHunkHeaderRow(
                        header: hunk.header,
                        minContentWidth: minContentWidth,
                        lineNumberWidth: lineNumberWidth,
                        changeMarkerWidth: changeMarkerWidth
                    )

                    ForEach(hunk.lines, id: \.id) { line in
                        DiffLineRow(
                            filePath: file.primaryPath,
                            line: line,
                            language: language,
                            highlightCache: highlightCache,
                            threads: (line.newLine.flatMap { threadsByNewLine[$0] } ?? []),
                            hoveredLineID: $hoveredLineID,
                            composer: $composer,
                            composerText: $composerText,
                            state: state,
                            minContentWidth: minContentWidth,
                            isScrolling: isScrolling,
                            lineNumberWidth: lineNumberWidth,
                            changeMarkerWidth: changeMarkerWidth
                        )
                    }
                }
            }
            Divider()
        }
    }

    private func mapThreadsByNewLine(threads: [DiffThread], path: String) -> [Int: [DiffThread]] {
        var map: [Int: [DiffThread]] = [:]
        for thread in threads {
            guard thread.path == path else { continue }
            guard case .line(let ln) = thread.anchor else { continue }
            map[ln, default: []].append(thread)
        }
        return map
    }
}

private struct DiffHunkHeaderRow: View {
    let header: String
    let minContentWidth: CGFloat
    let lineNumberWidth: CGFloat
    let changeMarkerWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: changeMarkerWidth)
            Text(header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: .systemPurple))
                .lineLimit(1)
                .padding(.vertical, 4)
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
        .frame(minWidth: minContentWidth, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
    }
}

private struct DiffLineRow: View {
    let filePath: String
    let line: DiffLine
    let language: DiffSyntaxHighlighter.Language
    let highlightCache: DiffHighlightCache
    let threads: [DiffThread]

    @Binding var hoveredLineID: String?
    @Binding var composer: ComposerLocation?
    @Binding var composerText: String

    @ObservedObject var state: GitDiffSidebarState

    let minContentWidth: CGFloat
    let isScrolling: Bool
    let lineNumberWidth: CGFloat
    let changeMarkerWidth: CGFloat

    private struct HighlightTaskKey: Hashable {
        let id: String
        let language: DiffSyntaxHighlighter.Language
        let text: String
        let canHighlight: Bool
    }

    @State private var renderedText: AttributedString? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lineRow
                .task(id: HighlightTaskKey(id: line.id, language: language, text: line.text, canHighlight: !isScrolling)) {
                    guard !isScrolling else { return }
                    // Keep rendering updates local to this row (avoid global invalidation storms).
                    let highlighted = await highlightCache.highlighted(id: line.id, text: line.text, language: language)
                    await MainActor.run {
                        renderedText = highlighted
                    }
                }

            if state.commentsEnabled, let newLine = line.newLine {
                ForEach(threads, id: \.id) { thread in
                    DiffThreadRow(
                        thread: thread,
                        state: state,
                        minContentWidth: minContentWidth,
                        lineNumberWidth: lineNumberWidth,
                        changeMarkerWidth: changeMarkerWidth
                    )
                }

                if composer?.path == filePath, composer?.newLine == newLine {
                    DiffComposerRow(
                        path: filePath,
                        newLine: newLine,
                        text: $composerText,
                        onCancel: { composer = nil; composerText = "" },
                        onSave: {
                            let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !body.isEmpty else { return }
                            Task { await state.addDraftThread(path: filePath, anchor: .line(newLine: newLine), body: body) }
                            composer = nil
                            composerText = ""
                        },
                        minContentWidth: minContentWidth,
                        lineNumberWidth: lineNumberWidth,
                        changeMarkerWidth: changeMarkerWidth
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var lineRow: some View {
        let baseRow = HStack(spacing: 0) {
            lineNumberColumn(line.oldLine)
            lineNumberColumn(line.newLine)
            changeMarkerColumn
            codeColumn
            Spacer(minLength: 0)
        }
        .frame(minWidth: minContentWidth, alignment: .leading)
        .background(lineBackground)
        .contentShape(Rectangle())

        if state.commentsEnabled {
            baseRow
                .overlay(alignment: .leading) {
                    commentButtonOverlay
                }
                .onHover { hovering in
                    guard !isScrolling else { return }
                    if hovering {
                        hoveredLineID = line.id
                    } else if hoveredLineID == line.id {
                        hoveredLineID = nil
                    }
                }
        } else {
            baseRow
        }
    }

    private var commentButtonOverlay: some View {
        Group {
            if canComment, hoveredLineID == line.id {
                Button {
                    openComposer()
                } label: {
                    Image(systemName: "plus.bubble")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                // Uses existing unused space on the leading side of the old-line gutter.
                .padding(.leading, 2)
                .help("Add comment")
            }
        }
    }

    private var canComment: Bool {
        // Anchor comments on the new-side line number.
        state.commentsEnabled && !isScrolling && line.newLine != nil && (line.kind == .add || line.kind == .context)
    }

    private func openComposer() {
        guard state.commentsEnabled else { return }
        guard let newLine = line.newLine else { return }
        composer = ComposerLocation(path: filePath, newLine: newLine)
        composerText = ""
    }

    private func lineNumberColumn(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: lineNumberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var changeMarkerColumn: some View {
        Rectangle()
            .fill(changeMarkerColor)
            .frame(width: changeMarkerWidth)
    }

    private var codeColumn: some View {
        Text(renderedText ?? AttributedString(line.text))
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
            .padding(.leading, 4)
    }

    private var changeMarkerColor: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.75)
        case .del: return Color.red.opacity(0.75)
        case .context: return Color.clear
        case .meta: return Color.secondary.opacity(0.35)
        }
    }

    private var lineBackground: some View {
        switch line.kind {
        case .add:
            return AnyView(Color.green.opacity(0.12))
        case .del:
            return AnyView(Color.red.opacity(0.12))
        case .context, .meta:
            return AnyView(Color.clear)
        }
    }
}

private struct DiffThreadRow: View {
    let thread: DiffThread
    @ObservedObject var state: GitDiffSidebarState
    let minContentWidth: CGFloat
    let lineNumberWidth: CGFloat
    let changeMarkerWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: changeMarkerWidth)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("You (draft)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(thread.isResolved ? "Unresolve" : "Resolve") {
                        Task { await state.setThreadResolved(thread.id, resolved: !thread.isResolved) }
                    }
                    .buttonStyle(.borderless)
                    Button("Delete") {
                        Task { await state.deleteThread(thread.id) }
                    }
                    .buttonStyle(.borderless)
                }
                Text(thread.body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .frame(minWidth: minContentWidth, alignment: .leading)
    }
}

private struct DiffComposerRow: View {
    let path: String
    let newLine: Int
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    let minContentWidth: CGFloat
    let lineNumberWidth: CGFloat
    let changeMarkerWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: lineNumberWidth)
            Color.clear.frame(width: changeMarkerWidth)
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .frame(minHeight: 60)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                HStack {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                    Button("Save", action: onSave)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .frame(minWidth: minContentWidth, alignment: .leading)
    }
}

private struct ComposerLocation: Hashable {
    let path: String
    let newLine: Int
}

private struct DiffFileHeaderOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private actor DiffHighlightCache {
    private struct Key: Hashable {
        let id: String
        let language: DiffSyntaxHighlighter.Language
        let text: String
    }

    private var cache: [Key: AttributedString] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<AttributedString, Never>] = [:]

    private let maxEntries: Int = 2500
    private let maxLineLengthForHighlighting: Int = 500

    func highlighted(id: String, text: String, language: DiffSyntaxHighlighter.Language) async -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }
        guard language != .unknown else { return AttributedString(text) }
        guard text.count <= maxLineLengthForHighlighting else { return AttributedString(text) }

        let key = Key(id: id, language: language, text: text)
        if let cached = cache[key] { return cached }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { [text, language] in
            DiffSyntaxHighlighter.highlightedCodeLineAttributed(text: text, language: language)
        }
        inFlight[key] = task

        let attr = await task.value
        inFlight[key] = nil
        insert(key: key, value: attr)
        return attr
    }

    private func insert(key: Key, value: AttributedString) {
        if cache.count >= maxEntries {
            let over = (cache.count + 1) - maxEntries
            if over > 0, over <= order.count {
                for _ in 0..<over {
                    let evict = order.removeFirst()
                    cache[evict] = nil
                }
            } else if over > 0 {
                cache.removeAll(keepingCapacity: true)
                order.removeAll(keepingCapacity: true)
            }
        }
        cache[key] = value
        order.append(key)
    }
}
