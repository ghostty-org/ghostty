import AppKit

// worktree-sidebar: M3 — workspace switching. The active workspace's split
// tree is detached and retained (processes, scrollback, and layout survive)
// and the target worktree's tree is attached in its place. See
// WorktreeWorkspaceManager for the ownership model.

extension TerminalController {
    /// The workspace manager, created on first use.
    private func ensureWorktreeWorkspaces() -> WorktreeWorkspaceManager {
        if let worktreeWorkspaces { return worktreeWorkspaces }
        let manager = WorktreeWorkspaceManager()
        worktreeWorkspaces = manager
        return manager
    }

    /// True when any surface in this window — the attached tree or a detached
    /// worktree workspace — still needs close confirmation.
    var anySurfaceNeedsConfirmQuit: Bool {
        surfaceTree.contains(where: { $0.needsConfirmQuit }) ||
            (worktreeWorkspaces?.needsConfirmQuit ?? false)
    }

    /// Switch the window's content to the workspace bound to `worktree`.
    ///
    /// The active tree is detached and retained, and the target worktree's
    /// tree is attached — created lazily with a single surface whose
    /// working directory is the worktree path on first visit. Revisiting
    /// restores the exact layout and refocuses the last focused surface.
    /// No-op when the worktree is already active.
    func switchToWorktree(_ worktree: Worktree) {
        guard let viewModel = worktreeSidebarViewController?.viewModel else { return }
        guard let ghosttyApp = ghostty.app else { return }
        let manager = ensureWorktreeWorkspaces()
        let targetKey = WorktreeWorkspaceManager.key(worktree.path)

        // Resolve the binding of the currently attached tree. Before the
        // first switch the window's original tree has no binding yet; adopt
        // it under the worktree the sidebar considers active (the one
        // containing the window's cwd at the last refresh).
        let currentKey: URL? = manager.activePath
            ?? viewModel.selectedWorktree.map { WorktreeWorkspaceManager.key($0.path) }

        if currentKey == targetKey {
            // Already showing this worktree; just make sure the implicit
            // binding is adopted and the highlight agrees.
            manager.activePath = targetKey
            viewModel.selectedWorktree = worktree
            return
        }

        guard let currentKey else {
            // TODO(worktree-sidebar): the attached tree resolves to no listed
            // worktree (cwd outside the repository's worktrees), so there is
            // nowhere to detach it to. Refuse to switch rather than silently
            // dropping live surfaces.
            Ghostty.logger.warning("worktree-sidebar: current tree has no worktree binding; switch aborted")
            return
        }

        // Detach the active workspace, retaining its tree (and ptys).
        manager.detach(.init(
            worktreePath: currentKey,
            tree: surfaceTree,
            lastFocusedSurface: focusedSurface))

        // Undo entries (e.g. "Close Terminal") capture whole surface trees.
        // Performing one after a switch would attach a tree belonging to a
        // different workspace and release the attached one, killing its
        // processes. Invalidate them rather than risk that.
        undoManager?.removeAllActions(withTarget: self)

        // Attach the target workspace, creating it lazily on first visit.
        let focusTarget: Ghostty.SurfaceView?
        if let existing = manager.removeForAttach(targetKey) {
            surfaceTree = existing.tree
            focusTarget = existing.lastFocusedSurface ?? existing.tree.root?.leftmostLeaf()
        } else {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = worktree.path.path
            let surfaceView = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
            surfaceTree = SplitTree(view: surfaceView)
            focusTarget = surfaceView
        }

        manager.activePath = targetKey
        viewModel.selectedWorktree = worktree

        if let focusTarget {
            focusedSurface = focusTarget
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget)
            }
        }
    }

    /// Cycle to the next/previous worktree in sidebar order, wrapping.
    /// Backs the `goto_worktree` keybind (see `gotoWorktree`).
    func cycleWorktree(_ direction: Ghostty.WorktreeFocusDirection, viewModel: WorktreeSidebarViewModel) {
        let current = worktreeWorkspaces?.activePath ?? viewModel.selectedWorktree?.path
        let target = WorktreeSidebar.cycleTarget(
            in: viewModel.worktrees,
            from: current,
            offset: direction == .next ? 1 : -1)
        guard let target else { return }
        switchToWorktree(target)
    }

    /// Attach a detached workspace after the active workspace's last surface
    /// closed, instead of closing the window (which would tear down every
    /// other workspace's live processes). See `replaceSurfaceTree`.
    func attachFallbackWorkspace(_ workspace: WorktreeWorkspaceManager.Workspace) {
        guard let manager = worktreeWorkspaces else { return }
        let key = WorktreeWorkspaceManager.key(workspace.worktreePath)
        _ = manager.removeForAttach(key)

        // Same tree-capture hazard as in switchToWorktree.
        undoManager?.removeAllActions(withTarget: self)

        surfaceTree = workspace.tree
        manager.activePath = key

        // Move the sidebar highlight to the fallback's worktree when it is
        // still listed (it may have been deleted on disk since the refresh).
        if let viewModel = worktreeSidebarViewController?.viewModel {
            viewModel.selectedWorktree = viewModel.worktrees
                .first { WorktreeWorkspaceManager.key($0.path) == key }
        }

        if let focusTarget = workspace.lastFocusedSurface ?? workspace.tree.root?.leftmostLeaf() {
            focusedSurface = focusTarget
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusTarget)
            }
        }
    }
}
