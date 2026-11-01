import AppKit

/// A value-only description of a terminal. Decoding this type never creates a
/// Surface, launches a shell, or attaches to a remote runtime. Its wire format
/// matches the existing terminal archive so the host remains the embedder.
struct TerminalWorkspaceSessionState: Codable, Equatable {
    struct Pane: Codable, Equatable {
        var pwd: String?
        var uuid: String
        var title: String?
        var isUserSetTitle: Bool?
        var agentResumeDescriptor: AgentResumeDescriptor?
        var sshResumeDescriptor: SSHResumeDescriptor?
        var runtimeDescriptor: SessionRuntimeDescriptor?

        enum CodingKeys: String, CodingKey {
            case pwd, uuid, title, isUserSetTitle, agentResumeDescriptor, sshResumeDescriptor, runtimeDescriptor
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // The upstream Surface decoder requires pwd even when it is null.
            try container.encode(pwd, forKey: .pwd)
            try container.encode(uuid, forKey: .uuid)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(isUserSetTitle, forKey: .isUserSetTitle)
            try container.encodeIfPresent(agentResumeDescriptor, forKey: .agentResumeDescriptor)
            try container.encodeIfPresent(sshResumeDescriptor, forKey: .sshResumeDescriptor)
            try container.encodeIfPresent(runtimeDescriptor, forKey: .runtimeDescriptor)
        }

        @MainActor init(_ view: Ghostty.SurfaceView) {
            pwd = view.pwd
            uuid = view.id.uuidString
            title = view.title
            isUserSetTitle = view.hasUserSetTitle
            agentResumeDescriptor = view.agentResumeDescriptor
            sshResumeDescriptor = view.sshResumeDescriptor
            runtimeDescriptor = view.runtimeDescriptor
        }
    }

    indirect enum Node: Codable, Equatable {
        case leaf(Pane)
        case split(Branch)

        struct Branch: Codable, Equatable {
            var direction: Direction
            var ratio: Double
            var left: Node
            var right: Node
        }
        enum Direction: Codable { case horizontal, vertical }
        enum CodingKeys: String, CodingKey { case view, split }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.view) {
                self = .leaf(try container.decode(Pane.self, forKey: .view))
            } else {
                self = .split(try container.decode(Branch.self, forKey: .split))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let pane): try container.encode(pane, forKey: .view)
            case .split(let branch): try container.encode(branch, forKey: .split)
            }
        }

        @MainActor init(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
            switch node {
            case .leaf(let view): self = .leaf(Pane(view))
            case .split(let branch):
                self = .split(Branch(direction: branch.direction == .horizontal ? .horizontal : .vertical,
                    ratio: branch.ratio, left: Node(branch.left), right: Node(branch.right)))
            }
        }

        func paneIDs(depth: Int = 0) -> [UUID]? {
            guard depth < 64 else { return nil }
            switch self {
            case .leaf(let pane): return UUID(uuidString: pane.uuid).map { [$0] }
            case .split(let branch):
                guard branch.ratio.isFinite, branch.ratio > 0, branch.ratio < 1,
                      let left = branch.left.paneIDs(depth: depth + 1),
                      let right = branch.right.paneIDs(depth: depth + 1) else { return nil }
                return left + right
            }
        }

        mutating func remapPaneIDs(using mapping: inout [String: String]) {
            switch self {
            case .leaf(var pane):
                let newID = mapping[pane.uuid] ?? UUID().uuidString
                mapping[pane.uuid] = newID
                pane.uuid = newID
                self = .leaf(pane)
            case .split(var branch):
                branch.left.remapPaneIDs(using: &mapping)
                branch.right.remapPaneIDs(using: &mapping)
                self = .split(branch)
            }
        }
    }

    struct Tree: Codable, Equatable {
        struct Path: Codable, Equatable {
            enum Component: Codable { case left, right }
            var path: [Component]
        }
        var version = 1
        var root: Node?
        var zoomed: Path?
    }

    var focusedSurface: String?
    var surfaceTree: Tree
    var effectiveFullscreenMode: FullscreenMode?
    var tabColor: TerminalTabColor?
    var titleOverride: String?
    var tabSessionID: String?
    var tabCreatedAt: Date?
    static let paneIDsPreRemappedKey = CodingUserInfoKey(
        rawValue: "omg.workspace.pane-ids-pre-remapped"
    )!

    @MainActor init(_ controller: TerminalController) {
        focusedSurface = controller.focusedSurface?.id.uuidString
        let tree = controller.surfaceTree
        let path = tree.zoomed.flatMap { tree.root?.path(to: $0) }
        surfaceTree = Tree(root: tree.root.map(Node.init), zoomed: path.map {
            Tree.Path(path: $0.path.map { $0 == .left ? .left : .right })
        })
        effectiveFullscreenMode = controller.fullscreenStyle?.fullscreenMode
        tabColor = (controller.window as? TerminalWindow)?.tabColor
        titleOverride = controller.titleOverride
        tabSessionID = controller.tabSessionID.uuidString
        tabCreatedAt = controller.tabCreatedAt
    }

    var paneIDs: [UUID]? {
        guard surfaceTree.version == 1, let ids = surfaceTree.root?.paneIDs(), !ids.isEmpty,
              ids.count <= 256, Set(ids).count == ids.count else { return nil }
        return ids
    }

    mutating func remapPaneIDsForRestoreTabs() {
        var mapping: [String: String] = [:]
        surfaceTree.root?.remapPaneIDs(using: &mapping)
        if let focusedSurface {
            self.focusedSurface = mapping[focusedSurface]
        }
    }

    @MainActor
    func instantiate(restoreSessions: Bool? = nil) throws -> TerminalRestorableState {
        let attachesSavedRuntime = restoreSessions
            ?? SessionRuntimeRestorationPolicy.attachesSavedRuntime(for: OhMyGhosttySettings.shared.startupMode)
        var restoredState = self
        if !attachesSavedRuntime {
            restoredState.remapPaneIDsForRestoreTabs()
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        decoder.userInfo[TerminalWorkspaceSessionStore.restoreSessionsKey] = attachesSavedRuntime
        decoder.userInfo[Self.paneIDsPreRemappedKey] = !attachesSavedRuntime
        return try decoder.decode(TerminalRestorableState.self, from: encoder.encode(restoredState))
    }
}
