import AppKit
import Combine
import SwiftUI

/// Manages the macOS menu bar status item that shows aggregate agent session status.
///
/// Creates an `NSStatusItem` with a ghost icon whose status dot reflects the
/// highest-priority indicator state across all running sessions. Clicking the
/// icon opens a popover listing active sessions grouped by project.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private var currentAggregateState: SessionIndicatorState?

    /// Create the status item and start observing session state changes.
    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIconRenderer.renderIcon(state: nil)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        self.statusItem = item

        // Subscribe to global indicator state changes from WorkspaceStore.
        cancellable = WorkspaceStore.shared.$globalIndicatorStates
            .receive(on: RunLoop.main)
            .sink { [weak self] states in
                self?.updateIcon(from: states)
            }
    }

    /// Tear down the status item and stop observing.
    func teardown() {
        cancellable?.cancel()
        cancellable = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover?.close()
        popover = nil
    }

    // MARK: - Private

    /// Recompute the aggregate state and update the icon if it changed.
    private func updateIcon(from states: [UUID: SessionIndicatorState]) {
        let newState = MenuBarIconRenderer.aggregateState(from: states)
        guard newState != currentAggregateState else { return }
        currentAggregateState = newState
        statusItem?.button?.image = MenuBarIconRenderer.renderIcon(state: newState)
    }

    /// Toggle the popover when the status item is clicked.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let contentView = MenuBarDropdownView()
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 280, height: 1)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 280, height: 300)
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = hostingController
        self.popover = pop

        if let button = statusItem?.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
