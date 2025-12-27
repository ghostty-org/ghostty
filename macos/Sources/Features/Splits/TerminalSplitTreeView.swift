import SwiftUI
import os

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let onResize: (SplitTree<Ghostty.SurfaceView>.Node, Double) -> Void
    let onDrop: (Ghostty.SurfaceView, TerminalSplitLeaf.DropZone) -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                onResize: onResize,
                onDrop: onDrop)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
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
    let onDrop: (Ghostty.SurfaceView, TerminalSplitLeaf.DropZone) -> Void

    var body: some View {
        switch (node) {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, onDrop: onDrop)

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
                    TerminalSplitSubtreeView(node: split.left, onResize: onResize, onDrop: onDrop)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, onResize: onResize, onDrop: onDrop)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let onDrop: (Ghostty.SurfaceView, DropZone) -> Void
    
    @State private var dropState: DropState = .idle
    
    var body: some View {
        Ghostty.InspectableSurface(
            surfaceView: surfaceView,
            isSplit: isSplit)
        .background {
            // We use background for the drop delegate and overlay for the visual indicator
            // so that we don't block mouse events from reaching the surface view. The
            // background receives drop events while the overlay (with allowsHitTesting
            // disabled) only provides visual feedback.
            GeometryReader { geometry in
                Color.clear
                    .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                        dropState: $dropState,
                        viewSize: geometry.size,
                        onDrop: { zone in onDrop(surfaceView, zone) }
                    ))
            }
        }
        .overlay {
            if case .dropping(let zone) = dropState {
                GeometryReader { geometry in
                    dropZoneOverlay(for: zone, in: geometry)
                }
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal pane")
    }
    
    @ViewBuilder
    private func dropZoneOverlay(for zone: DropZone, in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)
        
        switch zone {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
    
    enum DropZone: String, Equatable {
        case top
        case bottom
        case left
        case right
    }
    
    enum DropState: Equatable {
        case idle
        case dropping(DropZone)
    }
    
    struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let onDrop: (DropZone) -> Void
        
        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }
        
        func dropEntered(info: DropInfo) {
            dropState = .dropping(calculateDropZone(at: info.location))
        }
        
        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(calculateDropZone(at: info.location))
            return DropProposal(operation: .move)
        }
        
        func dropExited(info: DropInfo) {
            dropState = .idle
        }
        
        func performDrop(info: DropInfo) -> Bool {
            let zone = calculateDropZone(at: info.location)
            dropState = .idle
            onDrop(zone)
            return true
        }
        
        /// Determines which drop zone the cursor is in based on proximity to edges.
        ///
        /// Divides the view into four triangular regions by drawing diagonals from
        /// corner to corner. The drop zone is determined by which edge the cursor
        /// is closest to, creating natural triangular hit regions for each side.
        private func calculateDropZone(at point: CGPoint) -> DropZone {
            let relX = point.x / viewSize.width
            let relY = point.y / viewSize.height

            let distToLeft = relX
            let distToRight = 1 - relX
            let distToTop = relY
            let distToBottom = 1 - relY

            let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

            if minDist == distToLeft { return .left }
            if minDist == distToRight { return .right }
            if minDist == distToTop { return .top }
            return .bottom
        }
    }
}
