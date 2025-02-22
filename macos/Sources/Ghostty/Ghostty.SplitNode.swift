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
    enum SplitNode: Equatable, Hashable, Codable, Sequence {
        case leaf(Leaf)
        case split(Container)

        /// The parent of this node.
        var parent: Container? {
            get {
                switch (self) {
                case .leaf(let leaf):
                    return leaf.parent

                case .split(let container):
                    return container.parent
                }
            }

            set {
                switch (self) {
                case .leaf(let leaf):
                    leaf.parent = newValue

                case .split(let container):
                    container.parent = newValue
                }
            }
        }

        /// Returns true if the tree is split.
        var isSplit: Bool {
            return if case .leaf = self {
                false
            } else {
                true
            }
        }

        func topLeft() -> SurfaceView {
            switch (self) {
            case .leaf(let leaf):
                return leaf.surface

            case .split(let container):
                return container.topLeft.topLeft()
            }
        }

        /// Returns the view that would prefer receiving focus in this tree. This is always the
        /// top-left-most view. This is used when creating a split or closing a split to find the
        /// next view to send focus to.
        func preferredFocus(_ direction: SplitFocusDirection = .up) -> SurfaceView {
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
            case .previous, .up, .left:
                node = container.bottomRight

            case .next, .down, .right:
                node = container.topLeft
            }

            return node.preferredFocus(direction)
        }

        /// When direction is either next or previous, return the first or last
        /// leaf. This can be used when the focus needs to move to a leaf even
        /// after hitting the bottom-right-most or top-left-most surface.
        /// When the direction is not next or previous (such as top, bottom,
        /// left, right), it will be ignored and no leaf will be returned.
        func firstOrLast(_ direction: SplitFocusDirection) -> Leaf? {
            // If there is no parent, simply ignore.
            guard let root = self.parent?.rootContainer() else { return nil }

            switch (direction) {
            case .next:
                return root.firstLeaf()
            case .previous:
                return root.lastLeaf()
            default:
                return nil
            }
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
            return leaf(for: view) != nil
        }

        /// Find a surface view by UUID.
        func findUUID(uuid: UUID) -> SurfaceView? {
            switch (self) {
            case .leaf(let leaf):
                if (leaf.surface.uuid == uuid) {
                    return leaf.surface
                }

                return nil

            case .split(let container):
                return container.topLeft.findUUID(uuid: uuid) ??
                    container.bottomRight.findUUID(uuid: uuid)
            }
        }

        /// Returns true if the surface borders the top. Assumes the view is in the tree.
        func doesBorderTop(view: SurfaceView) -> Bool {
            switch (self) {
            case .leaf(let leaf):
                return leaf.surface == view

            case .split(let container):
                switch (container.direction) {
                case .vertical:
                    return container.topLeft.doesBorderTop(view: view)

                case .horizontal:
                    return container.topLeft.doesBorderTop(view: view) ||
                        container.bottomRight.doesBorderTop(view: view)
                }
            }
        }

        /// Return the node for the given view if its in the tree.
        func leaf(for view: SurfaceView) -> Leaf? {
            switch (self) {
            case .leaf(let leaf):
                if leaf.surface == view {
                    return leaf
                } else {
                    return nil
                }

            case .split(let container):
                return container.topLeft.leaf(for: view) ??
                    container.bottomRight.leaf(for: view)
            }
        }

        // MARK: - Sequence

        func makeIterator() -> IndexingIterator<[Leaf]> {
            return leaves().makeIterator()
        }

        /// Return all the leaves in this split node. This isn't very efficient but our split trees are never super
        /// deep so its not an issue.
        private func leaves() -> [Leaf] {
            switch (self) {
            case .leaf(let leaf):
                return [leaf]

            case .split(let container):
                return container.topLeft.leaves() + container.bottomRight.leaves()
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

        class Leaf: ObservableObject, Equatable, Hashable, Codable {
            let app: ghostty_app_t
            @Published var surface: SurfaceView

            weak var parent: SplitNode.Container?

            /// Initialize a new leaf which creates a new terminal surface.
            init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
                self.app = app
                self.surface = SurfaceView(app, baseConfig: baseConfig, uuid: uuid)
            }

            // MARK: - Hashable

            func hash(into hasher: inout Hasher) {
                hasher.combine(app)
                hasher.combine(surface)
            }

            // MARK: - Equatable

            static func == (lhs: Leaf, rhs: Leaf) -> Bool {
                return lhs.app == rhs.app && lhs.surface === rhs.surface
            }

            // MARK: - Codable

            enum CodingKeys: String, CodingKey {
                case pwd
                case uuid
            }

            required convenience init(from decoder: Decoder) throws {
                // Decoding uses the global Ghostty app
                guard let del = NSApplication.shared.delegate,
                      let appDel = del as? AppDelegate,
                      let app = appDel.ghostty.app else {
                    throw TerminalRestoreError.delegateInvalid
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                let uuid = UUID(uuidString: try container.decode(String.self, forKey: .uuid))
                var config = SurfaceConfiguration()
                config.workingDirectory = try container.decode(String?.self, forKey: .pwd)

                self.init(app, baseConfig: config, uuid: uuid)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(surface.pwd, forKey: .pwd)
                try container.encode(surface.uuid.uuidString, forKey: .uuid)
            }
        }

        class Container: ObservableObject, Equatable, Hashable, Codable {
            let app: ghostty_app_t
            let direction: SplitViewDirection

            @Published var topLeft: SplitNode
            @Published var bottomRight: SplitNode
            @Published var split: CGFloat = 0.5

            var resizeEvent: PassthroughSubject<Double, Never> = .init()

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

                let bottomRight: Leaf = .init(app, baseConfig: baseConfig)
                self.bottomRight = .leaf(bottomRight)

                from.parent = self
                bottomRight.parent = self
            }

            // Move the top left node to the bottom right and vice versa,
            // preserving the size.
            func swap() {
                let topLeft: SplitNode = self.topLeft
                self.topLeft = bottomRight
                self.bottomRight = topLeft
                self.split = 1 - self.split
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

            /// Returns the top most parent, or this container. Because this
            /// would fall back to use to self, the return value is guaranteed.
            func rootContainer() -> Container {
                guard let parent = self.parent else { return self }
                return parent.rootContainer()
            }

            /// Returns the first leaf from the given container. This is most
            /// useful for root container, so that we can find the top-left-most
            /// leaf.
            func firstLeaf() -> Leaf {
                switch (self.topLeft) {
                case .leaf(let leaf):
                    return leaf
                case .split(let s):
                    return s.firstLeaf()
                }
            }

            /// Returns the last leaf from the given container. This is most
            /// useful for root container, so that we can find the bottom-right-
            /// most leaf.
            func lastLeaf() -> Leaf {
                switch (self.bottomRight) {
                case .leaf(let leaf):
                    return leaf
                case .split(let s):
                    return s.lastLeaf()
                }
            }

            // MARK: - Hashable

            func hash(into hasher: inout Hasher) {
                hasher.combine(app)
                hasher.combine(direction)
                hasher.combine(topLeft)
                hasher.combine(bottomRight)
            }

            // MARK: - Equatable

            static func == (lhs: Container, rhs: Container) -> Bool {
                return lhs.app == rhs.app &&
                    lhs.direction == rhs.direction &&
                    lhs.topLeft == rhs.topLeft &&
                    lhs.bottomRight == rhs.bottomRight
            }

            // MARK: - Codable

            enum CodingKeys: String, CodingKey {
                case direction
                case split
                case topLeft
                case bottomRight
            }

            required init(from decoder: Decoder) throws {
                // Decoding uses the global Ghostty app
                guard let del = NSApplication.shared.delegate,
                      let appDel = del as? AppDelegate,
                      let app = appDel.ghostty.app else {
                    throw TerminalRestoreError.delegateInvalid
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.app = app
                self.direction = try container.decode(SplitViewDirection.self, forKey: .direction)
                self.split = try container.decode(CGFloat.self, forKey: .split)
                self.topLeft = try container.decode(SplitNode.self, forKey: .topLeft)
                self.bottomRight = try container.decode(SplitNode.self, forKey: .bottomRight)

                // Fix up the parent references
                self.topLeft.parent = self
                self.bottomRight.parent = self
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(direction, forKey: .direction)
                try container.encode(split, forKey: .split)
                try container.encode(topLeft, forKey: .topLeft)
                try container.encode(bottomRight, forKey: .bottomRight)
            }
        }

        /// This keeps track of the "neighbors" of a split: the immediately above/below/left/right
        /// nodes. This is purposely weak so we don't have to worry about memory management
        /// with this (although, it should always be correct).
        struct Neighbors {
            var left: SplitNode?
            var right: SplitNode?
            var up: SplitNode?
            var down: SplitNode?

            /// These are the previous/next nodes. It will certainly be one of the above as well
            /// but we keep track of these separately because depending on the split direction
            /// of the containing node, previous may be left OR up (same for next).
            var previous: SplitNode?
            var next: SplitNode?

            /// No neighbors, used by the root node.
            static let empty: Self = .init()

            /// Get the node for a given direction.
            func get(direction: SplitFocusDirection) -> SplitNode? {
                let map: [SplitFocusDirection : KeyPath<Self, SplitNode?>] = [
                    .previous: \.previous,
                    .next: \.next,
                    .up: \.up,
                    .down: \.down,
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
