import AppKit
import Combine

/// The Claude Code plans on disk, and which project each belongs to.
///
/// App-wide rather than per window: the plans directory is one directory, and
/// watching it once is cheaper than once per window. Which *terminals* show a
/// tag is decided per row, by asking whether its working directory is inside
/// the plan's project.
///
/// The attribution is to a **project**, not to a terminal. That is what the
/// data supports — see `ClaudePlanIndex` — so three tabs in the same repo all
/// show the tag. It is also true to what a plan is: it belongs to the work,
/// not to the window that happened to be focused.
@MainActor
final class ClaudePlanCenter: ObservableObject {
    static let shared = ClaudePlanCenter()

    /// The newest plan per encoded project.
    ///
    /// Only the newest: a project accumulates plans, and a row can show one
    /// tag. The one being worked on is the one just written.
    @Published private(set) var latestByProject: [String: ClaudePlanIndex.Plan] = [:]

    private var watcher: DirectoryWatcher?
    private var isScanning = false

    private init() {
        start()
    }

    private func start() {
        let watcher = DirectoryWatcher()
        watcher.onChange = { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        watcher.watch([ClaudePlanIndex.plansDirectory])
        self.watcher = watcher

        rescan()
    }

    /// The plan to offer a terminal sitting at `workingDirectory`.
    func plan(forTerminalAt workingDirectory: String?) -> ClaudePlanIndex.Plan? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }

        return latestByProject
            .filter { ClaudePlanIndex.project($0.key, contains: workingDirectory) }
            // The deepest matching project wins: a plan written for a
            // subdirectory is more specific than one for its parent.
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Reads the directory and resolves each plan's project.
    ///
    /// Off the main thread: resolving means reading the tail of transcripts,
    /// which are large. Guarded against overlap because a burst of writes to
    /// the plans directory is one scan's worth of news, not several.
    private func rescan() {
        guard !isScanning else { return }
        isScanning = true

        Task { [weak self] in
            let resolved = await Task.detached(priority: .utility) {
                var byProject: [String: ClaudePlanIndex.Plan] = [:]
                for plan in ClaudePlanIndex.plans() {
                    guard let project = ClaudePlanIndex.encodedProject(for: plan) else { continue }
                    // Newest first from `plans()`, so the first one wins.
                    if byProject[project] == nil { byProject[project] = plan }
                }
                return byProject
            }.value

            await MainActor.run {
                guard let self else { return }
                self.isScanning = false
                if self.latestByProject != resolved { self.latestByProject = resolved }
            }
        }
    }
}
