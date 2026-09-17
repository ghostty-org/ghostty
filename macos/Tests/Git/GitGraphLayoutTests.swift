import Testing
@testable import Ghostty

struct GitGraphLayoutTests {
    @Test func pendingSideBranchesCannotDisplaceTheFirstParentSpine() {
        let history = [
            commit("tip", ["main", "side", "probe"]), commit("probe", ["base"]),
            commit("main", ["base"]), commit("base", ["root"]),
            commit("side", ["root"]), commit("root", []),
        ]
        let rows = GitGraphLayout.rows(for: history)
        for index in [0, 2, 3, 5] { #expect(rows[index].nodeLane == 0) }
        #expect(rows[1].nodeLane > 0 && rows[4].nodeLane > 0)
        for index in 0..<(rows.count - 1) { #expect(rows[index].bottomLanes == rows[index + 1].topLanes) }
        for row in rows {
            #expect(Set(row.bottomLanes).count == row.bottomLanes.count)
            for edge in row.segments where edge.kind == .parent {
                #expect(row.bottomLanes[edge.to.lane] == edge.parentID)
            }
        }
    }

    @Test func manyHeldBranchesAndPaginationKeepOrdinaryCommitsOnLaneZero() {
        let sides = (0..<24).map { "side-\($0)" }
        let main = (0..<80).map { "main-\($0)" }
        var history = [commit("tip", ["entry"] + sides + ["probe"]), commit("probe", [main[0]]), commit("entry", [main[0]])]
        history += main.enumerated().map { index, name in commit(name, index + 1 < main.count ? [main[index + 1]] : ["root"]) }
        history += sides.map { commit($0, ["root"]) }
        history.append(commit("root", []))
        let rows = GitGraphLayout.rows(for: history)
        let mainIDs = Set((["tip", "entry", "root"] + main).map(id))
        #expect(rows.filter { mainIDs.contains($0.commitID) }.allSatisfy { $0.nodeLane == 0 })
        let page = GitGraphLayout.rows(for: Array(history.prefix(30)))
        #expect(page.map(\.nodeLane) == rows.prefix(30).map(\.nodeLane))
        #expect(page.map(\.topLanes) == rows.prefix(30).map(\.topLanes))
    }

    @Test func spineCommitQueuedBySideBranchKeepsTrunkColorOnLaneZero() {
        // topo order: a side child of spine commit `base` is listed before the
        // spine's own continuation, so `base` enters the lanes via the side
        // branch. The trunk on lane 0 must keep a single color regardless.
        let history = [
            commit("tip", ["s1", "side"]),
            commit("side", ["base"]),
            commit("s1", ["base"]),
            commit("base", ["root"]),
            commit("root", []),
        ]
        let rows = GitGraphLayout.rows(for: history)
        let trunk = GitGraphLayout.spineColorIndex
        for (index, nodeID) in ["tip", "side", "s1", "base", "root"].enumerated() {
            #expect(rows[index].commitID == id(nodeID))
        }
        for row in rows where ["tip", "s1", "base", "root"].map(id).contains(row.commitID) {
            #expect(row.nodeLane == 0)
            #expect(row.nodeColorIndex == trunk)
            if row.commitID != id("tip") {
                #expect(row.incomingSegment()?.colorIndex == trunk)
            }
            for segment in row.segments where segment.kind == .parent && segment.parentID != nil
                && ["s1", "base", "root"].map(id).contains(segment.parentID!) {
                #expect(segment.colorIndex == trunk)
            }
        }
        let sideRow = rows[1]
        #expect(sideRow.nodeLane > 0)
        #expect(sideRow.nodeColorIndex != trunk)
        #expect(sideRow.parentEdge(to: id("base"))?.colorIndex == trunk)
    }

    @Test func remoteOnlyCommitsMarkRowsAndEdgesUntilLocalAncestor() {
        let remoteTip = commit("remote-tip", ["remote-mid"])
        let remoteMid = commit("remote-mid", ["local"])
        let local = commit("local", ["base"])
        let base = commit("base", [])
        var input = [remoteTip, remoteMid, local, base]
        input[0].isRemoteOnly = true
        input[1].isRemoteOnly = true
        let rows = GitGraphLayout.rows(for: input)
        #expect(rows[0].isRemoteOnly && rows[1].isRemoteOnly)
        #expect(!rows[2].isRemoteOnly && !rows[3].isRemoteOnly)
        #expect(rows[0].parentEdge(to: id("remote-mid"))?.isRemoteOnly == false)
        #expect(rows[1].incomingSegment()?.isRemoteOnly == true)
        #expect(rows[1].parentEdge(to: id("local"))?.isRemoteOnly == true)
        #expect(rows[2].segments.allSatisfy { !$0.isRemoteOnly })
        #expect(rows[3].segments.allSatisfy { !$0.isRemoteOnly })
    }

    private func commit(_ value: String, _ parents: [String]) -> GitHistoryCommit {
        GitHistoryCommit(id: id(value), parentIDs: parents.map(id), authorName: "Author", authorEmail: "a@example.com",
            authoredAt: .distantPast, subject: "feat: " + value)
    }

    @Test func linearHistoryKeepsParentConnectivityUntilRoot() {
        var layout = GitGraphLayout()

        let rowA = layout.append(commitID: id("a"), parentIDs: [id("b")])
        #expect(rowA.nodeLane == 0)
        #expect(rowA.bottomLanes == [id("b")])
        #expect(rowA.containsParentEdge(from: id("a"), to: id("b")))

        let rowB = layout.append(commitID: id("b"), parentIDs: [id("c")])
        #expect(rowB.topLanes == [id("b")])
        #expect(rowB.bottomLanes == [id("c")])
        #expect(rowB.containsIncoming(commitID: id("b"), lane: 0))
        #expect(rowB.containsParentEdge(from: id("b"), to: id("c")))

        let rowC = layout.append(commitID: id("c"), parentIDs: [])
        #expect(rowC.topLanes == [id("c")])
        #expect(rowC.bottomLanes == [])
        #expect(rowC.containsIncoming(commitID: id("c"), lane: 0))
        #expect(layout.activeCommitIDs == [])
    }

    @Test func linearFirstParentHistoryKeepsOneColor() {
        var layout = GitGraphLayout()

        let rowA = layout.append(commitID: id("a"), parentIDs: [id("b")])
        let rowB = layout.append(commitID: id("b"), parentIDs: [id("c")])
        let rowC = layout.append(commitID: id("c"), parentIDs: [])

        #expect(rowA.nodeColorIndex == rowA.parentEdge(to: id("b"))?.colorIndex)
        #expect(rowB.nodeColorIndex == rowA.nodeColorIndex)
        #expect(rowB.nodeColorIndex == rowB.incomingSegment()?.colorIndex)
        #expect(rowB.nodeColorIndex == rowB.parentEdge(to: id("c"))?.colorIndex)
        #expect(rowC.nodeColorIndex == rowA.nodeColorIndex)
        #expect(rowC.nodeColorIndex == rowC.incomingSegment()?.colorIndex)
    }

    @Test func mergeReusesExistingParentLaneWithoutDuplicateActiveParents() {
        var layout = GitGraphLayout()

        let merge = layout.append(commitID: id("merge"), parentIDs: [id("left"), id("right")])
        #expect(merge.bottomLanes == [id("left"), id("right")])
        #expect(merge.containsParentEdge(from: id("merge"), to: id("left")))
        #expect(merge.containsParentEdge(from: id("merge"), to: id("right")))

        let left = layout.append(commitID: id("left"), parentIDs: [id("base")])
        #expect(left.topLanes == [id("left"), id("right")])
        #expect(left.bottomLanes == [id("base"), id("right")])
        #expect(left.containsPassthrough(commitID: id("right"), from: 1, to: 1))
        #expect(left.containsParentEdge(from: id("left"), to: id("base")))

        let right = layout.append(commitID: id("right"), parentIDs: [id("base")])
        #expect(right.topLanes == [id("base"), id("right")])
        #expect(right.bottomLanes == [id("base")])
        #expect(right.containsPassthrough(commitID: id("base"), from: 0, to: 0))
        #expect(right.containsParentEdge(from: id("right"), to: id("base")))
        #expect(right.parentEdge(to: id("base"))?.colorIndex == left.nodeColorIndex)
        #expect(right.parentEdge(to: id("base"))?.colorIndex != right.nodeColorIndex)
        #expect(layout.activeCommitIDs == [id("base")])
    }

    @Test func octopusMergeTracksEveryUnprocessedParentInOrder() {
        var layout = GitGraphLayout()

        let row = layout.append(
            commitID: id("octopus"),
            parentIDs: [id("p1"), id("p2"), id("p3")]
        )

        #expect(row.bottomLanes == [id("p1"), id("p2"), id("p3")])
        #expect(layout.activeCommitIDs == [id("p1"), id("p2"), id("p3")])
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p1")))
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p2")))
        #expect(row.containsParentEdge(from: id("octopus"), to: id("p3")))
        #expect(row.parentEdge(to: id("p1"))?.colorIndex == row.nodeColorIndex)
        #expect(row.parentEdge(to: id("p2"))?.colorIndex != row.nodeColorIndex)
        #expect(row.parentEdge(to: id("p3"))?.colorIndex != row.nodeColorIndex)
    }

    @Test func independentRootsDoNotLeaveActiveLanes() {
        var layout = GitGraphLayout()

        let first = layout.append(commitID: id("root-a"), parentIDs: [])
        let second = layout.append(commitID: id("root-b"), parentIDs: [])

        #expect(first.nodeLane == 0)
        #expect(second.nodeLane == 0)
        #expect(first.bottomLanes == [])
        #expect(second.bottomLanes == [])
        #expect(first.segments.isEmpty)
        #expect(second.segments.isEmpty)
        #expect(layout.activeCommitIDs == [])
    }

    @Test func appendingMoreRowsDoesNotMutateEarlierOutput() {
        var layout = GitGraphLayout()

        let first = layout.append(commitID: id("merge"), parentIDs: [id("left"), id("right")])
        let captured = first

        _ = layout.append(commitID: id("left"), parentIDs: [id("base")])
        _ = layout.append(commitID: id("right"), parentIDs: [id("base")])

        #expect(first == captured)
        #expect(first.bottomLanes == [id("left"), id("right")])
    }

    @Test func pagedAppendMatchesSinglePassRowsAndFinalLanes() {
        let history: [(GitCommitID, [GitCommitID])] = [
            (id("merge"), [id("left"), id("right")]),
            (id("left"), [id("base")]),
            (id("right"), [id("base")]),
            (id("base"), []),
            (id("next-root"), []),
        ]

        var singlePass = GitGraphLayout()
        let singleRows = history.map { singlePass.append(commitID: $0.0, parentIDs: $0.1) }

        var paged = GitGraphLayout()
        let firstPage = history.prefix(2).map { paged.append(commitID: $0.0, parentIDs: $0.1) }
        let secondPage = history.dropFirst(2).map { paged.append(commitID: $0.0, parentIDs: $0.1) }

        #expect(firstPage + secondPage == singleRows)
        #expect(paged.activeCommitIDs == singlePass.activeCommitIDs)
    }

    @Test func pagedAppendPreservesLaneColorsAcrossBoundary() {
        let history: [(GitCommitID, [GitCommitID])] = [
            (id("merge"), [id("left"), id("right")]),
            (id("left"), [id("base")]),
            (id("right"), [id("base")]),
            (id("base"), [id("root")]),
            (id("root"), []),
        ]

        var singlePass = GitGraphLayout()
        let singleRows = history.map { singlePass.append(commitID: $0.0, parentIDs: $0.1) }

        var paged = GitGraphLayout()
        let pageOne = history.prefix(3).map { paged.append(commitID: $0.0, parentIDs: $0.1) }
        let pageTwo = history.dropFirst(3).map { paged.append(commitID: $0.0, parentIDs: $0.1) }
        let pagedRows = pageOne + pageTwo

        #expect(pagedRows.map(\.nodeColorIndex) == singleRows.map(\.nodeColorIndex))
        #expect(pagedRows.map(\.segments) == singleRows.map(\.segments))
    }

    @Test func duplicateParentIDsProduceOneActiveLaneAndOneEdge() {
        var layout = GitGraphLayout()

        let row = layout.append(commitID: id("dup"), parentIDs: [id("parent"), id("parent")])

        #expect(row.parentIDs == [id("parent")])
        #expect(row.bottomLanes == [id("parent")])
        #expect(row.segments.filter { $0.kind == .parent }.count == 1)
    }
}

private func id(_ rawValue: String) -> GitCommitID {
    GitCommitID(rawValue)
}

private extension GitGraphRow {
    func containsIncoming(commitID: GitCommitID, lane: Int) -> Bool {
        segments.contains {
            $0.kind == .incoming
                && $0.commitID == commitID
                && $0.from == .top(lane: lane)
                && $0.to == .node(lane: lane)
        }
    }

    func containsPassthrough(commitID: GitCommitID, from: Int, to: Int) -> Bool {
        segments.contains {
            $0.kind == .passthrough
                && $0.commitID == commitID
                && $0.from == .top(lane: from)
                && $0.to == .bottom(lane: to)
        }
    }

    func containsParentEdge(from commitID: GitCommitID, to parentID: GitCommitID) -> Bool {
        segments.contains {
            $0.kind == .parent
                && $0.commitID == commitID
                && $0.parentID == parentID
        }
    }

    func incomingSegment() -> GitGraphSegment? {
        segments.first { $0.kind == .incoming }
    }

    func parentEdge(to parentID: GitCommitID) -> GitGraphSegment? {
        segments.first {
            $0.kind == .parent
                && $0.parentID == parentID
        }
    }
}
