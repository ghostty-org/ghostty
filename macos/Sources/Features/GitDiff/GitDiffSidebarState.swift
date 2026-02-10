import Foundation
import SwiftUI
import Darwin
import OSLog

enum GitDiffSource: String, Hashable, CaseIterable, Codable {
    case workingTree
    case pullRequest

    var label: String {
        switch self {
        case .workingTree: return "Local"
        case .pullRequest: return "PR"
        }
    }
}

struct GitDiffSidebarRow: Identifiable, Hashable {
    let entry: GitDiffEntry
    let scope: GitDiffScope

    var id: String { entry.path }
}

struct GitDiffScrollRequest: Hashable {
    let path: String
    let nonce: Int
}

@MainActor
final class GitDiffSidebarState: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ghostree",
        category: "GitDiff"
    )

    private struct RefreshRequest: Hashable {
        var cwd: URL?
        var force: Bool
    }

    @Published var isVisible: Bool = false
    @Published var panelWidth: CGFloat = 320
    @Published var repoRoot: String? = nil
    @Published var entries: [GitDiffEntry] = []
    @Published var source: GitDiffSource = .workingTree {
        didSet {
            handleSourceChange()
        }
    }
    @Published var selectedScope: GitDiffScope = .all {
        didSet {
            handleScopeChange()
        }
    }
    @Published var selectedPath: String? = nil
    @Published var currentVisiblePath: String? = nil
    @Published var scrollRequest: GitDiffScrollRequest? = nil
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var diffText: String = ""
    @Published var diffError: String? = nil
    @Published var isDiffLoading: Bool = false
    @Published var document: DiffDocument? = nil
    @Published var commentsEnabled: Bool = false
    @Published var reviewDraft: DiffReviewDraft = .empty
    @Published var collapsedFileIDs: Set<String> = []
    @Published var renderedFileCount: Int = 0
    @Published var pullRequest: PRStatus? = nil
    @Published var selectedWorktreePath: String? = nil
    private var diffRequestID: Int = 0
    private var scrollNonce: Int = 0

    private let store = GitDiffStore()
    private var lastCwd: URL? = nil
    private let draftStore = DiffReviewDraftStore()
    private var refreshTask: Task<Void, Never>? = nil
    private var pendingRefresh: RefreshRequest? = nil
    private var lastRefreshAt: Date = .distantPast
    private var pollTask: Task<Void, Never>? = nil
    private let watchQueue = DispatchQueue(label: "gitdiff.watch", qos: .utility)
    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var watchFileDescriptors: [Int32] = []
    private var watchedPaths: [String] = []
    private var watchedWorktreePath: String? = nil
    private var ignoreWatchEventsUntil: Date = .distantPast

    var allCount: Int {
        entries.count
    }

    var stagedCount: Int {
        entries.filter { $0.hasStagedChanges }.count
    }

    var unstagedCount: Int {
        entries.filter { $0.hasUnstagedChanges }.count
    }

    var visibleRows: [GitDiffSidebarRow] {
        switch selectedScope {
        case .all:
            return entries.map { GitDiffSidebarRow(entry: $0, scope: .all) }
        case .staged:
            return entries.filter { $0.hasStagedChanges }.map { GitDiffSidebarRow(entry: $0, scope: .staged) }
        case .unstaged:
            return entries.filter { $0.hasUnstagedChanges }.map { GitDiffSidebarRow(entry: $0, scope: .unstaged) }
        }
    }

    func refresh(cwd: URL?, force: Bool = false) async {
        await performRefresh(cwd: cwd, force: force)
    }

    func requestRefresh(cwd: URL?, force: Bool = false) {
        guard force || isVisible else { return }
        if let cwd { lastCwd = cwd }
        pendingRefresh = RefreshRequest(cwd: cwd, force: force)
        if refreshTask == nil {
            refreshTask = Task { @MainActor [weak self] in
                await self?.runRefreshLoop()
            }
        }
    }

    private func runRefreshLoop() async {
        defer { refreshTask = nil }
        while !Task.isCancelled {
            guard let req = pendingRefresh else { return }
            pendingRefresh = nil

            if !req.force {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if pendingRefresh != nil { continue }

                let minInterval: TimeInterval = 0.4
                let since = Date().timeIntervalSince(lastRefreshAt)
                if since < minInterval {
                    try? await Task.sleep(nanoseconds: UInt64((minInterval - since) * 1_000_000_000))
                    if pendingRefresh != nil { continue }
                }
            }

            await performRefresh(cwd: req.cwd, force: req.force)
            lastRefreshAt = Date()
        }
    }

    private func performRefresh(cwd: URL?, force: Bool) async {
        guard force || isVisible else { return }
        if let cwd { lastCwd = cwd }

        let effectiveCwd: URL?
        if let selectedWorktreePath {
            effectiveCwd = URL(fileURLWithPath: selectedWorktreePath)
        } else {
            effectiveCwd = cwd ?? lastCwd
        }

        guard let effectiveCwd else { return }

        let start = DispatchTime.now().uptimeNanoseconds

        isLoading = true
        defer { isLoading = false }

        let root = await store.repoRoot(for: effectiveCwd.path)
        repoRoot = root
        guard let root else {
            entries = []
            errorMessage = nil
            stopWatching()
            clearDiff()
            return
        }

        do {
            entries = try await store.statusEntries(repoRoot: root)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = String(describing: error)
        }
        reconcileSelection()
        startWatchingIfNeeded()

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        Self.logger.debug("refresh repo=\(root, privacy: .public) entries=\(self.entries.count) force=\(force) ms=\(elapsedMs, privacy: .public)")
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                guard self.isVisible else { continue }
                guard self.source == .workingTree else { continue }
                self.requestRefresh(cwd: self.lastCwd, force: false)
            }
        }
    }

    func refreshCurrent(force: Bool = false) async {
        await refresh(cwd: lastCwd, force: force)
    }

    func setSelectedWorktreePath(_ path: String?) async {
        selectedWorktreePath = path
        guard isVisible else { return }
        let url = path.map { URL(fileURLWithPath: $0) }
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = nil
        await performRefresh(cwd: url, force: true)
        await loadDiffForCurrentSource()
    }

    func setVisible(_ visible: Bool, cwd: String?) async {
        isVisible = visible
        if !visible {
            pollTask?.cancel()
            pollTask = nil
            refreshTask?.cancel()
            refreshTask = nil
            pendingRefresh = nil
            stopWatching()
            clearDiff()
            return
        }
        let url = cwd.map { URL(fileURLWithPath: $0) }
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = nil
        await performRefresh(cwd: url, force: true)
        startPollingIfNeeded()
        await loadDiffForCurrentSource()
    }

    func diffCommand(for entry: GitDiffEntry) -> String {
        store.diffCommand(for: entry, scope: selectedScope)
    }

    func loadUnifiedDiff() async {
        guard let repoRoot else {
            diffText = ""
            diffError = "No repository"
            document = nil
            return
        }
        diffRequestID += 1
        let requestID = diffRequestID
        isDiffLoading = true
        diffError = nil
        diffText = ""
        document = nil
        renderedFileCount = 0
        do {
            let scope = selectedScope
            let text = try await store.unifiedDiffText(repoRoot: repoRoot, scope: scope, entries: entries)
            guard requestID == diffRequestID else { return }
            diffText = text
            let parsed = await Task.detached(priority: .userInitiated) {
                DiffParser.parseUnified(text: text, source: .workingTree(scope: scope))
            }.value
            guard requestID == diffRequestID else { return }
            document = parsed
            renderedFileCount = min(parsed.files.count, 12)
            await loadDraftForCurrentContext()
        } catch {
            guard requestID == diffRequestID else { return }
            diffText = ""
            diffError = String(describing: error)
            document = nil
        }
        guard requestID == diffRequestID else { return }
        isDiffLoading = false
    }

    func loadPullRequestDiff() async {
        guard let repoRoot else {
            diffText = ""
            diffError = "No repository"
            document = nil
            return
        }

        diffRequestID += 1
        let requestID = diffRequestID

        pullRequest = nil
        currentVisiblePath = nil
        scrollRequest = nil

        isDiffLoading = true
        diffError = nil
        diffText = ""
        document = nil
        renderedFileCount = 0

        guard let branch = await store.currentBranch(repoRoot: repoRoot) else {
            diffError = "Detached HEAD (no branch)"
            isDiffLoading = false
            return
        }

        do {
            let pr = try await GHClient.prForBranchLite(repoPath: repoRoot, branch: branch)
            guard requestID == diffRequestID else { return }
            guard let pr else {
                diffError = "No pull request for branch “\(branch)”"
                isDiffLoading = false
                return
            }
            pullRequest = pr

            let text = try await GHClient.prDiff(repoPath: repoRoot, number: pr.number)
            guard requestID == diffRequestID else { return }
            let cleaned = stripANSIEscapeCodes(text)
            diffText = cleaned
            let parsed = await Task.detached(priority: .userInitiated) {
                DiffParser.parseUnified(text: cleaned, source: .pullRequest(number: pr.number))
            }.value
            guard requestID == diffRequestID else { return }
            document = parsed
            renderedFileCount = min(parsed.files.count, 12)
            await loadDraftForCurrentContext()
        } catch {
            guard requestID == diffRequestID else { return }
            diffText = ""
            diffError = describe(error)
            document = nil
        }
        guard requestID == diffRequestID else { return }
        isDiffLoading = false
    }

    func clearDiff() {
        isDiffLoading = false
        diffText = ""
        diffError = nil
        selectedPath = nil
        currentVisiblePath = nil
        scrollRequest = nil
        pullRequest = nil
        document = nil
        reviewDraft = .empty
        collapsedFileIDs = []
        renderedFileCount = 0
    }

    func stage(_ entry: GitDiffEntry) async {
        guard let repoRoot else { return }
        ignoreWatchEventsUntil = Date().addingTimeInterval(0.6)
        do {
            try await store.stage(repoRoot: repoRoot, path: entry.path)
            await refreshCurrent(force: true)
            if isVisible {
                await loadDiffForCurrentSource()
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    func unstage(_ entry: GitDiffEntry) async {
        guard let repoRoot else { return }
        ignoreWatchEventsUntil = Date().addingTimeInterval(0.6)
        var failures: [String] = []
        let paths = unstagePaths(for: entry)
        for path in paths {
            do {
                try await store.unstage(repoRoot: repoRoot, path: path)
            } catch {
                failures.append(describe(error))
            }
        }
        await refreshCurrent(force: true)
        if isVisible {
            await loadDiffForCurrentSource()
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    private func startWatchingIfNeeded() {
        guard isVisible else { return }
        guard source == .workingTree else {
            stopWatching()
            return
        }
        let worktreePath = selectedWorktreePath ?? repoRoot
        guard let worktreePath else { return }
        startWatching(worktreePath: worktreePath, forceRestart: false)
    }

    private func startWatching(worktreePath: String, forceRestart: Bool) {
        let paths = watchPaths(for: worktreePath)
        guard !paths.isEmpty else { return }

        if !forceRestart, watchedWorktreePath == worktreePath, watchedPaths == paths, !watchSources.isEmpty {
            return
        }

        stopWatching()
        watchedWorktreePath = worktreePath
        watchedPaths = paths

        for path in paths {
            let fd = openFileDescriptor(path)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .link],
                queue: watchQueue
            )
            source.setEventHandler { [weak self] in
                let data = source.data
                Task { @MainActor [weak self] in
                    self?.handleWatchEvent(data, worktreePath: worktreePath)
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            watchSources.append(source)
            watchFileDescriptors.append(fd)
        }
    }

    private func stopWatching() {
        for source in watchSources {
            source.cancel()
        }
        watchSources.removeAll()
        watchFileDescriptors.removeAll()
        watchedPaths = []
        watchedWorktreePath = nil
    }

    private func handleWatchEvent(_ data: DispatchSource.FileSystemEvent, worktreePath: String) {
        if Date() < ignoreWatchEventsUntil { return }

        if data.contains(.delete) || data.contains(.rename) {
            startWatching(worktreePath: worktreePath, forceRestart: true)
        }

        requestRefresh(cwd: lastCwd, force: false)
    }

    private func watchPaths(for worktreePath: String) -> [String] {
        guard let gitDir = gitDirPath(for: worktreePath) else { return [] }
        let index = URL(fileURLWithPath: gitDir).appendingPathComponent("index").path
        let head = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD").path
        return [index, head]
    }

    private func openFileDescriptor(_ path: String) -> Int32 {
        path.withCString { open($0, O_EVTONLY) }
    }

    private func gitDirPath(for worktreePath: String) -> String? {
        let gitPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(".git").path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            if isDir.boolValue {
                return gitPath
            }
            if let contents = try? String(contentsOfFile: gitPath, encoding: .utf8) {
                if let line = contents.split(separator: "\n").first,
                   line.hasPrefix("gitdir: ") {
                    let raw = line.dropFirst("gitdir: ".count)
                    let path = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if path.hasPrefix("/") {
                        return path
                    }
                    return URL(fileURLWithPath: worktreePath).appendingPathComponent(path).path
                }
            }
        }
        return nil
    }

    private func handleScopeChange() {
        reconcileSelection()
        if isVisible, source == .workingTree {
            Task { await loadUnifiedDiff() }
        }
    }

    private func handleSourceChange() {
        if source == .workingTree {
            pullRequest = nil
            startWatchingIfNeeded()
        } else {
            stopWatching()
        }
        if isVisible {
            Task { await loadDiffForCurrentSource() }
        }
    }

    private func loadDiffForCurrentSource() async {
        switch source {
        case .workingTree:
            await loadUnifiedDiff()
        case .pullRequest:
            await loadPullRequestDiff()
        }
    }

    private func entryVisible(_ entry: GitDiffEntry, in scope: GitDiffScope) -> Bool {
        switch scope {
        case .all:
            return true
        case .staged:
            return entry.hasStagedChanges
        case .unstaged:
            return entry.hasUnstagedChanges
        }
    }

    private func reconcileSelection() {
        guard let selectedPath else { return }
        guard let entry = entries.first(where: { $0.path == selectedPath }) else {
            self.selectedPath = nil
            return
        }
        if !entryVisible(entry, in: selectedScope) {
            self.selectedPath = nil
        }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        if let gitError = error as? GitDiffError {
            switch gitError {
            case .commandFailed(let message):
                return message
            }
        }
        return String(describing: error)
    }

    private func unstagePaths(for entry: GitDiffEntry) -> [String] {
        guard entry.kind != .untracked else { return [entry.path] }
        if let originalPath = entry.originalPath, !originalPath.isEmpty, originalPath != entry.path {
            return [originalPath, entry.path]
        }
        return [entry.path]
    }

    func requestScroll(to path: String) {
        selectedPath = path
        currentVisiblePath = path
        scrollNonce += 1
        scrollRequest = GitDiffScrollRequest(path: path, nonce: scrollNonce)
    }

    func toggleFileCollapsed(_ fileID: String) {
        if collapsedFileIDs.contains(fileID) {
            collapsedFileIDs.remove(fileID)
        } else {
            collapsedFileIDs.insert(fileID)
        }
    }

    func addDraftThread(path: String, anchor: DiffThreadAnchor, body: String) async {
        guard let ctx = currentReviewContext() else { return }
        let now = Date()
        let thread = DiffThread(
            id: UUID(),
            path: path,
            anchor: anchor,
            body: body,
            isResolved: false,
            createdAt: now,
            updatedAt: now
        )
        reviewDraft.threads.append(thread)
        try? draftStore.save(reviewDraft, context: ctx)
    }

    func setThreadResolved(_ id: UUID, resolved: Bool) async {
        guard let ctx = currentReviewContext() else { return }
        guard let idx = reviewDraft.threads.firstIndex(where: { $0.id == id }) else { return }
        reviewDraft.threads[idx].isResolved = resolved
        reviewDraft.threads[idx].updatedAt = Date()
        try? draftStore.save(reviewDraft, context: ctx)
    }

    func deleteThread(_ id: UUID) async {
        guard let ctx = currentReviewContext() else { return }
        reviewDraft.threads.removeAll(where: { $0.id == id })
        try? draftStore.save(reviewDraft, context: ctx)
    }

    func exportReviewJSON() -> String {
        guard let ctx = currentReviewContext() else { return "{}" }
        return draftStore.exportJSONString(reviewDraft, context: ctx)
    }

    func draftFileURL() -> URL? {
        guard let ctx = currentReviewContext() else { return nil }
        return draftStore.draftURL(for: ctx)
    }

    private func currentReviewContext() -> DiffReviewContext? {
        guard let repoRoot else { return nil }
        switch source {
        case .workingTree:
            return DiffReviewContext(
                repoRoot: repoRoot,
                source: .workingTree,
                scope: selectedScope,
                pullRequestNumber: nil
            )
        case .pullRequest:
            guard let pr = pullRequest else { return nil }
            return DiffReviewContext(
                repoRoot: repoRoot,
                source: .pullRequest,
                scope: nil,
                pullRequestNumber: pr.number
            )
        }
    }

    private func loadDraftForCurrentContext() async {
        guard let ctx = currentReviewContext() else {
            reviewDraft = .empty
            return
        }
        reviewDraft = (try? draftStore.load(context: ctx)) ?? .empty
    }

    private func stripANSIEscapeCodes(_ text: String) -> String {
        let pattern = "\\u001B\\[[0-9;]*[A-Za-z]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
