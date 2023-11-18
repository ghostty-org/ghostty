import SwiftUI
import Combine
import GhosttyKit

extension Ghostty {
    /// This enum represents the possible states that a node in the split tree can be in. It is either:
    ///
    ///   - noSplit - This is an unsplit, single pane. This contains only a "leaf" which has a single
    ///   terminal surface to render.
    ///   - horizontal/vertical - This is split into the horizontal or vertical direction. This contains a
    ///   "container" which has a recursive top/left SplitNode and bottom/right SplitNode. These
    ///   values can further be split infinitely.
    ///
    enum SplitNode: Equatable, Hashable {
        case leaf(Leaf)
        case split(Container)
        
        /// Returns the view that would prefer receiving focus in this tree. This is always the
        /// top-left-most view. This is used when creating a split or closing a split to find the
        /// next view to send focus to.
        func preferredFocus(_ direction: SplitFocusDirection = .top) -> SurfaceView {
            let container: Container
            switch (self) {
            case .leaf(let leaf):
                // noSplit is easy because there is only one thing to focus
                return leaf.surface

            case .split(let c):
                container = c
            }
            
            let node: SplitNode
            switch (direction) {
            case .previous, .bottom, .left:
                node = container.bottomRight
                
            case .next, .top, .right:
                node = container.topLeft
            }
            
            return node.preferredFocus(direction)
        }

        /// Close the surface associated with this node. This will likely deinitialize the
        /// surface. At this point, the surface view in this node tree can never be used again.
        func close() {
            switch (self) {
            case .leaf(let leaf):
                leaf.surface.close()

            case .split(let container):
                container.topLeft.close()
                container.bottomRight.close()
            }
        }
        
        /// Returns true if any surface in the split stack requires quit confirmation.
        func needsConfirmQuit() -> Bool {
            switch (self) {
            case .leaf(let leaf):
                return leaf.surface.needsConfirmQuit

            case .split(let container):
                return container.topLeft.needsConfirmQuit() ||
                    container.bottomRight.needsConfirmQuit()
            }
        }

        /// Returns true if the split tree contains the given view.
        func contains(view: SurfaceView) -> Bool {
            switch (self) {
            case .leaf(let leaf):
                return leaf.surface == view

            case .split(let container):
                return container.topLeft.contains(view: view) ||
                    container.bottomRight.contains(view: view)
            }
        }
        
        // MARK: - Equatable
        
        static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
            switch (lhs, rhs) {
            case (.leaf(let lhs_v), .leaf(let rhs_v)):
                return lhs_v === rhs_v
            case (.split(let lhs_v), .split(let rhs_v)):
                return lhs_v === rhs_v
            default:
                return false
            }
        }

        class Leaf: ObservableObject, Equatable, Hashable {
            /// Reference to the global app state
            let app: Ghostty.AppState

            /// The surface view associated with this leaf node
            @Published var surface: SurfaceView

            /// The parent container of this node. Nil if this is the root node
            weak var parent: SplitNode.Container?

            /// Initialize a new leaf which creates a new terminal surface.
            init(_ app: Ghostty.AppState, _ baseConfig: SurfaceConfiguration?) {
                self.app = app
                self.surface = SurfaceView(app, baseConfig)
            }
            
            // MARK: - Hashable
            
            func hash(into hasher: inout Hasher) {
                hasher.combine(surface)
            }
            
            // MARK: - Equatable
            
            static func == (lhs: Leaf, rhs: Leaf) -> Bool {
                return lhs.surface === rhs.surface
            }
        }

        class Container: ObservableObject, Equatable, Hashable {
            /// Reference to the global app state
            let app: Ghostty.AppState
            let direction: SplitViewDirection

            @Published var topLeft: SplitNode
            @Published var bottomRight: SplitNode
            @Published var split: CGFloat = 0.5

            var resizeEvent: PassthroughSubject<Double, Never> = .init()

            /// The parent container of this node. Nil if this is the root node
            weak var parent: SplitNode.Container?

            /// A container is always initialized from some prior leaf because a split has to originate
            /// from a non-split value. When initializing, we inherit the leaf's surface and then
            /// initialize a new surface for the new pane.
            init(from: Leaf, direction: SplitViewDirection, baseConfig: SurfaceConfiguration? = nil) {
                self.app = from.app
                self.direction = direction
                self.parent = from.parent

                // Initially, both topLeft and bottomRight are in the "nosplit"
                // state since this is a new split.
                self.topLeft = .leaf(from)

                let bottomRight: Leaf = .init(app, baseConfig)
                self.bottomRight = .leaf(bottomRight)

                from.parent = self
                bottomRight.parent = self
            }

            /// Resize the split by moving the split divider in the given
            /// direction by the given amount. If this container is not split
            /// in the given direction, navigate up the tree until we find a
            /// container that is
            func resize(direction: SplitResizeDirection, amount: UInt16) {
                 // We send a resize event to our publisher which will be
                 // received by the SplitView.
                switch (self.direction) {
                case .horizontal:
                    switch (direction) {
                    case .left: resizeEvent.send(-Double(amount))
                    case .right: resizeEvent.send(Double(amount))
                    default: parent?.resize(direction: direction, amount: amount)
                    }
                case .vertical:
                    switch (direction) {
                    case .up: resizeEvent.send(-Double(amount))
                    case .down: resizeEvent.send(Double(amount))
                    default: parent?.resize(direction: direction, amount: amount)
                    }
                }
            }

            /// Equalize the splits in this container. Each split is equalized
            /// based on its weight, i.e. the number of leaves it contains.
            /// This function returns the weight of this container.
            func equalize() -> UInt {
                let topLeftWeight: UInt
                switch (topLeft) {
                case .leaf:
                    topLeftWeight = 1
                case .split(let c):
                    topLeftWeight = c.equalize()
                }

                let bottomRightWeight: UInt
                switch (bottomRight) {
                case .leaf:
                    bottomRightWeight = 1
                case .split(let c):
                    bottomRightWeight = c.equalize()
                }

                let weight = topLeftWeight + bottomRightWeight
                split = Double(topLeftWeight) / Double(weight)
                return weight
            }

            // MARK: - Hashable
            
            func hash(into hasher: inout Hasher) {
                hasher.combine(direction)
                hasher.combine(topLeft)
                hasher.combine(bottomRight)
            }
            
            // MARK: - Equatable
            
            static func == (lhs: Container, rhs: Container) -> Bool {
                return lhs.direction == rhs.direction &&
                    lhs.topLeft == rhs.topLeft &&
                    lhs.bottomRight == rhs.bottomRight
            }
        }

        /// This keeps track of the "neighbors" of a split: the immediately above/below/left/right
        /// nodes. This is purposely weak so we don't have to worry about memory management
        /// with this (although, it should always be correct).
        struct Neighbors {
            var left: SplitNode?
            var right: SplitNode?
            var top: SplitNode?
            var bottom: SplitNode?

            /// These are the previous/next nodes. It will certainly be one of the above as well
            /// but we keep track of these separately because depending on the split direction
            /// of the containing node, previous may be left OR top (same for next).
            var previous: SplitNode?
            var next: SplitNode?

            /// No neighbors, used by the root node.
            static let empty: Self = .init()

            /// Get the node for a given direction.
            func get(direction: SplitFocusDirection) -> SplitNode? {
                let map: [SplitFocusDirection : KeyPath<Self, SplitNode?>] = [
                    .previous: \.previous,
                    .next: \.next,
                    .top: \.top,
                    .bottom: \.bottom,
                    .left: \.left,
                    .right: \.right,
                ]

                guard let path = map[direction] else { return nil }
                return self[keyPath: path]
            }

            /// Update multiple keys and return a new copy.
            func update(_ attrs: [WritableKeyPath<Self, SplitNode?>: SplitNode?]) -> Self {
                var clone = self
                attrs.forEach { (key, value) in
                    clone[keyPath: key] = value
                }
                return clone
            }
            
            /// True if there are no neighbors
            func isEmpty() -> Bool {
                return self.previous == nil && self.next == nil
            }
        }
    }
}
