import Foundation
import AppKit

/// Event-driven PR status manager with smart refresh
/// - Watches for pushes via GitRefWatcher
/// - Polls only when CI is pending
/// - Caches terminal states forever (until invalidated by push)
@MainActor
final class PRStatusManager: ObservableObject {
    @Published private(set) var statusByWorktreePath: [String: PRStatusCacheEntry] = [:]
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var errorMessage: String?

    private var refWatcher: GitRefWatcher?
    private var pendingPollers: [String: Task<Void, Never>] = [:]  // worktreePath -> polling task
    private var appFocusObserver: Any?
    private var lastAppFocusRefresh: Date = .distantPast

    private let pollInterval: TimeInterval = 20  // seconds between polls for pending CI
    private let staleDuration: TimeInterval = 300  // 5 minutes before refresh on focus

    /// Called when a push is detected for a repo. Provides the repo path.
    var onPushDetected: ((String) async -> Void)?

    /// Called when app regains focus and statuses are stale.
    var onAppFocusRefresh: (() async -> Void)?

    // MARK: - Initialization

    init() {
        setupRefWatcher()
        setupAppFocusObserver()
        Task {
            isAvailable = await GHClient.isAvailable()
        }
    }

    deinit {
        refWatcher?.stopAll()
        if let observer = appFocusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for task in pendingPollers.values {
            task.cancel()
        }
    }

    // MARK: - Public API

    func prStatus(for worktreePath: String) -> PRStatus? {
        statusByWorktreePath[worktreePath]?.status
    }

    func ciState(for worktreePath: String) -> CIState {
        statusByWorktreePath[worktreePath]?.status.overallCIState ?? .none
    }

    /// Start monitoring a repository for PR status changes
    func startMonitoring(repoPath: String) {
        refWatcher?.watch(repoPath: repoPath)
    }

    /// Stop monitoring a repository
    func stopMonitoring(repoPath: String) {
        refWatcher?.unwatch(repoPath: repoPath)
    }

    /// Fetch PR status for a worktree (call on selection, initial load, etc.)
    func fetchIfNeeded(worktreePath: String, branch: String, repoPath: String) async {
        // Already have fresh terminal state? Skip.
        if let existing = statusByWorktreePath[worktreePath],
           existing.isTerminal && !existing.isStale {
            return
        }

        await fetch(worktreePath: worktreePath, branch: branch, repoPath: repoPath)
    }

    /// Force refresh (after push detected, manual refresh, etc.)
    func refresh(worktreePath: String, branch: String, repoPath: String) async {
        // Invalidate cache
        statusByWorktreePath[worktreePath] = nil
        await fetch(worktreePath: worktreePath, branch: branch, repoPath: repoPath)
    }

    /// Refresh all worktrees for a repo (after push detected)
    func refreshRepo(repoPath: String, worktrees: [(path: String, branch: String)]) async {
        for wt in worktrees {
            statusByWorktreePath[wt.path] = nil
        }

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    await self.fetch(worktreePath: wt.path, branch: wt.branch, repoPath: repoPath)
                }
            }
        }
    }

    // MARK: - Private: Fetching

    private func fetch(worktreePath: String, branch: String, repoPath: String) async {
        guard isAvailable else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if let prStatus = try await GHClient.prForBranch(repoPath: repoPath, branch: branch) {
                let entry = PRStatusCacheEntry(
                    status: prStatus,
                    isTerminal: prStatus.overallCIState.isTerminal
                )
                statusByWorktreePath[worktreePath] = entry
                errorMessage = nil

                // Start polling if CI is pending
                if !entry.isTerminal {
                    startPolling(worktreePath: worktreePath, branch: branch, repoPath: repoPath)
                } else {
                    stopPolling(worktreePath: worktreePath)
                }
            } else {
                // No PR for this branch
                statusByWorktreePath[worktreePath] = nil
                stopPolling(worktreePath: worktreePath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private: Polling (only for pending CI)

    private func startPolling(worktreePath: String, branch: String, repoPath: String) {
        // Already polling?
        if pendingPollers[worktreePath] != nil { return }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.pollInterval ?? 20) * 1_000_000_000)

                guard !Task.isCancelled else { break }

                await self?.fetch(worktreePath: worktreePath, branch: branch, repoPath: repoPath)

                // Stop if terminal
                if let entry = self?.statusByWorktreePath[worktreePath], entry.isTerminal {
                    break
                }
            }
        }

        pendingPollers[worktreePath] = task
    }

    private func stopPolling(worktreePath: String) {
        pendingPollers[worktreePath]?.cancel()
        pendingPollers.removeValue(forKey: worktreePath)
    }

    // MARK: - Private: GitRefWatcher (push detection)

    private func setupRefWatcher() {
        refWatcher = GitRefWatcher { [weak self] repoPath in
            Task { @MainActor in
                await self?.handlePushDetected(repoPath: repoPath)
            }
        }
    }

    private func handlePushDetected(repoPath: String) async {
        // Call the callback if set, otherwise this is a no-op
        await onPushDetected?(repoPath)
    }

    // MARK: - Private: App Focus

    private func setupAppFocusObserver() {
        appFocusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppFocus()
            }
        }
    }

    private func handleAppFocus() async {
        let now = Date()
        guard now.timeIntervalSince(lastAppFocusRefresh) > staleDuration else { return }
        lastAppFocusRefresh = now

        // Call the callback if set
        await onAppFocusRefresh?()
    }
}
