import Combine
import Foundation

/// The repository state behind the Git panel, and the operations that
/// change it.
///
/// Same shape as `GitStatusCenter`: staleness is decided on the main actor
/// before dispatching, `inflight` is inserted before the hop and removed in
/// the same hop that writes the result, and the freshness stamp is written
/// on completion rather than on dispatch so a slow call doesn't buy itself
/// a free TTL window.
///
/// Operations run silently and then refresh. When one fails, everything
/// git printed goes to `GitFailure`, which pulls out a title and a next
/// step and keeps the transcript underneath — see there for why the raw
/// output alone wasn't good enough.
@MainActor
final class GitCenter: ObservableObject {
    static let shared = GitCenter()

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let operation: String
        let failure: GitFailure
    }

    @Published private(set) var statuses: [String: GitStatus] = [:]
    @Published private(set) var branches: [String: [String]] = [:]
    @Published private(set) var stashes: [String: [String]] = [:]

    /// The operation currently running, for a progress indicator. Only one
    /// at a time per panel — a commit and a push racing each other on the
    /// same repo is never what anyone wanted.
    @Published private(set) var busy: [String: String] = [:]

    @Published var lastError: Failure?

    /// Repositories whose first status load has finished. Only ever gains
    /// entries, and the insert is guarded so it publishes once per repo
    /// instead of on every one of the periodic refreshes.
    @Published private(set) var loadedRoots: Set<String> = []

    private var inflight: Set<String> = []
    private var pendingRefresh: Set<String> = []
    private var checkedAt: [String: Date] = [:]

    /// Short: the panel is visible and the user is acting on it. The 5s
    /// metadata timer asks more often than this, and gets cache most times.
    private static let statusTTL: TimeInterval = 3

    private init() {}

    // MARK: Reading

    func status(forRoot root: String) -> GitStatus? { statuses[root] }

    func isBusy(_ root: String) -> String? { busy[root] }

    /// Whether a first status has come back for this repository — success
    /// or failure. Distinguishing "hasn't answered yet" from "answered,
    /// and there's nothing" is what lets the panel show a spinner without
    /// spinning forever on a repo git can't read.
    func hasLoaded(_ root: String) -> Bool { loadedRoots.contains(root) }

    /// Refreshes if stale. Cheap no-op otherwise, so it's safe to call from
    /// a timer and from every view update.
    ///
    /// A forced refresh that arrives while one is already running is
    /// remembered rather than dropped. That matters because every operation
    /// forces a refresh when it finishes, and the periodic one is often
    /// mid-flight at exactly that moment — dropping it left the panel
    /// showing the state from *before* the operation, with no later
    /// trigger to correct it.
    func requestStatus(root: String, force: Bool = false) {
        let stale = force || Date().timeIntervalSince(checkedAt[root] ?? .distantPast) > Self.statusTTL
        guard stale else { return }

        guard !inflight.contains(root) else {
            if force { pendingRefresh.insert(root) }
            return
        }
        inflight.insert(root)

        Task.detached(priority: .utility) {
            let status = Self.loadStatus(root: root)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let status { self.statuses[root] = status }
                self.checkedAt[root] = Date()
                self.inflight.remove(root)
                if !self.loadedRoots.contains(root) { self.loadedRoots.insert(root) }

                if self.pendingRefresh.remove(root) != nil {
                    self.requestStatus(root: root, force: true)
                }
            }
        }
    }

    func requestBranches(root: String) {
        Task.detached(priority: .userInitiated) {
            let names = Self.loadBranches(root: root)
            await MainActor.run { [weak self] in
                self?.branches[root] = names
            }
        }
    }

    func requestStashes(root: String) {
        Task.detached(priority: .userInitiated) {
            let entries = Self.loadStashes(root: root)
            await MainActor.run { [weak self] in
                self?.stashes[root] = entries
            }
        }
    }

    // MARK: Loading (background)

    /// `core.quotePath=false` keeps non-ASCII paths as real UTF-8 instead of
    /// C-escaped octal, which is what makes accented filenames both legible
    /// and stageable.
    nonisolated private static func loadStatus(root: String) -> GitStatus? {
        let result = GitCommand.run(
            [
                "-c", "core.quotePath=false",
                "status", "--porcelain=v2", "--branch", "--untracked-files=all",
            ],
            in: root
        )
        guard result.succeeded else { return nil }
        return GitStatus.parse(porcelainV2: result.stdout)
    }

    nonisolated private static func loadBranches(root: String) -> [String] {
        guard let output = GitCommand.output(
            ["branch", "--format=%(refname:short)", "--sort=-committerdate"],
            in: root
        ) else { return [] }

        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func loadStashes(root: String) -> [String] {
        guard let output = GitCommand.output(
            ["stash", "list", "--format=%gd: %s"],
            in: root
        ) else { return [] }

        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Operations

    func stage(_ paths: [String], in root: String) {
        perform("Stage", in: root, arguments: ["add", "--"] + paths)
    }

    func stageAll(in root: String) {
        perform("Stage All", in: root, arguments: ["add", "-A"])
    }

    /// `restore --staged` rather than `reset HEAD` — it does the same thing
    /// on a repo with commits and also works on one that has none yet,
    /// where `HEAD` doesn't resolve.
    func unstage(_ paths: [String], in root: String) {
        perform("Unstage", in: root, arguments: ["restore", "--staged", "--"] + paths)
    }

    func unstageAll(in root: String) {
        perform("Unstage All", in: root, arguments: ["reset"])
    }

    /// Throws away working-tree changes. Untracked files aren't in git at
    /// all, so `restore` can't touch them — those are deleted outright,
    /// which is why the caller must confirm first.
    func discard(_ changes: [GitFileChange], in root: String) {
        let tracked = changes.filter { !$0.isUntrackedOnly }.map(\.path)
        let untracked = changes.filter(\.isUntrackedOnly).map(\.path)

        Task.detached(priority: .userInitiated) {
            var failure: ShellCommand.Result?

            if !tracked.isEmpty {
                let result = GitCommand.run(
                    ["restore", "--"] + tracked,
                    in: root,
                    timeout: GitCommand.mutateTimeout
                )
                if !result.succeeded { failure = result }
            }

            for path in untracked {
                let url = URL(fileURLWithPath: root).appendingPathComponent(path)
                try? FileManager.default.removeItem(at: url)
            }

            await MainActor.run { [weak self] in
                self?.finish("Discard", root: root, failure: failure)
            }
        }
    }

    /// Commits, optionally staging everything first.
    ///
    /// The staging has to be part of *this* operation rather than a
    /// separate call before it. Every operation takes the `busy` lock, so
    /// firing `stageAll` and then `commit` meant the commit hit the lock
    /// the stage was still holding and was silently dropped — the files
    /// ended up staged and nothing was ever committed, with no error to
    /// explain it.
    func commit(message: String, amend: Bool, stageAll: Bool, in root: String) {
        var commitArguments = ["commit", "-m", message]
        if amend { commitArguments.append("--amend") }

        let steps = stageAll ? [["add", "-A"], commitArguments] : [commitArguments]
        perform("Commit", in: root, steps: steps, timeout: GitCommand.mutateTimeout)
    }

    func push(in root: String) {
        perform("Push", in: root, arguments: ["push"], timeout: GitCommand.networkTimeout)
    }

    /// A branch with no upstream needs to say where it's going and record
    /// it, which is the whole difference between this and `push`.
    func publish(branch: String, in root: String) {
        perform(
            "Publish Branch",
            in: root,
            arguments: ["push", "-u", "origin", branch],
            timeout: GitCommand.networkTimeout
        )
    }

    func pull(in root: String) {
        perform("Pull", in: root, arguments: ["pull"], timeout: GitCommand.networkTimeout)
    }

    func fetch(in root: String) {
        perform("Fetch", in: root, arguments: ["fetch", "--prune"], timeout: GitCommand.networkTimeout)
    }

    func checkout(branch: String, in root: String) {
        perform("Switch Branch", in: root, arguments: ["checkout", branch], timeout: GitCommand.mutateTimeout)
    }

    func createBranch(named name: String, in root: String) {
        perform("Create Branch", in: root, arguments: ["checkout", "-b", name], timeout: GitCommand.mutateTimeout)
    }

    /// `--include-untracked` so stashing actually clears the tree; without
    /// it new files stay behind and the "clean slate" the user asked for
    /// isn't one.
    func stashPush(message: String?, in root: String) {
        var arguments = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty { arguments += ["-m", message] }
        perform("Stash", in: root, arguments: arguments, timeout: GitCommand.mutateTimeout)
    }

    func stashPop(in root: String) {
        perform("Pop Stash", in: root, arguments: ["stash", "pop"], timeout: GitCommand.mutateTimeout)
    }

    // MARK: Plumbing

    private func perform(
        _ name: String,
        in root: String,
        arguments: [String],
        timeout: TimeInterval = GitCommand.queryTimeout
    ) {
        perform(name, in: root, steps: [arguments], timeout: timeout)
    }

    /// Runs commands in order, stopping at the first failure.
    ///
    /// One `busy` lock covers the whole sequence, which is what makes
    /// multi-step operations (stage-then-commit) safe: they can't be
    /// interleaved with anything else, and a later step never runs against
    /// the state an earlier failure left behind.
    private func perform(
        _ name: String,
        in root: String,
        steps: [[String]],
        timeout: TimeInterval = GitCommand.queryTimeout
    ) {
        guard busy[root] == nil, !steps.isEmpty else { return }
        busy[root] = name

        Task.detached(priority: .userInitiated) {
            var failure: ShellCommand.Result?

            for step in steps {
                let result = GitCommand.run(step, in: root, timeout: timeout)
                guard result.succeeded else {
                    failure = result
                    break
                }
            }

            await MainActor.run { [weak self] in
                self?.finish(name, root: root, failure: failure)
            }
        }
    }

    private func finish(_ name: String, root: String, failure: ShellCommand.Result?) {
        busy[root] = nil

        // Cleared on success as well as set on failure, so a stale error
        // can't outlive the problem it described.
        //
        // Both streams are handed to the parser: git splits a single
        // explanation across them routinely — `pull` writes the fetch
        // transcript to stderr and the refusal to stdout — and reading
        // only one loses half the story.
        lastError = failure.map {
            Failure(
                operation: name,
                failure: GitFailure(
                    operation: name,
                    output: [$0.stderr, $0.stdout]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                )
            )
        }
        requestStatus(root: root, force: true)
        requestBranches(root: root)
        requestStashes(root: root)
    }
}
