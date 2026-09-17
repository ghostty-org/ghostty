import Foundation

struct GitGraphLayout: Equatable, Sendable {
    private(set) var activeLanes: [GitCommitID]
    private var activeLaneColorIndices: [Int]
    private var nextColorIndex: Int
    private let primaryRanks: [GitCommitID: Int]

    init(activeLanes: [GitCommitID] = [], primaryFirstParents: [GitCommitID] = []) {
        // Only real continuations enter from above; the first-parent spine
        // supplies ordering ranks, not an invented incoming edge at the tip.
        let initial = activeLanes
        self.activeLanes = initial
        self.activeLaneColorIndices = initial.indices.map { $0 % GitGraphRow.paletteSize }
        self.nextColorIndex = initial.count % GitGraphRow.paletteSize
        var ranks: [GitCommitID: Int] = [:]
        for (index, id) in primaryFirstParents.enumerated() where ranks[id] == nil { ranks[id] = index }
        primaryRanks = ranks
    }

    /// Anchor the displayed timeline's first-parent spine, rather than letting
    /// unrelated pending tips become the new leftmost lane after a merge.
    static func rows(for commits: [GitHistoryCommit]) -> [GitGraphRow] {
        var firstParents: [GitCommitID: GitCommitID] = [:]
        for commit in commits { firstParents[commit.id] = commit.parentIDs.first }
        var primary: [GitCommitID] = []
        var seen = Set<GitCommitID>()
        var current = commits.first?.id
        while let id = current, seen.insert(id).inserted {
            primary.append(id)
            current = firstParents[id]
        }
        let remoteOnly = Set(commits.filter(\.isRemoteOnly).map(\.id))
        var layout = GitGraphLayout(primaryFirstParents: primary)
        return commits.map { layout.append(commitID: $0.id, parentIDs: $0.parentIDs, isRemoteOnly: remoteOnly) }
    }

    var activeCommitIDs: [GitCommitID] {
        activeLanes
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID]
    ) -> GitGraphRow {
        append(commitID: commitID, parentIDs: parentIDs, isRemoteOnly: [])
    }

    mutating func append(
        commitID: GitCommitID,
        parentIDs: [GitCommitID],
        isRemoteOnly: Set<GitCommitID>
    ) -> GitGraphRow {
        let topLanes = activeLanes
        let topLaneColorIndices = activeLaneColorIndices
        let uniqueParentIDs = Self.uniqueCommitIDs(parentIDs)
        let currentLane = topLanes.firstIndex(of: commitID) ?? topLanes.count
        let wasActive = currentLane < topLanes.count
        let currentColorIndex = if wasActive {
            topLaneColorIndices[currentLane]
        } else {
            allocateColorIndex()
        }

        var bottomLanes = topLanes
        var bottomLaneColorIndices = topLaneColorIndices
        if wasActive {
            bottomLanes.remove(at: currentLane)
            bottomLaneColorIndices.remove(at: currentLane)
        }

        var parentLanes: [GitCommitID: Int] = [:]
        var parentColorIndices: [GitCommitID: Int] = [:]
        var insertionIndex = min(currentLane, bottomLanes.count)

        for (parentIndex, parentID) in uniqueParentIDs.enumerated() {
            if let lane = bottomLanes.firstIndex(of: parentID) {
                parentLanes[parentID] = lane
                parentColorIndices[parentID] = bottomLaneColorIndices[lane]
                insertionIndex = max(insertionIndex, lane + 1)
                continue
            }

            let lane = min(insertionIndex, bottomLanes.count)
            // A lane's identity color stays with it; only the spine (already
            // pinned to the trunk color at insertion) may reuse palette slot 0.
            let colorIndex = if primaryRanks[parentID] != nil {
                Self.spineColorIndex
            } else if parentIndex == 0 {
                currentColorIndex
            } else {
                allocateColorIndex()
            }
            bottomLanes.insert(parentID, at: lane)
            bottomLaneColorIndices.insert(colorIndex, at: lane)
            parentLanes[parentID] = lane
            parentColorIndices[parentID] = colorIndex
            insertionIndex = lane + 1
        }

        // A side branch may have queued a future mainline ancestor to the
        // right of other pending lanes. Promote the nearest unprocessed spine
        // commit before emitting edges, keeping boundary coordinates consistent.
        // The promoted lane keeps the trunk color so lane 0 never changes hue.
        if let lane = bottomLanes.indices.filter({ primaryRanks[bottomLanes[$0]] != nil }).min(by: {
            primaryRanks[bottomLanes[$0], default: .max] < primaryRanks[bottomLanes[$1], default: .max]
        }), lane != 0 {
            let id = bottomLanes.remove(at: lane)
            bottomLaneColorIndices.remove(at: lane)
            bottomLanes.insert(id, at: 0)
            bottomLaneColorIndices.insert(Self.spineColorIndex, at: 0)
        }
        for parentID in uniqueParentIDs { parentLanes[parentID] = bottomLanes.firstIndex(of: parentID) }

        var segments: [GitGraphSegment] = []
        if wasActive {
            segments.append(
                GitGraphSegment(
                    kind: .incoming,
                    from: .top(lane: currentLane),
                    to: .node(lane: currentLane),
                    colorIndex: currentColorIndex,
                    commitID: commitID,
                    parentID: nil,
                    isRemoteOnly: isRemoteOnly.contains(commitID)
                )
            )
        }

        for (lane, laneCommitID) in topLanes.enumerated() where laneCommitID != commitID {
            guard let bottomLane = bottomLanes.firstIndex(of: laneCommitID) else { continue }
            segments.append(
                GitGraphSegment(
                    kind: .passthrough,
                    from: .top(lane: lane),
                    to: .bottom(lane: bottomLane),
                    colorIndex: topLaneColorIndices[lane],
                    commitID: laneCommitID,
                    parentID: nil,
                    isRemoteOnly: isRemoteOnly.contains(laneCommitID)
                )
            )
        }

        for parentID in uniqueParentIDs {
            guard let parentLane = parentLanes[parentID],
                  let parentColorIndex = parentColorIndices[parentID] else { continue }
            // The edge belongs to the child commit; an unpulled child keeps the
            // dashed style until it joins a local (or shared) ancestor.
            let edgeIsRemoteOnly = isRemoteOnly.contains(commitID)
                && (!isRemoteOnly.contains(parentID) || parentLanes.count > 1)
            segments.append(
                GitGraphSegment(
                    kind: .parent,
                    from: .node(lane: currentLane),
                    to: .bottom(lane: parentLane),
                    colorIndex: parentColorIndex,
                    commitID: commitID,
                    parentID: parentID,
                    isRemoteOnly: edgeIsRemoteOnly
                )
            )
        }

        activeLanes = bottomLanes
        activeLaneColorIndices = bottomLaneColorIndices

        return GitGraphRow(
            commitID: commitID,
            parentIDs: uniqueParentIDs,
            topLanes: topLanes,
            bottomLanes: bottomLanes,
            nodeLane: currentLane,
            nodeColorIndex: currentColorIndex,
            segments: segments,
            isRemoteOnly: isRemoteOnly.contains(commitID)
        )
    }

    /// Lane 0's first-parent spine always uses this palette slot.
    static let spineColorIndex = 0

    private mutating func allocateColorIndex() -> Int {
        defer {
            nextColorIndex = (nextColorIndex + 1) % GitGraphRow.paletteSize
        }
        return nextColorIndex
    }

    private static func uniqueCommitIDs(_ commitIDs: [GitCommitID]) -> [GitCommitID] {
        var seen = Set<GitCommitID>()
        var result: [GitCommitID] = []
        for commitID in commitIDs where !seen.contains(commitID) {
            seen.insert(commitID)
            result.append(commitID)
        }
        return result
    }

}

struct GitGraphRow: Equatable, Sendable {
    static let paletteSize = 8

    let commitID: GitCommitID
    let parentIDs: [GitCommitID]
    let topLanes: [GitCommitID]
    let bottomLanes: [GitCommitID]
    let nodeLane: Int
    let nodeColorIndex: Int
    let segments: [GitGraphSegment]
    var isRemoteOnly = false

    var requiredLaneCount: Int {
        max(topLanes.count, bottomLanes.count, nodeLane + 1, 1)
    }
}

struct GitGraphSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case incoming
        case parent
        case passthrough
    }

    let kind: Kind
    let from: GitGraphPoint
    let to: GitGraphPoint
    let colorIndex: Int
    let commitID: GitCommitID
    let parentID: GitCommitID?
    /// Dashed rendering for commits fetched to a remote ref but not yet
    /// reachable from any local branch (see GitHistorySnapshot.remoteOnlyCommitIDs).
    var isRemoteOnly = false
}

enum GitGraphPoint: Equatable, Sendable {
    case top(lane: Int)
    case node(lane: Int)
    case bottom(lane: Int)

    var lane: Int {
        switch self {
        case .top(let lane), .node(let lane), .bottom(let lane):
            lane
        }
    }
}
