import SwiftUI

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let onResize: (SplitTree<Ghostty.SurfaceView>.Node, Double) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                onResize: onResize)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad beaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
        }
    }
}

struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let onResize: (SplitTree<Ghostty.SurfaceView>.Node, Double) -> Void

    var body: some View {
        switch (node) {
        case .leaf(let leafView):
            Ghostty.InspectableSurface(
                surfaceView: leafView,
                isSplit: !isRoot)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal pane")

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch (split.direction) {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    onResize(node, $0)
                }),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, onResize: onResize)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, onResize: onResize)
                }
            )
        }
    }
}
