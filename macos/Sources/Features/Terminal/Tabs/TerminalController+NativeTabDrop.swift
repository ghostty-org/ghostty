import AppKit

extension TerminalController {
    func sharesNativeTabGroup(with other: TerminalController) -> Bool {
        guard let window, let otherWindow = other.window else { return false }
        if window === otherWindow { return true }
        return window.tabGroup.map { $0 === otherWindow.tabGroup } ?? false
    }
    /// Move the native window, including its complete split tree, between hosts.
    /// Surface transfer remains the existing Ghostty pane-move transaction.
    func attachNativeTab(_ source: TerminalController, relativeTo target: TerminalController,
                         placement: VerticalTabDropPolicy.Placement) -> Bool {
        guard source !== target, source.workspaceID == target.workspaceID,
              source.isAvailableForWorkspace, target.isAvailableForWorkspace,
              let incoming = source.window, let destination = target.window,
              !source.sharesNativeTabGroup(with: target) else { return false }
        let oldGroup = incoming.tabGroup
        let oldIndex = oldGroup?.windows.firstIndex(of: incoming) ?? 0
        let selected = destination.tabGroup?.selectedWindow ?? destination
        guard destination.addTabbedWindowSafely(incoming, ordered: .above),
              let group = destination.tabGroup, incoming.tabGroup === group,
              let index = group.windows.firstIndex(of: destination),
              let sourceIndex = group.windows.firstIndex(of: incoming) else { return false }
        let insertion = index + (placement == .before ? 0 : 1)
        let expected = VerticalTabDropPolicy.destinationIndex(sourceIndex: sourceIndex, insertionIndex: insertion,
                                                              tabCount: group.windows.count)
        _ = target.reorderTab(source, toInsertionIndex: insertion)
        guard group.windows.firstIndex(of: incoming) == expected else {
            incoming.tabGroup?.removeWindow(incoming)
            if let oldGroup {
                oldGroup.insertWindow(incoming, at: min(oldIndex, oldGroup.windows.count))
                Self.refreshTabs(in: oldGroup)
            } else {
                incoming.makeKeyAndOrderFront(nil)
            }
            Self.refreshTabs(in: group)
            return false
        }
        if group.windows.contains(selected) { group.selectedWindow = selected }
        Self.refreshTabs(in: group)
        if let oldGroup, !oldGroup.windows.isEmpty { Self.refreshTabs(in: oldGroup) }
        incoming.invalidateRestorableState()
        return true
    }
}
