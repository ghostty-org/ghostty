import AppKit

/// Icon geometry preserves split direction, not terminal divider ratios.
/// Stop at half-width/half-height; deeper subtrees retain every pane in one slot.
enum SplitTabIconLayout {
    struct Slot<ViewType: NSView & Codable & Identifiable>: Identifiable, Equatable {
        var id: ViewType.ID { views[0].id }
        let rect: CGRect
        let views: [ViewType]
        let isFolded: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rect == rhs.rect && lhs.isFolded == rhs.isFolded &&
                lhs.views.map(\.id) == rhs.views.map(\.id)
        }
    }

    static func layout<V>(tree: SplitTree<V>) -> [Slot<V>] {
        guard let root = tree.root else { return [] }
        return layout(node: root)
    }

    private static func layout<V>(
        node: SplitTree<V>.Node,
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [Slot<V>] {
        switch node {
        case .leaf(let view):
            return [.init(rect: rect, views: [view], isFolded: false)]
        case .split(let split):
            let horizontal = split.direction == .horizontal
            guard (horizontal ? rect.width : rect.height) > 0.5 else {
                return [.init(rect: rect, views: node.leaves(), isFolded: true)]
            }
            var first = rect
            if horizontal { first.size.width /= 2 } else { first.size.height /= 2 }
            let second = first.offsetBy(dx: horizontal ? first.width : 0,
                                        dy: horizontal ? 0 : first.height)
            return layout(node: split.left, rect: first) + layout(node: split.right, rect: second)
        }
    }
}

/// Value-only presentation: no tab-wide/focused activity may leak into another pane.
struct SplitTabPane: Identifiable {
    static func isPaneFocused(selected: Bool, surfaceID: UUID, focusedID: UUID?) -> Bool {
        selected && surfaceID == focusedID
    }
    let id: UUID
    let icon: GhosttyTabIcon
    let activity: TabActivity?
    let title: String
    let focused: Bool

}

