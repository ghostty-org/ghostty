import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryNavigatorTests {
    private func fixture() -> [GitHistoryCommit] {
        let refs: [GitRefDecoration] = [.init(name: "main", kind: .currentBranch)] +
            (0..<7).map { .init(name: "origin/fix/lake-search-api-with-a-very-long-name-\($0)", kind: .remoteBranch) } +
            (0..<8).map { .init(name: "1.1.147_lake-search-api_prod-long-release-tag-\($0)", kind: .tag) }
        return [("main001", ["main002", "side001", "side002", "side003"]),
                ("main002", ["base001"]), ("side003", ["base001"]),
                ("side002", ["base001"]), ("side001", ["base001"]),
                ("base001", ["root001"]), ("root001", [])].enumerated().map { index, value in
            GitHistoryCommit(id: .init(value.0), parentIDs: value.1.map(GitCommitID.init),
                authorName: "renjiejiang02", authorEmail: "renjiejiang02@deeproute.ai",
                authoredAt: Date(timeIntervalSince1970: 1_788_700_620),
                subject: index < 2 ? "fix(lake-search): pin available rapidjson \(index)" : "Merge work on \(value.0)",
                refDecorations: index == 0 ? refs : (index == 1 ? [refs[1]] : (index == 2 ? [refs[refs.count - 1]] : [])))
        }
    }

    @Test func rowExtentsStayCompactAndBoundaryCoordinatesMatch() {
        let rows = GitGraphLayout.rows(for: fixture())
        let columns = rows.map { GitGraphColumnLayout(row: $0) }
        #expect(columns.last?.contentX == 16)
        #expect(columns[0].contentX == 46) // Three parent lanes right of the node.
        #expect(columns[2].contentX == 46) // Rightmost lane now contains a node.
        for index in 0..<(rows.count - 1) {
            #expect(rows[index].bottomLanes == rows[index + 1].topLanes)
            for lane in rows[index].bottomLanes.indices {
                #expect(columns[index].edgeX(lane: lane, count: rows[index].bottomLanes.count) ==
                        columns[index + 1].edgeX(lane: lane, count: rows[index + 1].topLanes.count))
            }
        }
        for (row, column) in zip(rows, columns) {
            #expect(column.middleX(lane: row.nodeLane, row: row) + 4.5 <= column.width)
            for segment in row.segments {
                #expect(column.edgeX(lane: segment.from.lane, count: 0) + 0.8 <= column.width)
                #expect(column.edgeX(lane: segment.to.lane, count: 0) + 0.8 <= column.width)
            }
        }
    }

    @Test func singleLaneAndMergeReserveOnlyTheirActualDrawing() {
        var engine = GitGraphLayout()
        let single = engine.append(commitID: .init("tip"), parentIDs: [.init("merge")])
        let merge = engine.append(commitID: .init("merge"), parentIDs: [.init("main"), .init("side")])
        let branch = engine.append(commitID: .init("side"), parentIDs: [.init("main")])
        let root = engine.append(commitID: .init("main"), parentIDs: [])
        // Pipe model: `main` keeps both branch pipes until it terminates them,
        // so its row still spans the two converging lanes (26), matching
        // lazygit / Git Graph's two-lines-into-the-node rendering.
        #expect([single, merge, branch, root].map { GitGraphColumnLayout(row: $0).contentX } == [16, 26, 26, 26])
    }

    @Test func firstVisibleNodeHasNoInventedIncomingEdgeButContinuationDoes() {
        let commits = fixture()
        let rows = GitGraphLayout.rows(for: commits)
        #expect(rows[0].topLanes.isEmpty)
        #expect(!rows[0].segments.contains { $0.kind == .incoming })
        #expect(rows[1].segments.contains { $0.kind == .incoming })
        var continued = GitGraphLayout(activeLanes: [commits[0].id], primaryFirstParents: [commits[0].id])
        #expect(continued.append(commitID: commits[0].id, parentIDs: commits[0].parentIDs)
            .segments.contains { $0.kind == .incoming })
    }

    @Test func extremeNavigatorContentKeepsWidthsHeightsAndTopDisclosureStable() async throws {
        for width in [220.0, 360.0] {
            let commits = fixture()
            let first = commits[0]
            let body = (1...18).map { "Line \($0): explain the available rapidjson dependency and compatibility." }.joined(separator: "\n")
            let detail = GitCommitExpansion(metadata: .init(commitID: first.id, authorName: first.authorName,
                authorEmail: first.authorEmail, authoredAt: "2026-09-06", parents: first.parentIDs,
                message: first.subject + "\n\n" + body),
                files: [.init(path: "foo.swift", status: "M"), .init(path: "bar.swift", status: "A"),
                        .init(path: "new.swift", oldPath: "old.swift", status: "R100")],
                statistics: .init(additions: 642, deletions: 87, binaryFiles: 0))
            var root = GitHistoryTable(commits: commits, selectedCommitID: nil, headCommitID: first.id,
                expandedCommits: [:], onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in })
            let host = NSHostingView(rootView: root.background(Color(NSColor.windowBackgroundColor)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 730),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded()
            let table = try #require(find(NSTableView.self, in: host))
            func cell(_ row: Int) throws -> NSView {
                let value = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                value.layoutSubtreeIfNeeded()
                return value
            }
            let foldedMain = try cell(0)
            let foldedHeight = table.rect(ofRow: 0).height
            let foldedBadges = try #require(find(GitRefBadgesView.self, in: foldedMain))
            let badge = try #require(foldedBadges.subviews.compactMap { $0 as? NSButton }.last)
            badge.performClick(nil)
            let popover = try #require(foldedBadges.popover)
            #expect(popover.isShown)
            let fullList = try #require(
                popover.contentViewController as? GitReferenceListPopoverController
            )
            #expect(first.refDecorations.allSatisfy { fullList.refsForTesting.contains($0) })
            #expect(find(GitCollectionTableView.self, in: fullList.view) != nil)
            try await capture(popover.contentViewController!.view, path: "/tmp/omg-git-refs-popover-\(Int(width)).png")
            popover.close()
            root.expandedCommits = [first.id: detail]
            let coordinator = try #require(table.target as? GitHistoryTable.Coordinator)
            coordinator.update(root)
            let main = try cell(0)
            let nextMain = try cell(6)
            let branch = try cell(7)
            let subject = try #require(find(NSTextField.self, in: main))
            #expect(subject.frame.minX == find(NSTextField.self, in: nextMain)?.frame.minX)
            #expect(subject.frame.minX == find(NSTextField.self, in: branch)?.frame.minX)
            #expect(subject.bounds.width > width * 0.65)
            #expect(foldedHeight == table.rect(ofRow: 6).height)
            func metadataButtons(_ view: NSView) -> [InspectorMetadataText] {
                if let button = view as? InspectorMetadataText { return [button] }
                return view.subviews.flatMap(metadataButtons)
            }
            let meta = metadataButtons(main)
            #expect(meta.contains { $0.value == "renjiejiang02@deeproute.ai" })
            #expect(meta.contains { $0.value == "main001" })
            for value in [nextMain, branch] {
                let group = try #require(find(GitRefBadgesView.self, in: value))
                let named = group.subviews.compactMap { $0 as? NSButton }
                #expect(named.count == 1 && named[0].frame.width <= 104)
                #expect(group.bounds.height == 17)
            }
            let badges = try #require(find(GitRefBadgesView.self, in: main))
            #expect(badges.bounds.height == 17)
            let message = try cell(5)
            let control = try #require(find(NSButton.self, in: message))
            let controlFrame = control.frame
            let filePosition = table.rect(ofRow: 2)
            control.performClick(nil)
            let openControl = try #require(find(NSButton.self, in: try cell(5)))
            #expect(openControl.title == GitL10n.format("Commit message · {0} lines", "18"))
            #expect(openControl.frame == controlFrame)
            #expect(table.rect(ofRow: 2) == filePosition)
            try await capture(host, path: "/tmp/omg-git-navigator-message-open-\(Int(width)).png")
            openControl.performClick(nil)
            try await capture(host, path: "/tmp/omg-git-navigator-\(Int(width)).png")

        }
    }

    @Test func textFollowsEachRowsActualGraphWidth() async throws {
        let input: [(String, [String], String)] = [
            ("tip", ["main", "side", "probe"], "feat: mainline start"),
            ("probe", ["base"], "feat: side branch work"),
            ("main", ["base"], "feat: mainline continues"),
            ("base", ["root"], "feat: shared mainline ancestor"),
            ("side", ["root"], "feat: another branch"),
            ("root", [], "feat: mainline root"),
        ]
        let commits = input.map { value in GitHistoryCommit(id: .init(value.0), parentIDs: value.1.map(GitCommitID.init),
            authorName: "Author", authorEmail: "author@example.com", authoredAt: Date(timeIntervalSince1970: 0), subject: value.2) }
        for width in [220.0, 360.0] {
            let view = NSHostingView(rootView: GitHistoryTable(commits: commits, selectedCommitID: nil,
                onSelect: { _ in }, onOpen: { _ in }, onShowInTerminal: { _ in }).background(Color(NSColor.windowBackgroundColor)))
            view.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(120))
            let table = try #require(find(NSTableView.self, in: view))
            func x(_ row: Int) throws -> CGFloat {
                let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                return try #require(cell.subviews.compactMap { $0 as? NSTextField }.first).frame.minX
            }
            // Pipe model: lanes stay occupied until the node where their two
            // lines converge, so the shared-ancestor rows keep the wider graph.
            for (row, expected) in [36.0, 36, 36, 36, 26, 26].enumerated() {
                #expect(try x(row) == expected)
            }
            try await capture(view, path: "/tmp/omg-git-mainline-\(Int(width)).png")
        }
    }

    @Test func subjectMetadataAndRefsShareTheRenderedLeadingEdge() async throws {
        let commits = fixture()
        let rows = GitGraphLayout.rows(for: commits)
        for row in [rows[0], rows[2], rows.last!] {
            let column = GitGraphColumnLayout(row: row)
            let commit = GitHistoryCommit(id: row.commitID, parentIDs: row.parentIDs, authorName: "MMMM",
                authorEmail: "MMMM", authoredAt: .distantPast, subject: "MMMM")
            let cell = GitHistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 78))
            cell.configure(commit: commit, graph: row, graphLayout: column, summary: ("MMMM", [.init(name: "MMMM", kind: .head)]),
                           state: (false, false), toggle: {})
            let window = NSWindow(contentRect: cell.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = cell
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            cell.layoutSubtreeIfNeeded()
            let subject = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
            // Equal glyph/font isolates control-internal padding from glyph bearings.
            subject.font = .systemFont(ofSize: 10)
            try await Task.sleep(for: .milliseconds(80))
            window.displayIfNeeded()
            let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / cell.bounds.width
            func inkX(_ view: NSView) throws -> CGFloat {
                let rect = view.convert(view.bounds, to: cell)
                for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                        if let color, color.alphaComponent > 0.05, max(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 {
                            return CGFloat(x) / scale
                        }
                    }
                }
                throw NSError(domain: "Missing rendered text: \(type(of: view))", code: 1)
            }
            let titleX = try inkX(subject)
            let metadata = cell.subviews.compactMap { $0 as? GitMetadataLine }
            for line in metadata {
                let first = try #require(line.subviews.compactMap { $0 as? InspectorMetadataText }.first)
                #expect(abs(try inkX(first) - titleX) <= 0.5)
                #expect(line.frame.minX == column.contentX)
            }
            let refs = try #require(find(GitRefBadgesView.self, in: cell))
            let badge = try #require(refs.subviews.compactMap { $0 as? NSButton }.first)
            #expect(subject.frame.minX == refs.frame.minX)
            #expect(badge.attributedTitle.string.first == "M")
        }
    }

    @Test func graphStrokesReachCellBoundariesWithoutCrossingTheHeadHalo() throws {
        let id = GitCommitID("node")
        let parent = GitCommitID("parent")
        let row = GitGraphRow(commitID: id, parentIDs: [parent], topLanes: [id], bottomLanes: [parent],
            nodeLane: 0, nodeColorIndex: 0, segments: [
                .init(kind: .incoming, from: .top(lane: 0), to: .node(lane: 0),
                      colorIndex: 0, commitID: id, parentID: nil),
                .init(kind: .parent, from: .node(lane: 0), to: .bottom(lane: 0),
                      colorIndex: 0, commitID: id, parentID: parent),
            ])
        for height in [56, 78, 156] {
            for head in [false, true] {
                for remote in [false, true] {
                    for section in [GitGraphCellView.Section.commit, .expandedCommit, .continuation, .expansionEnd] {
                        var input = row
                        input.isRemoteOnly = remote
                        let view = GitGraphCellView(frame: NSRect(x: 0, y: 0, width: 20, height: height))
                        view.configure(row: input, isHead: head, section: section)
                        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40,
                            pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        context.cgContext.translateBy(x: 0, y: CGFloat(height * 2))
                        context.cgContext.scaleBy(x: 2, y: -2)
                        view.draw(view.bounds)
                        NSGraphicsContext.restoreGraphicsState()
                        func hasLine(at y: Int) -> Bool {
                            (15...16).contains { x in
                                guard let c = bitmap.colorAt(x: x, y: y * 2)?.usingColorSpace(.deviceRGB) else { return false }
                                return c.alphaComponent > 0.2 && c.blueComponent - c.redComponent > 0.2
                            }
                        }
                        // Every pixel row below the node must carry the line,
                        // including the last pixel row before the next cell.
                        for y in 22..<height {
                            #expect(hasLine(at: y), "Missing line at y=\(y), height=\(height), head=\(head), section=\(section)")
                        }
                        for y in 0..<4 { #expect(hasLine(at: y)) }
                        if head && (section == .commit || section == .expandedCommit) {
                            #expect(!hasLine(at: 8), "The gap inside the HEAD halo must not contain a line stub")
                        }
                    }
                }
            }
        }
    }

    @Test func headHaloMatchesTheLaneColour() throws {
        let id = GitCommitID("node")
        let parent = GitCommitID("parent")
        let row = GitGraphRow(commitID: id, parentIDs: [parent], topLanes: [id], bottomLanes: [parent],
            nodeLane: 0, nodeColorIndex: 1, segments: [
                .init(kind: .incoming, from: .top(lane: 0), to: .node(lane: 0),
                      colorIndex: 1, commitID: id, parentID: nil),
                .init(kind: .parent, from: .node(lane: 0), to: .bottom(lane: 0),
                      colorIndex: 1, commitID: id, parentID: parent),
            ])
        // Lane 0 is x = 8, the node centre is y = 12 and the HEAD halo ring
        // sits at radius 6, so its leftmost band lands on view point (2, 12).
        // That spot carries no node or lane line, only the halo.
        func ringPixel(head: Bool) throws -> NSColor {
            let view = GitGraphCellView(frame: NSRect(x: 0, y: 0, width: 20, height: 78))
            view.configure(row: row, isHead: head)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 156,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.translateBy(x: 0, y: 156)
            context.cgContext.scaleBy(x: 2, y: -2)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return try #require(bitmap.colorAt(x: 4, y: 24)?.usingColorSpace(.deviceRGB))
        }
        let head = try ringPixel(head: true)
        #expect(head.alphaComponent > 0.5)
        // Palette slot 1 is green: the halo must agree with the lane, not with
        // the fixed accent colour it used to be painted with.
        #expect(head.greenComponent - head.blueComponent > 0.2)
        #expect(head.greenComponent - head.redComponent > 0.2)
        let plain = try ringPixel(head: false)
        #expect(plain.alphaComponent < 0.2, "Only the HEAD node draws an outer halo")
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        if let value = view as? T { return value }
        return view?.subviews.compactMap { find(type, in: $0) }.first
    }
    private func capture(_ view: NSView, path: String) async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/omg-git-render") else { return }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
