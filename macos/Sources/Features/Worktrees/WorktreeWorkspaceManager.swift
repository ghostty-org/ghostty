import AppKit
import Foundation

#if os(macOS)

/// Owns a window's detached worktree workspaces (M3 switching).
///
/// A *workspace* is a worktree's whole split tree plus its last focused
/// surface — the unit of switching is the tree, never a single surface. The
/// manager stores only *detached* workspaces: the active workspace's tree is
/// the controller's live `surfaceTree`. Keeping a second (stale) copy of the
/// active tree here would retain surfaces the user has since closed, leaving
/// their ptys alive as zombies.
///
/// A workspace's binding is set at creation and never reassigned: it stays
/// keyed to the worktree it was created for even if a pane later `cd`s
/// elsewhere. The sidebar highlight tracks the active workspace, not live cwds.
@MainActor
final class WorktreeWorkspaceManager: NSObject {
    struct Workspace {
        /// The worktree this workspace is bound to. Standardized via `key(_:)`.
        let worktreePath: URL

        /// The retained split tree. Holding this keeps every surface — and its
        /// pty, scrollback, and layout — alive while detached from the view
        /// hierarchy (verified by the research spike).
        var tree: SplitTree<Ghostty.SurfaceView>

        /// Restored as first responder when the workspace is reattached. Weak:
        /// the tree owns the surface, and if it's gone we fall back to the
        /// leftmost leaf.
        weak var lastFocusedSurface: Ghostty.SurfaceView?
    }

    /// Detached workspaces keyed by standardized worktree path.
    private(set) var detached: [URL: Workspace] = [:]

    /// The worktree path bound to the currently attached surface tree. Nil
    /// until the window's original tree is adopted on the first switch.
    var activePath: URL?

    override init() {
        super.init()

        // Surfaces in a detached tree are in no controller's surfaceTree, so
        // BaseTerminalController ignores their close requests (e.g. the
        // process exiting while another worktree is shown). Handle those here
        // so dead surfaces don't linger in retained trees.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The canonical dictionary key for a worktree path. Uses filesystem
    /// canonicalization (case + symlinks) so differently-spelled paths for
    /// the same directory can't create two workspaces (see
    /// `WorktreeSidebar.canonicalPath`).
    static func key(_ url: URL) -> URL {
        URL(fileURLWithPath: WorktreeSidebar.canonicalPath(url))
    }

    /// Store a workspace that is being detached from the view hierarchy.
    func detach(_ workspace: Workspace) {
        detached[Self.key(workspace.worktreePath)] = workspace
    }

    /// Remove and return the workspace for the given worktree so its tree can
    /// be attached. Nil when the worktree has no workspace yet (first visit —
    /// the caller creates one lazily).
    func removeForAttach(_ path: URL) -> Workspace? {
        detached.removeValue(forKey: Self.key(path))
    }

    /// A deterministic detached workspace, used as a fallback target when the
    /// active workspace's last surface closes while others are still alive.
    func anyDetached() -> Workspace? {
        guard let key = detached.keys.min(by: { $0.path < $1.path }) else { return nil }
        return detached[key]
    }

    /// True when any detached surface still needs close confirmation. The
    /// attached tree is checked separately by the controller.
    var needsConfirmQuit: Bool {
        detached.values.contains { workspace in
            workspace.tree.contains(where: { $0.needsConfirmQuit })
        }
    }

    /// Drop every detached workspace, releasing their surfaces (and ptys).
    /// Called when the window closes.
    func removeAll() {
        detached.removeAll()
        activePath = nil
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let entry = detached.first(where: { $0.value.tree.contains(target) }) else { return }
        guard let node = entry.value.tree.root?.node(view: target) else { return }

        // No confirmation for detached surfaces: a detached surface can't
        // receive input, so a close request only arrives once its process has
        // already exited.
        let newTree = entry.value.tree.removing(node)
        if newTree.isEmpty {
            // Last surface gone: drop the workspace. The sidebar row remains
            // (rows mirror git worktrees, not workspaces); revisiting the
            // worktree lazily creates a fresh workspace.
            detached.removeValue(forKey: entry.key)
        } else {
            detached[entry.key]?.tree = newTree
        }
    }
}

#endif
