import AppKit
import GhosttyKit
import IOSurface

extension TerminalController {
    /// Native fullscreen attachment and SwiftUI container registration finish
    /// on subsequent run-loop turns. Repair only the still-selected live pane;
    /// a rapid second switch or a user tab selection supersedes this work.
    func finishWorkspacePresentation(attempt: Int = 0, generation: UInt64? = nil) {
        let generation = generation ?? workspacePresentationGeneration
        guard generation == workspacePresentationGeneration,
              !workspaceCoordinator.isTerminating,
              !workspaceCoordinator.native.transitioningWindows.contains(windowSessionID),
              isAvailableForWorkspace, !workspacePresentationIsParked,
              let window, (window.tabGroup?.selectedWindow ?? window) === window else { return }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        refreshWorkspaceTabs()
        tabLayoutState.sidebarHost.presentSelectedWindow(updateContent: true)
        if window.isKeyWindow, let surface = focusedSurface ?? surfaceTree.first,
           surface.window === window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(surface)
        }
        prepareWorkspaceFrame()
        window.contentView?.displayIfNeeded()
        let sidebarReady = !sidebarIsShowing || tabLayoutState.sidebarHost.liveView?.window === window
        let surfaceReady = (focusedSurface ?? surfaceTree.first)?.window === window
        guard attempt < 10, attempt == 0 || !sidebarReady || !surfaceReady else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.02)) { [weak self] in
            self?.finishWorkspacePresentation(attempt: attempt + 1, generation: generation)
        }
    }

    /// The final sidebar/layout can differ from the intermediate mixed native
    /// tab group. Fill the terminal at that final geometry before exposing it.
    func prepareWorkspaceFrame() {
        guard let targetWindow = window else { return }
        targetWindow.contentView?.superview?.layoutSubtreeIfNeeded()
        for view in surfaceTree {
            guard view.window === targetWindow, !view.isHiddenOrHasHiddenAncestor,
                  let layer = view.layer, let surface = view.surface else { continue }
            let width = Int((layer.bounds.width * layer.contentsScale).rounded(.down))
            let height = Int((layer.bounds.height * layer.contentsScale).rounded(.down))
            guard width > 0, height > 0 else { continue }
            if let image = layer.contents as? IOSurface, image.width == width, image.height == height { continue }
            ghostty_surface_draw(surface)
        }
    }

    /// AppKit gives a newly attached tab its fullscreen content rect only when
    /// selecting it. Keep that selection, the sidebar handoff, and the first
    /// correctly sized terminal frame in one nonanimated presentation update.
    func withNewTabPresentation(
        from outgoingWindow: NSWindow?,
        selectRetained: (() -> Bool)? = nil,
        show: () -> Bool
    ) -> Bool {
        guard let targetWindow = window, let outgoingWindow,
              targetWindow !== outgoingWindow,
              targetWindow.tabGroup === outgoingWindow.tabGroup else {
            let shown = show()
            if shown, tabLayout == .vertical { Self.refreshTabs(in: window?.tabGroup) }
            return shown
        }

        if !outgoingWindow.styleMask.contains(.fullScreen), let selectRetained {
            guard selectRetained() else { return false }
            syncTabPresentationAppearance()
            if tabLayout == .vertical { Self.refreshTabs(in: targetWindow.tabGroup) }
            prepareTabPresentation(from: outgoingWindow)
            targetWindow.contentView?.displayIfNeeded()
            return true
        }

        guard outgoingWindow.styleMask.contains(.fullScreen) else {
            let shown = show()
            if shown, tabLayout == .vertical { Self.refreshTabs(in: targetWindow.tabGroup) }
            return shown
        }

        // This is a tab replacement inside an existing fullscreen space, not
        // an independently opening window. Restore the normal behavior afterward.
        let animationBehavior = targetWindow.animationBehavior
        targetWindow.animationBehavior = .none
        defer { targetWindow.animationBehavior = animationBehavior }

        var shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            // A hidden window has not run TerminalWindow.syncAppearance yet.
            // Give AppKit the group's background before it exposes the window.
            targetWindow.backgroundColor = outgoingWindow.backgroundColor
            targetWindow.isOpaque = outgoingWindow.isOpaque
            shown = show()
            guard shown else { return }
            syncTabPresentationAppearance()
            if tabLayout == .vertical { Self.refreshTabs(in: targetWindow.tabGroup) }
            prepareTabPresentation(from: outgoingWindow)
            targetWindow.contentView?.displayIfNeeded()
        }
        return shown
    }

    /// Prepare only the tab about to replace the closing/selected window. Hidden
    /// tabs retain their last IOSurface, which may predate a window enlargement.
    /// Its top-left gravity leaves the newly exposed area transparent until a
    /// new frame arrives, so layout and fill that frame before AppKit reveals it.
    func prepareTabPresentation(from outgoingWindow: NSWindow) {
        guard let targetWindow = window, targetWindow !== outgoingWindow,
              outgoingWindow.tabGroup?.windows.contains(targetWindow) == true else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if !targetWindow.styleMask.contains(.fullScreen), targetWindow.frame != outgoingWindow.frame {
                targetWindow.setFrame(outgoingWindow.frame, display: false)
            }
            targetWindow.contentView?.superview?.layoutSubtreeIfNeeded()

            for surfaceView in surfaceTree {
                // A zoomed split can leave other panes detached/hidden. They
                // are not part of the incoming picture and must remain idle.
                guard surfaceView.window === targetWindow,
                      !surfaceView.isHiddenOrHasHiddenAncestor,
                      let layer = surfaceView.layer,
                      let surface = surfaceView.surface else { continue }
                let width = Int((layer.bounds.width * layer.contentsScale).rounded(.down))
                let height = Int((layer.bounds.height * layer.contentsScale).rounded(.down))
                guard width > 0, height > 0 else { continue }
                if let image = layer.contents as? IOSurface,
                   image.width == width, image.height == height { continue }

                // Unlike an automatic hidden-layer display callback, this
                // explicit request is allowed to draw while still occluded.
                // Draw once at the final size, without forcing opacity or
                // stretching the old terminal image.
                ghostty_surface_draw(surface)
            }
        }
    }
}
