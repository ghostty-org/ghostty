import AppKit

/// All native workspace topology changes pass this boundary. The model is
/// committed only after apply succeeds. Injected operations exercise real
/// rollback without depending on AppKit throwing an Objective-C exception.
@MainActor
final class TerminalWorkspaceNativeAdapter {
    struct Group {
        var members: [TerminalController]
        var selected: TerminalController
        var tabLayout: Ghostty.Config.MacOSTabLayout
        var visible: Bool
        var layout: VerticalTabWindowLayoutState
        var scrollOffset: Double?
    }

    var attach: (NSWindow, NSWindow, NSWindow.OrderingMode) -> Bool = {
        $0.addTabbedWindowSafely($1, ordered: $2)
    }
    var show: (TerminalController) -> Bool = { $0.showWindowSafely(nil) }
    private struct Transition {
        weak var window: NSWindow?
        let host: UUID
    }
    private var transitions: [ObjectIdentifier: Transition] = [:]
    var transitioningWindows: Set<UUID> {
        Set(transitions.values.compactMap { $0.window == nil ? nil : $0.host })
    }
    private(set) var nonNativeProjectionWindows = Set<UUID>()
    private(set) var retainedVerticalHosts = Set<UUID>()
    private var observers: [NSObjectProtocol] = []
    var transitionCompleted: ((UUID) -> Void)?

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow,
                          let controller = window.windowController as? TerminalController,
                          controller.workspaceCoordinator.native === self else { return }
                    self.transitions[ObjectIdentifier(window)] = Transition(window: window, host: controller.windowSessionID)
                }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow,
                          let controller = window.windowController as? TerminalController,
                          controller.workspaceCoordinator.native === self else { return }
                    let host = self.transitions.removeValue(forKey: ObjectIdentifier(window))?.host ?? controller.windowSessionID
                    // AppKit still owns its fullscreen stack while delivering
                    // this notification. Drain queued workspace commands only
                    // after the native transition has completely unwound.
                    self.scheduleTransitionCompletion(in: host)
                }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                if let host = self?.transitions.removeValue(forKey: ObjectIdentifier(window))?.host {
                    self?.scheduleTransitionCompletion(in: host)
                }
            }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func beginNonNativeProjection(in host: UUID) { nonNativeProjectionWindows.insert(host) }
    func finishNonNativeProjection(in host: UUID) { nonNativeProjectionWindows.remove(host) }
    func forgetRetainedHost(_ host: UUID) { retainedVerticalHosts.remove(host) }

    func fullscreenTransitionFailed(in host: UUID) {
        transitions = transitions.filter { $0.value.host != host && $0.value.window != nil }
        scheduleTransitionCompletion(in: host)
    }

    private func scheduleTransitionCompletion(in host: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.transitioningWindows.contains(host) else { return }
            self.transitionCompleted?(host)
        }
    }

    func preflightError(_ controllers: [TerminalController]) -> String? {
        for controller in controllers {
            if !controller.isAvailableForWorkspace {
                return WorkspaceL10n.text("The terminal window is no longer available.", "终端窗口已不可用。")
            }
            if controller.window?.attachedSheet != nil {
                return WorkspaceL10n.text("Finish the open dialog before changing workspaces.", "请先完成当前对话框，再操作工作区。")
            }
            if transitioningWindows.contains(controller.windowSessionID) {
                return WorkspaceL10n.text("The window is changing fullscreen mode. Try again when it finishes.", "窗口正在切换全屏状态，请完成后重试。")
            }
            if controller.window?.tabbingMode == .disallowed {
                return WorkspaceL10n.text("This window style does not support workspace tab groups.", "当前窗口样式不支持工作区标签组。")
            }
        }
        return nil
    }

    func canApply(_ controllers: [TerminalController]) -> Bool { preflightError(controllers) == nil }

    /// Incoming windows join the existing fullscreen stack before outgoing
    /// members leave. At no point may that native fullscreen container be empty.
    func apply(_ groups: [Group], previous: [Group], focus: TerminalController?,
               retainingVerticalHosts requestedHosts: Set<UUID>? = nil,
               restoringTopology: Bool = false) -> Bool {
        // Bind the destination's own presentation before AppKit selects it.
        // The native stack temporarily contains both workspaces during handoff;
        // its associated layout must never supply the outgoing header/rows.
        for group in groups {
            for member in group.members {
                if member.tabLayout != group.tabLayout { member.adoptTabLayout(group.tabLayout) }
                member.tabLayoutState = group.layout
            }
        }
        let previousVisible = previous.filter(\.visible)
        let all = previous.flatMap(\.members) + groups.flatMap(\.members)
        var modes: [UUID: FullscreenMode] = [:]
        var seen = Set<ObjectIdentifier>()
        for controller in all where seen.insert(ObjectIdentifier(controller)).inserted {
            guard let style = controller.fullscreenStyle, style.isFullscreen, !style.supportsTabs else { continue }
            modes[controller.windowSessionID] = style.fullscreenMode
            nonNativeProjectionWindows.insert(controller.windowSessionID)
            // Borderless fullscreen cannot join native tabs. Normalize inside
            // the presentation transaction, then enter the same mode on the
            // committed destination after native membership is complete.
            style.exit()
        }
        var completed = false
        let retainedBefore = retainedVerticalHosts
        let affectedHosts = Set(all.map(\.windowSessionID))
        let retainedHosts = Set(groups.filter {
            $0.visible && $0.tabLayout == .vertical &&
                modes[$0.selected.windowSessionID] == nil &&
                (requestedHosts?.contains($0.selected.windowSessionID) ?? true)
        }.map { $0.selected.windowSessionID })
        retainedVerticalHosts.subtract(affectedHosts)
        retainedVerticalHosts.formUnion(retainedHosts)
        defer {
            if !completed { retainedVerticalHosts = retainedBefore }
            let destinations = completed ? groups : previous
            for (host, mode) in modes {
                guard let target = destinations.first(where: { $0.visible && $0.selected.windowSessionID == host })?.selected else { continue }
                target.toggleFullscreen(mode: mode)
            }
        }
        for group in groups where group.visible {
            guard let selectedWindow = group.selected.window else { return false }
            let outgoing = previousVisible.first {
                $0.selected.windowSessionID == group.selected.windowSessionID
            }?.selected.window
            var anchor = outgoing ?? selectedWindow
            let physicalMembers = physicalMembers(for: group, in: groups, retaining: retainedHosts)
            let activeIDs = Set(group.members.map(ObjectIdentifier.init))
            let keepsExistingGroup = retainedBefore.contains(group.selected.windowSessionID) &&
                retainedHosts.contains(group.selected.windowSessionID)
            let attachedWindows = anchor.tabGroup?.windows ?? [anchor]
            var attached = Set(attachedWindows.map(ObjectIdentifier.init))
            if retainedHosts.contains(group.selected.windowSessionID) {
                anchor = attachedWindows.last ?? anchor
            }
            for member in physicalMembers {
                guard let window = member.window else { return false }
                let alreadyAttached = attached.contains(ObjectIdentifier(window))
                if !activeIDs.contains(ObjectIdentifier(member)), alreadyAttached { continue }
                if activeIDs.contains(ObjectIdentifier(member)) {
                    member.cancelWorkspacePendingPresentation()
                    // A warm retained group only prepares its selected tab.
                    // Other tabs keep their geometry until selected.
                    if !keepsExistingGroup || member === group.selected, let outgoing,
                       !window.styleMask.contains(.fullScreen), window.frame != outgoing.frame {
                        window.setFrame(outgoing.frame, display: false)
                    }
                }
                if window !== anchor && !alreadyAttached {
                    guard attach(anchor, window, .above) else { return false }
                    attached.insert(ObjectIdentifier(window))
                }
                member.finishWorkspaceTabAttachment()
                anchor = window
            }
            if outgoing !== selectedWindow {
                guard group.selected.withNewTabPresentation(from: outgoing, show: { self.show(group.selected) }) else { return false }
            }
        }
        // Only the completed destination can now occupy the fullscreen stack.
        for group in groups where !group.visible {
            for member in group.members {
                guard let window = member.window else { continue }
                if retainedHosts.contains(group.selected.windowSessionID) {
                    if !member.workspacePresentationIsParked { member.cancelWorkspacePendingPresentation() }
                    continue
                }
                // Already parked groups are not part of this handoff. Even
                // reading tabGroup can recreate AppKit's discarded tab stack.
                if !restoringTopology,
                   !retainedBefore.contains(group.selected.windowSessionID),
                   member.workspacePresentationIsParked && !window.isVisible { continue }
                member.cancelWorkspacePendingPresentation()
                // Removing the sole member creates an empty native window
                // stack which AppKit can later reuse when entering fullscreen.
                // A singleton only needs parking, not detachment.
                if let native = window.tabGroup, native.windows.count > 1 {
                    native.removeWindow(window)
                }
                window.orderOut(nil)
            }
        }
        for group in groups where group.visible {
            guard let window = group.selected.window else { return false }
            let windows = physicalMembers(for: group, in: groups, retaining: retainedHosts).compactMap(\.window)
            if let native = window.tabGroup {
                let currentOrder = native.windows
                guard Set(currentOrder.map(ObjectIdentifier.init)) == Set(windows.map(ObjectIdentifier.init)) else { return false }
                let desiredOrder = retainedHosts.contains(group.selected.windowSessionID)
                    ? retainedOrder(currentOrder, groups: groups, host: group.selected.windowSessionID) : windows
                // insertWindow moves an existing member without explicitly
                // emptying the native stack or removing its selected anchor.
                var order = currentOrder
                for (index, member) in desiredOrder.enumerated() where order[index] !== member {
                    native.insertWindow(member, at: index)
                    order.removeAll { $0 === member }
                    order.insert(member, at: index)
                }
                guard native.windows == desiredOrder else { return false }
                if native.selectedWindow !== window { native.selectedWindow = window }
            } else if windows.count != 1 { return false }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if group.selected === focus { window.makeKeyAndOrderFront(nil) } else if !window.isVisible { window.orderFront(nil) }
        }
        completed = true
        return true
    }

    private func physicalMembers(for group: Group, in groups: [Group], retaining hosts: Set<UUID>) -> [TerminalController] {
        let host = group.selected.windowSessionID
        guard hosts.contains(host) else { return group.members }
        return groups.filter { $0.selected.windowSessionID == host }.flatMap(\.members)
    }

    private func retainedOrder(_ windows: [NSWindow], groups: [Group], host: UUID) -> [NSWindow] {
        var result = windows
        for group in groups where group.selected.windowSessionID == host {
            let members = group.members.compactMap(\.window)
            let ids = Set(members.map(ObjectIdentifier.init))
            let positions = result.indices.filter { ids.contains(ObjectIdentifier(result[$0])) }
            for (index, member) in zip(positions, members) { result[index] = member }
        }
        return result
    }

    /// Compensation deliberately uses the real native operation, rather than an
    /// injected failing operation. A failed compensation is reported to callers.
    func rollback(_ previous: [Group], attempted: [Group], focus: TerminalController?,
                  retainingVerticalHosts: Set<UUID>? = nil) -> Bool {
        let savedAttach = attach
        let savedShow = show
        attach = { $0.addTabbedWindowSafely($1, ordered: $2) }
        show = { $0.showWindowSafely(nil) }
        defer { attach = savedAttach; show = savedShow }
        let originalIDs = Set(previous.flatMap(\.members).map(\.tabSessionID))
        let additions = attempted.compactMap { group -> Group? in
            let members = group.members.filter { !originalIDs.contains($0.tabSessionID) }
            guard let selected = members.first else { return nil }
            return Group(members: members, selected: selected, tabLayout: group.tabLayout,
                visible: false, layout: group.layout)
        }
        return apply(previous + additions, previous: attempted, focus: focus,
                     retainingVerticalHosts: retainingVerticalHosts, restoringTopology: true)
    }

    func publish(_ groups: [Group]) {
        for group in groups {
            for member in group.members {
                member.workspacePresentationIsParked = !group.visible
                member.tabLayoutState = group.layout
            }
            guard group.visible else { continue }
            let selected = group.selected
            group.layout.sidebarHost.restoreScrollOffset(group.scrollOffset)
            selected.window?.tabGroup?.setGhosttyTerminalShellLayoutState(group.layout)
            selected.refreshWorkspaceTabs()
            group.layout.sidebarHost.presentSelectedWindow(updateContent: true)
            selected.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            group.layout.sidebarHost.restoreScrollOffset(group.scrollOffset)
            selected.prepareWorkspaceFrame()
            selected.window?.contentView?.displayIfNeeded()
            if let surface = selected.focusedSurface ?? selected.surfaceTree.first,
               let window = selected.window, window.isKeyWindow, surface.window === window {
                window.makeFirstResponder(surface)
            }
            selected.finishWorkspacePresentation()
        }
    }
}

/// Suppresses only native presentation while a command is applying. The
/// coordinator's graph remains frozen until its commit; screen suppression is
/// never used as a substitute for model atomicity.
@MainActor
final class TerminalWorkspacePresentationTransaction {
    private var animations: [(NSWindow, NSWindow.AnimationBehavior)] = []
    private var ended = false

    init(_ controllers: [TerminalController]) {
        TerminalWorkspacePresentation.begin()
        NSDisableScreenUpdates()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<ObjectIdentifier>()
        for controller in controllers {
            guard let window = controller.window, seen.insert(ObjectIdentifier(window)).inserted else { continue }
            animations.append((window, window.animationBehavior))
            window.animationBehavior = .none
        }
    }

    func publish(_ update: () -> Void) {
        guard !ended else { return }
        ended = true
        TerminalWorkspacePresentation.end()
        update()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        for (window, behavior) in animations { window.animationBehavior = behavior }
        NSEnableScreenUpdates()
    }
}
