import AppKit

/// Divider segments are confined to their parent split, including unequal ratios.
enum TabSplitPreviewLayout {
    struct Divider: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    static func dividers<V>(tree: SplitTree<V>, size: CGSize) -> [Divider] {
        guard let spatial = tree.root?.spatial(within: size) else { return [] }
        return spatial.slots.compactMap { slot in
            guard case .split(let split) = slot.node else { return nil }
            let bounds = slot.bounds
            switch split.direction {
            case .horizontal:
                let x = bounds.minX + bounds.width * split.ratio
                return .init(start: CGPoint(x: x, y: bounds.minY), end: CGPoint(x: x, y: bounds.maxY))
            case .vertical:
                let y = bounds.minY + bounds.height * split.ratio
                return .init(start: CGPoint(x: bounds.minX, y: y), end: CGPoint(x: bounds.maxX, y: y))
            }
        }
    }
}
