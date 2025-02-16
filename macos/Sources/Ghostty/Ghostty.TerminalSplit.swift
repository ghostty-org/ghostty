import SwiftUI
import GhosttyKit

extension Ghostty {
    /// A spittable terminal view is one where the terminal allows for "splits" (vertical and horizontal) within the
    /// view. The terminal starts in the unsplit state (a plain ol' TerminalView) but responds to changes to the
    /// split direction by splitting the terminal.
    ///
    /// This also allows one split to be "zoomed" at any time.
    struct TerminalSplit: View {
        /// The current state of the root node. This can be set to nil when all surfaces are closed.
        @Binding var node: SplitNode?

        /// Non-nil if one of the surfaces in the split tree is currently "zoomed." A zoomed surface
        /// becomes "full screen" on the split tree.
        @State private var zoomedSurface: SurfaceView? = nil

        var body: some View {
            ZStack {
                TerminalSplitRoot(
                    node: $node,
                    zoomedSurface: $zoomedSurface
                )

                // If we have a zoomed surface, we overlay that on top of our split
                // root. Our split root will become clear when there is a zoomed
                // surface. We need to keep the split root around so that we don't
                // lose all of the surface state so this must be a ZStack.
                if let surfaceView = zoomedSurface {
                    InspectableSurface(surfaceView: surfaceView)
                }
            }
            .focusedValue(\.ghosttySurfaceZoomed, zoomedSurface != nil)
        }
    }

    /// The root of a split tree. This sets up the initial SplitNode state and renders. There is only ever
    /// one of these in a split tree.
    private struct TerminalSplitRoot: View {
        /// The root node that we're rendering. This will be set to nil if all the surfaces in this tree close.
        @Binding var node: SplitNode?

        /// Keeps track of whether we're in a zoomed split state or not. If one of the splits we own
        /// is in the zoomed state, we clear our body since we expect a zoomed split to overlay
        /// this one.
        @Binding var zoomedSurface: SurfaceView?

        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?

        var body: some View {
            let center = NotificationCenter.default
            let pubZoom = center.publisher(for: Notification.didToggleSplitZoom)
            let pubEqualize = center.publisher(for: Notification.didEqualizeSplits)

            // If we're zoomed, we don't render anything, we are transparent. This
            // ensures that the View stays around so we don't lose our state, but
            // also that the zoomed view on top can see through if background transparency
            // is enabled.
            if (zoomedSurface == nil) {
                ZStack {
                    switch (node) {
                    case nil:
                        Color(.clear)

                    case .leaf(let leaf):
                        TerminalSplitLeaf(
                            leaf: leaf,
                            neighbors: .empty,
                            node: $node
                        )

                    case .split(let container):
                        TerminalSplitContainer(
                            neighbors: .empty,
                            node: $node,
                            container: container
                        )
                        .onReceive(pubZoom) { onZoom(notification: $0) }
                        .onReceive(pubEqualize) { onEqualize(notification: $0) }
                    }
                }
                .navigationTitle(surfaceTitle ?? "Ghostty")
                .id(node) // Needed for change detection on node
            } else {
                // On these events we want to reset the split state and call it.
                let pubSplit = center.publisher(for: Notification.ghosttyNewSplit, object: zoomedSurface!)
                let pubClose = center.publisher(for: Notification.ghosttyCloseSurface, object: zoomedSurface!)
                let pubFocus = center.publisher(for: Notification.ghosttyFocusSplit, object: zoomedSurface!)

                ZStack {}
                    .onReceive(pubZoom) { onZoomReset(notification: $0) }
                    .onReceive(pubSplit) { onZoomReset(notification: $0) }
                    .onReceive(pubClose) { onZoomReset(notification: $0) }
                    .onReceive(pubFocus) { onZoomReset(notification: $0) }
            }
        }

        func onZoom(notification: SwiftUI.Notification) {
            // Our node must be split to receive zooms. You can't zoom an unsplit terminal.
            if case .leaf = node {
                preconditionFailure("TerminalSplitRoom must not be zoom-able if no splits exist")
            }

            // Make sure the notification has a surface and that this window owns the surface.
            guard let surfaceView = notification.object as? SurfaceView else { return }
            guard node?.contains(view: surfaceView) ?? false else { return }

            // We are in the zoomed state.
            zoomedSurface = surfaceView

            // See onZoomReset, same logic.
            DispatchQueue.main.async { Ghostty.moveFocus(to: surfaceView) }
        }

        func onZoomReset(notification: SwiftUI.Notification) {
            // Make sure the notification has a surface and that this window owns the surface.
            guard let surfaceView = notification.object as? SurfaceView else { return }
            guard zoomedSurface == surfaceView else { return }

            // We are now unzoomed
            zoomedSurface = nil

            // We need to stay focused on this view, but the view is going to change
            // superviews. We need to do this async so it happens on the next event loop
            // tick.
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: surfaceView)

                // If the notification is not a toggle zoom notification, we want to re-publish
                // it after a short delay so that the split tree has a chance to re-establish
                // so the proper view gets this notification.
                if (notification.name != Notification.didToggleSplitZoom) {
                    // We have to wait ANOTHER tick since we just established.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(notification)
                    }
                }
            }
        }

        func onEqualize(notification: SwiftUI.Notification) {
            guard case .split(let c) = node else { return }
            _ = c.equalize()
        }
    }

    /// A noSplit leaf node of a split tree.
    private struct TerminalSplitLeaf: View {
        /// The leaf to draw the surface for.
        let leaf: SplitNode.Leaf

        /// The neighbors, used for navigation.
        let neighbors: SplitNode.Neighbors

        /// The SplitNode that the leaf belongs to. This will be set to nil when leaf is closed.
        @Binding var node: SplitNode?

        var body: some View {
            let center = NotificationCenter.default
            let pub = center.publisher(for: Notification.ghosttyNewSplit, object: leaf.surface)
            let pubClose = center.publisher(for: Notification.ghosttyCloseSurface, object: leaf.surface)
            let pubFocus = center.publisher(for: Notification.ghosttyFocusSplit, object: leaf.surface)
            let pubResize = center.publisher(for: Notification.didResizeSplit, object: leaf.surface)

            InspectableSurface(surfaceView: leaf.surface, isSplit: !neighbors.isEmpty())
                .onReceive(pub) { onNewSplit(notification: $0) }
                .onReceive(pubClose) { onClose(notification: $0) }
                .onReceive(pubFocus) { onMoveFocus(notification: $0) }
                .onReceive(pubResize) { onResize(notification: $0) }
        }

        private func onClose(notification: SwiftUI.Notification) {
            var processAlive = false
            if let valueAny = notification.userInfo?["process_alive"] {
                if let value = valueAny as? Bool {
                    processAlive = value
                }
            }

            // If the child process is not alive, then we exit immediately
            guard processAlive else {
                node = nil
                return
            }

            // If we don't have a window to attach our modal to, we also exit immediately.
            // This should NOT happen.
            guard let window = leaf.surface.window else {
                node = nil
                return
            }

            // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
            // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
            // confirmationDialog allows the user to Cmd-W close the alert, but when doing
            // so SwiftUI does not update any of the bindings to note that window is no longer
            // being shown, and provides no callback to detect this.
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "The terminal still has a running process. If you close the " +
                "terminal the process will be killed."
            alert.addButton(withTitle: "Close the Terminal")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window, completionHandler: { response in
                switch (response) {
                case .alertFirstButtonReturn:
                    alert.window.orderOut(nil)
                    node = nil

                default:
                    break
                }
            })
        }

        private func onNewSplit(notification: SwiftUI.Notification) {
            let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            let config = configAny as? SurfaceConfiguration

            // Determine our desired direction
            guard let directionAny = notification.userInfo?["direction"] else { return }
            guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
            let splitDirection: SplitViewDirection
            let swap: Bool
            switch (direction) {
            case GHOSTTY_SPLIT_DIRECTION_RIGHT:
                splitDirection = .horizontal
                swap = false
            case GHOSTTY_SPLIT_DIRECTION_LEFT:
                splitDirection = .horizontal
                swap = true
            case GHOSTTY_SPLIT_DIRECTION_DOWN:
                splitDirection = .vertical
                swap = false
            case GHOSTTY_SPLIT_DIRECTION_UP:
                splitDirection = .vertical
                swap = true

            default:
                return
            }

            // Setup our new container since we are now split
            let container = SplitNode.Container(from: leaf, direction: splitDirection, baseConfig: config)

            // Change the parent node. This will trigger the parent to relayout our views.
            node = .split(container)

            // See moveFocus comment, we have to run this whenever split changes.
            Ghostty.moveFocus(to: container.bottomRight.preferredFocus(), from: node!.preferredFocus())

            // If we are swapping, swap now. We do this after our focus event
            // so that focus is in the right place.
            if swap {
                container.swap()
            }
        }

        /// This handles the event to move the split focus (i.e. previous/next) from a keyboard event.
        private func onMoveFocus(notification: SwiftUI.Notification) {
            // Determine our desired direction
            guard let directionAny = notification.userInfo?[Notification.SplitDirectionKey] else { return }
            guard let direction = directionAny as? SplitFocusDirection else { return }

            // Find the next surface to move to. In most cases this should be
            // finding the neighbor in provided direction, and focus it. When
            // the neighbor cannot be found based on next or previous direction,
            // this would instead search for first or last leaf and focus it
            // instead, giving the wrap around effect.
            // When other directions are provided, this can be nil, and early
            // returned.
            guard let nextSurface = neighbors.get(direction: direction)?.preferredFocus(direction)
                    ?? node?.firstOrLast(direction)?.surface else { return }

            Ghostty.moveFocus(
                to: nextSurface
            )
        }

        /// Handle a resize event.
        private func onResize(notification: SwiftUI.Notification) {
            // If this leaf is not part of a split then there is nothing to do
            guard let parent = leaf.parent else { return }

            guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] else { return }
            guard let direction = directionAny as? Ghostty.SplitResizeDirection else { return }

            guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] else { return }
            guard let amount = amountAny as? UInt16 else { return }

            parent.resize(direction: direction, amount: amount)
        }
    }

    /// This represents a split view that is in the horizontal or vertical split state.
    private struct TerminalSplitContainer: View {
        @EnvironmentObject var ghostty: Ghostty.App

        let neighbors: SplitNode.Neighbors
        @Binding var node: SplitNode?
        @StateObject var container: SplitNode.Container

        var body: some View {
            SplitView(
                container.direction,
                $container.split,
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                resizePublisher: container.resizeEvent,
                left: {
                let neighborKey: WritableKeyPath<SplitNode.Neighbors, SplitNode?> = container.direction == .horizontal ? \.right : \.down

                TerminalSplitNested(
                    node: closeableTopLeft(),
                    neighbors: neighbors.update([
                        neighborKey: container.bottomRight,
                        \.next: container.bottomRight,
                    ])
                )
            }, right: {
                let neighborKey: WritableKeyPath<SplitNode.Neighbors, SplitNode?> = container.direction == .horizontal ? \.left : \.up

                TerminalSplitNested(
                    node: closeableBottomRight(),
                    neighbors: neighbors.update([
                        neighborKey: container.topLeft,
                        \.previous: container.topLeft,
                    ])
                )
            })
        }

        private func closeableTopLeft() -> Binding<SplitNode?> {
            return .init(get: {
                container.topLeft
            }, set: { newValue in
                if let newValue {
                    container.topLeft = newValue
                    return
                }

                // Closing
                container.topLeft.close()
                node = container.bottomRight

                switch (node) {
                case .leaf(let l):
                    l.parent = container.parent
                case .split(let c):
                    c.parent = container.parent
                case .none:
                    break
                }

                DispatchQueue.main.async {
                    Ghostty.moveFocus(
                        to: container.bottomRight.preferredFocus(),
                        from: container.topLeft.preferredFocus()
                    )
                }
            })
        }

        private func closeableBottomRight() -> Binding<SplitNode?> {
            return .init(get: {
                container.bottomRight
            }, set: { newValue in
                if let newValue {
                    container.bottomRight = newValue
                    return
                }

                // Closing
                container.bottomRight.close()
                node = container.topLeft

                switch (node) {
                case .leaf(let l):
                    l.parent = container.parent
                case .split(let c):
                    c.parent = container.parent
                case .none:
                    break
                }

                DispatchQueue.main.async {
                    Ghostty.moveFocus(
                        to: container.topLeft.preferredFocus(),
                        from: container.bottomRight.preferredFocus()
                    )
                }
            })
        }
    }


    /// This is like TerminalSplitRoot, but... not the root. This renders a SplitNode in any state but
    /// requires there be a binding to the parent node.
    private struct TerminalSplitNested: View {
        @Binding var node: SplitNode?
        let neighbors: SplitNode.Neighbors

        var body: some View {
            Group {
                switch (node) {
                case nil:
                    Color(.clear)

                case .leaf(let leaf):
                    TerminalSplitLeaf(
                        leaf: leaf,
                        neighbors: neighbors,
                        node: $node
                    )

                case .split(let container):
                    TerminalSplitContainer(
                        neighbors: neighbors,
                        node: $node,
                        container: container
                    )
                }
            }
            .id(node)
        }
    }

    /// When changing the split state, or going full screen (native or non), the terminal view
    /// will lose focus. There has to be some nice SwiftUI-native way to fix this but I can't
    /// figure it out so we're going to do this hacky thing to bring focus back to the terminal
    /// that should have it.
    static func moveFocus(
        to: SurfaceView,
        from: SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        // The whole delay machinery is a bit of a hack to work around a
        // situation where the window is destroyed and the surface view
        // will never be attached to a window. Realistically, we should
        // handle this upstream but we also don't want this function to be
        // a source of infinite loops.

        // Our max delay before we give up
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        // We start at a 50 millisecond delay and do a doubling backoff
        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            // 100 milliseconds
            0.05
        }

        let work: DispatchWorkItem = .init {
            // If the callback runs before the surface is attached to a view
            // then the window will be nil. We just reschedule in that case.
            guard let window = to.window else {
                moveFocus(to: to, from: from, delay: nextDelay)
                return
            }

            // If we had a previously focused node and its not where we're sending
            // focus, make sure that we explicitly tell it to lose focus. In theory
            // we should NOT have to do this but the focus callback isn't getting
            // called for some reason.
            if let from = from {
                _ = from.resignFirstResponder()
            }

            window.makeFirstResponder(to)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }
}
