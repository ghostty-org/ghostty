import Foundation
import SwiftUI
import Darwin

struct GitDiffSelection: Hashable {
    let path: String
    let scope: GitDiffScope
}

struct GitDiffSidebarRow: Identifiable, Hashable {
    let entry: GitDiffEntry
    let scope: GitDiffScope

    var id: GitDiffSelection {
        GitDiffSelection(path: entry.path, scope: scope)
    }
}

@MainActor
final class GitDiffSidebarState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var isDiffActive: Bool = false
    @Published var panelWidth: CGFloat = 320
    @Published var repoRoot: String? = nil
    @Published var entries: [GitDiffEntry] = []
    @Published var selectedScope: GitDiffScope = .all {
        didSet {
            handleScopeChange()
        }
    }
    @Published var selectedEntry: GitDiffSelection? = nil
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var diffText: String = ""
    @Published var diffError: String? = nil
    @Published var isDiffLoading: Bool = false
    @Published var selectedWorktreePath: String? = nil
    private var diffRequestID: Int = 0

    private let store = GitDiffStore()
    private var lastCwd: URL? = nil
    private let watchQueue = DispatchQueue(label: "gitdiff.watch", qos: .utility)
    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var watchFileDescriptors: [Int32] = []
    private var watchDebounce: DispatchWorkItem?

    var selectedPath: String? {
        selectedEntry?.path
    }

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
        guard force || isVisible || isDiffActive else { return }
        if let cwd {
            lastCwd = cwd
        }

        let effectiveCwd: URL?
        if let selectedWorktreePath {
            effectiveCwd = URL(fileURLWithPath: selectedWorktreePath)
        } else {
            effectiveCwd = cwd ?? lastCwd
        }

        guard let effectiveCwd else { return }

        isLoading = true
        defer { isLoading = false }

        let root = await store.repoRoot(for: effectiveCwd.path)
        repoRoot = root
        guard let root else {
            entries = []
            errorMessage = nil
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
    }

    func refreshCurrent(force: Bool = false) async {
        await refresh(cwd: lastCwd, force: force)
    }

    func setSelectedWorktreePath(_ path: String?) async {
        selectedWorktreePath = path
        let url = path.map { URL(fileURLWithPath: $0) }
        await refresh(cwd: url, force: true)
    }

    func setVisible(_ visible: Bool, cwd: String?) async {
        isVisible = visible
        if !visible {
            stopWatching()
            isDiffActive = false
            clearDiff()
            return
        }
        let url = cwd.map { URL(fileURLWithPath: $0) }
        await refresh(cwd: url, force: true)
    }

    func diffCommand(for entry: GitDiffEntry) -> String {
        store.diffCommand(for: entry, scope: selectedScope)
    }

    func loadDiff(_ entry: GitDiffEntry, scope: GitDiffScope) async {
        guard let repoRoot else {
            diffText = ""
            diffError = "No repository"
            return
        }
        diffRequestID += 1
        let requestID = diffRequestID
        let selection = GitDiffSelection(path: entry.path, scope: scope)
        selectedEntry = selection
        isDiffLoading = true
        diffError = nil
        diffText = ""
        do {
            let text = try await store.diffText(repoRoot: repoRoot, entry: entry, scope: scope)
            guard requestID == diffRequestID, selectedEntry == selection else { return }
            diffText = text
        } catch {
            guard requestID == diffRequestID, selectedEntry == selection else { return }
            diffText = ""
            diffError = String(describing: error)
        }
        guard requestID == diffRequestID, selectedEntry == selection else { return }
        isDiffLoading = false
    }

    func clearDiff() {
        isDiffLoading = false
        diffText = ""
        diffError = nil
        selectedEntry = nil
    }

    func stage(_ entry: GitDiffEntry) async {
        guard let repoRoot else { return }
        do {
            try await store.stage(repoRoot: repoRoot, path: entry.path)
            await refreshCurrent(force: true)
            await reloadSelectedDiffIfNeeded()
        } catch {
            errorMessage = describe(error)
        }
    }

    func unstage(_ entry: GitDiffEntry) async {
        guard let repoRoot else { return }
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
        await reloadSelectedDiffIfNeeded()
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    private func startWatchingIfNeeded() {
        guard isVisible else { return }
        let worktreePath = selectedWorktreePath ?? repoRoot
        guard let worktreePath else { return }
        startWatching(worktreePath: worktreePath)
    }

    private func startWatching(worktreePath: String) {
        stopWatching()
        let paths = watchPaths(for: worktreePath)
        guard !paths.isEmpty else { return }

        for path in paths {
            let fd = openFileDescriptor(path)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .link],
                queue: watchQueue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleRefresh()
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
        watchDebounce?.cancel()
        watchDebounce = nil
        for source in watchSources {
            source.cancel()
        }
        watchSources.removeAll()
        watchFileDescriptors.removeAll()
    }

    private func scheduleRefresh() {
        watchDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.refreshCurrent(force: true) }
        }
        watchDebounce = workItem
        watchQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func watchPaths(for worktreePath: String) -> [String] {
        var paths: [String] = []
        paths.append(worktreePath)
        if let gitDir = gitDirPath(for: worktreePath) {
            paths.append(gitDir)
        }
        return paths
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
        guard let currentSelection = selectedEntry else { return }
        guard let entry = entries.first(where: { $0.path == currentSelection.path }) else {
            clearDiff()
            return
        }
        guard entryVisible(entry, in: selectedScope) else {
            clearDiff()
            return
        }
        let newSelection = GitDiffSelection(path: entry.path, scope: selectedScope)
        if newSelection == currentSelection { return }
        selectedEntry = newSelection
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
        guard let selectedEntry else { return }
        guard let entry = entries.first(where: { $0.path == selectedEntry.path }) else {
            clearDiff()
            return
        }
        if !entryVisible(entry, in: selectedScope) {
            clearDiff()
        }
    }

    private func reloadSelectedDiffIfNeeded() async {
        guard let selectedEntry else { return }
        guard let entry = entries.first(where: { $0.path == selectedEntry.path }) else {
            clearDiff()
            return
        }
        guard entryVisible(entry, in: selectedEntry.scope) else {
            clearDiff()
            return
        }
        await loadDiff(entry, scope: selectedEntry.scope)
    }

    private func describe(_ error: Error) -> String {
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
}
