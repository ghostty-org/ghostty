import Foundation
import SwiftUI
import Darwin

@MainActor
final class GitDiffSidebarState: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var isDiffActive: Bool = false
    @Published var panelWidth: CGFloat = 320
    @Published var repoRoot: String? = nil
    @Published var entries: [GitDiffEntry] = []
    @Published var selectedPath: String? = nil
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
            return
        }

        do {
            entries = try await store.statusEntries(repoRoot: root)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = String(describing: error)
        }
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
        store.diffCommand(for: entry)
    }

    func loadDiff(_ entry: GitDiffEntry) async {
        guard let repoRoot else {
            diffText = ""
            diffError = "No repository"
            return
        }
        diffRequestID += 1
        let requestID = diffRequestID
        selectedPath = entry.path
        isDiffLoading = true
        diffError = nil
        diffText = ""
        do {
            let text = try await store.diffText(repoRoot: repoRoot, entry: entry)
            guard requestID == diffRequestID, selectedPath == entry.path else { return }
            diffText = text
        } catch {
            guard requestID == diffRequestID, selectedPath == entry.path else { return }
            diffText = ""
            diffError = String(describing: error)
        }
        guard requestID == diffRequestID, selectedPath == entry.path else { return }
        isDiffLoading = false
    }

    func clearDiff() {
        isDiffLoading = false
        diffText = ""
        diffError = nil
        selectedPath = nil
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
}
