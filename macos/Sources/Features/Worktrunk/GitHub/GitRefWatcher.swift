import Foundation
import Darwin

/// Watches `.git/refs/remotes/origin/` for changes to detect pushes
final class GitRefWatcher {
    typealias ChangeHandler = (String) -> Void  // repoPath

    private let queue = DispatchQueue(label: "dev.sidequery.Ghostree.gitrefwatcher", qos: .utility)
    private var watchers: [String: WatcherState] = [:]  // repoPath -> state
    private let onChange: ChangeHandler

    private struct WatcherState {
        var source: DispatchSourceFileSystemObject
        var fd: Int32
        var debounce: DispatchWorkItem?
    }

    init(onChange: @escaping ChangeHandler) {
        self.onChange = onChange
    }

    deinit {
        stopAll()
    }

    // MARK: - Public API

    func watch(repoPath: String) {
        queue.async { [weak self] in
            self?.startWatching(repoPath: repoPath)
        }
    }

    func unwatch(repoPath: String) {
        queue.async { [weak self] in
            self?.stopWatching(repoPath: repoPath)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for repoPath in self.watchers.keys {
                self.stopWatching(repoPath: repoPath)
            }
        }
    }

    // MARK: - Private

    private func startWatching(repoPath: String) {
        // Already watching?
        if watchers[repoPath] != nil { return }

        // Find the refs/remotes/origin directory
        guard let refsPath = remoteRefsPath(for: repoPath) else { return }

        let fd = refsPath.withCString { open($0, O_EVTONLY) }
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleChange(repoPath: repoPath)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()

        watchers[repoPath] = WatcherState(source: source, fd: fd, debounce: nil)
    }

    private func stopWatching(repoPath: String) {
        guard let state = watchers.removeValue(forKey: repoPath) else { return }
        state.debounce?.cancel()
        state.source.cancel()
    }

    private func handleChange(repoPath: String) {
        guard var state = watchers[repoPath] else { return }

        // Debounce: git operations often write multiple files
        state.debounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange(repoPath)
        }
        state.debounce = workItem
        watchers[repoPath] = state

        queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func remoteRefsPath(for repoPath: String) -> String? {
        // Get the .git directory (handling worktrees)
        guard let gitDir = gitDirPath(for: repoPath) else { return nil }

        // For worktrees, refs/remotes is in the main repo's git dir
        let commonDir = commonGitDir(gitDir: gitDir)
        let refsPath = URL(fileURLWithPath: commonDir)
            .appendingPathComponent("refs")
            .appendingPathComponent("remotes")
            .appendingPathComponent("origin")
            .path

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: refsPath, isDirectory: &isDir), isDir.boolValue {
            return refsPath
        }

        // Fall back to refs/remotes (in case origin doesn't exist yet)
        let remotesPath = URL(fileURLWithPath: commonDir)
            .appendingPathComponent("refs")
            .appendingPathComponent("remotes")
            .path

        if FileManager.default.fileExists(atPath: remotesPath, isDirectory: &isDir), isDir.boolValue {
            return remotesPath
        }

        return nil
    }

    private func gitDirPath(for worktreePath: String) -> String? {
        let gitPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(".git").path
        var isDir: ObjCBool = false

        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            if isDir.boolValue {
                return gitPath
            }
            // Worktree: .git is a file pointing to the actual git dir
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

    private func commonGitDir(gitDir: String) -> String {
        // For worktrees, the commondir file points to the main repo
        let commonDirFile = URL(fileURLWithPath: gitDir).appendingPathComponent("commondir").path

        if let contents = try? String(contentsOfFile: commonDirFile, encoding: .utf8) {
            let relative = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !relative.isEmpty {
                let resolved = URL(fileURLWithPath: gitDir)
                    .appendingPathComponent(relative)
                    .standardized
                    .path
                return resolved
            }
        }

        return gitDir
    }
}
