import AppKit
import Testing
@testable import Ghostty

@MainActor
struct VerticalNativeTabOutlineTests {
    @Test func nativeRowsAndCloseButtonsShareTheDeliveredHoverState() throws {
        final class Window: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isVisible: Bool { true }
        }
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        let second = try fixture.tab(parent: first)
        let config = NativeTabOutlineConfiguration(
            groups: GhosttyTabOrganizationModel().groups(tabs: [first, second], grouping: .none, ordering: .manual),
            selectedID: ObjectIdentifier(first), layoutState: first.tabLayoutState, controller: first, rowHeight: 32,
            presentation: { tab in
                .init(title: "Tab \(tab.actualIndex)", remoteBreadcrumb: nil, shortcut: "\(tab.actualIndex)",
                      icon: .systemSymbol("terminal"), activity: nil, selected: tab.controller === first, hovered: false)
            })
        let controller = NativeTabOutlineController(config)
        let window = Window(contentRect: .init(x: 0, y: 0, width: 320, height: 160),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.contentView = nil; window.close() }
        controller.update(config)
        controller.view.layoutSubtreeIfNeeded()
        let outline = controller.outline
        outline.updateTrackingAreas()
        let owner = try #require(outline.trackingAreas.first { $0.owner is NativeTableHover }?.owner as? NativeTableHover)
        let rows = try (0..<2).map { try #require(outline.rowView(atRow: $0, makeIfNecessary: true) as? NativeHoverRowView) }
        func closeButton(in view: NSView) -> NativeActionControl? {
            if let button = view as? NativeActionControl, button.accessibilityLabel() == "Close Tab" { return button }
            return view.subviews.lazy.compactMap(closeButton).first
        }
        let buttons = try (0..<2).map { index in
            let cell = try #require(outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? NativeTabCell)
            #expect(cell.superview === rows[index])
            return try #require(closeButton(in: cell))
        }
        let selection = outline.selectedRowIndexes
        for index in [1, 0, 1, 0] {
            let rect = outline.rect(ofRow: index)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: outline.convert(.init(x: 80, y: rect.midY), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 0, pressure: 0))
            #expect(NSApp.sendAction(#selector(NSResponder.mouseMoved(with:)), to: owner, from: event))
            for row in 0..<2 {
                #expect(rows[row].isHovered == (row == index))
                #expect(buttons[row].isHidden == (row != index))
            }
            #expect(outline.selectedRowIndexes == selection)
        }
        #expect(NSApp.sendAction(#selector(NSResponder.mouseExited(with:)), to: owner, from: NSEvent()))
        #expect(rows.allSatisfy { !$0.isHovered })
        #expect(buttons.allSatisfy { $0.isHidden })
    }

    private func descendantLabel(_ view: NSView, matching value: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == value { return field }
        for child in view.subviews {
            if let field = descendantLabel(child, matching: value) { return field }
        }
        return nil
    }

    @Test func dropResolvesNativeIndexesInsteadOfShortcutNumbers() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<4).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        let windows = controllers.compactMap(\.window)
        defer { for window in windows { window.delegate = nil; window.close() } }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let nativeGroup = try #require(windows[0].tabGroup)
        let ordered = nativeGroup.windows.compactMap { $0.windowController as? TerminalController }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let model = GhosttyTabOrganizationModel()
        var groups = model.groups(tabs: ordered, grouping: .none, ordering: .manual)
        func makeView() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(groups: groups, selectedID: ObjectIdentifier(ordered[0]),
                                 layoutState: state, controller: ordered[0], rowHeight: 32,
                                 presentation: { _ in nil })
        }
        let coordinator = NativeTabOutlineController(makeView())
        let column = NSTableColumn(identifier: .init("tab"))
        coordinator.outline.addTableColumn(column)
        coordinator.outline.outlineTableColumn = column
        coordinator.outline.dataSource = coordinator
        coordinator.outline.delegate = coordinator
        coordinator.update(makeView())
        #expect(groups[0].tabs.map(\.actualIndex) == [1, 2, 3, 4])
        for source in ordered {
            for insertion in 0...ordered.count {
                let result = try #require(coordinator.resolveDrop(
                    sourceID: source.tabSessionID, item: nil, index: insertion
                ))
                #expect(result.0 === source)
                #expect(result.1 == insertion)
            }
        }
        // A group-end insertion belongs before the next group's first tab.
        groups = [
            .init(id: "first", title: "First", icon: nil, tabs: Array(groups[0].tabs.prefix(2))),
            .init(id: "second", title: "Second", icon: nil, tabs: Array(groups[0].tabs.suffix(2)))
        ]
        coordinator.update(makeView())
        let first = try #require(coordinator.nodes["group:first"])
        let second = try #require(coordinator.nodes["group:second"])
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 2)?.1 == 2)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: second, index: 0) == nil)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: -1) == nil)
        // A native reorder can precede publication of the next presentation.
        nativeGroup.removeWindow(try #require(ordered[1].window))
        nativeGroup.insertWindow(try #require(ordered[1].window), at: 0)
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 1)?.1 == 0)
        nativeGroup.removeWindow(try #require(ordered[1].window))
        #expect(coordinator.resolveDrop(sourceID: ordered[0].tabSessionID, item: first, index: 1) == nil)
    }

    @Test func tabDevelopmentProfileIsIsolated() {
        guard Bundle.main.bundleIdentifier == "com.jischeng.omg.debug.tab" else { return }
        #expect(OMGApplicationEnvironment.isDevelopment)
        #expect(OMGApplicationEnvironment.channel() == "debug-tab")
        #expect(OMGApplicationEnvironment.settingsFileURL().path.contains("oh-my-ghostty-dev-tab"))
        #expect(OMGApplicationEnvironment.applicationSupportURL().lastPathComponent == "OMG Dev Tab")
    }

    @Test func nativeCellRefreshesFocusAndDetachesWhenReconfigured() async throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let nativeApp = try #require(delegate.ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let first = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let second = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        let firstSurface = try #require(first.surfaceTree.first)
        let secondSurface = Ghostty.SurfaceView(nativeApp, baseConfig: config)
        first.surfaceTree = .init(root: .split(.init(
            direction: .horizontal, ratio: 0.5,
            left: .leaf(view: firstSurface), right: .leaf(view: secondSurface)
        )), zoomed: nil)
        first.focusedSurface = firstSurface
        defer {
            for controller in [first, second] {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }

        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let tabs = [GhosttyOrganizedTab(controller: first, actualIndex: 1)]
        var presentationCalls = 0
        func view() -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: [.init(id: "test", title: nil, icon: nil, tabs: tabs)],
                selectedID: ObjectIdentifier(first), layoutState: state, controller: first,
                rowHeight: 32,
                presentation: { tab in
                    presentationCalls += 1
                    let title: String
                    if let override = tab.controller.titleOverride {
                        title = override
                    } else if tab.controller === first {
                        title = tab.controller.focusedSurface === secondSurface ? "Focused secondary" : "Focused primary"
                    } else {
                        title = "Second controller"
                    }
                    return .init(
                        title: title, remoteBreadcrumb: nil, shortcut: nil,
                        icon: .systemSymbol("terminal"), activity: nil,
                        selected: false, hovered: false
                    )
                }
            )
        }

        let coordinator = NativeTabOutlineController(view())
        let outline = coordinator.outline
        let column = NSTableColumn(identifier: .init("tab"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.setFrameSize(NSSize(width: 320, height: 80))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update(view())
        outline.reloadData()
        let firstCell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeTabCell)
        #expect(firstCell.toolTip == "Focused primary")
        #expect(descendantLabel(firstCell, matching: "Focused primary")?.stringValue == "Focused primary")

        // A controller-only title change must refresh this cell without an
        // NSViewRepresentable/coordinator update.
        first.titleOverride = "Background override"
        try await Task.sleep(for: .milliseconds(20))
        #expect(firstCell.toolTip == "Background override")
        #expect(descendantLabel(firstCell, matching: "Background override")?.stringValue == "Background override")

        first.titleOverride = nil
        first.focusedSurface = secondSurface
        try await Task.sleep(for: .milliseconds(20))
        #expect(firstCell.toolTip == "Focused secondary")

        // Settle the initial tree publisher and any coalesced refresh before
        // testing that the same cell detaches from its previous controller.
        try await Task.sleep(for: .milliseconds(20))
        let secondTab = GhosttyOrganizedTab(controller: second, actualIndex: 1)
        firstCell.configure(
            tab: secondTab, title: nil, presentation: view().presentation,
            canClose: true, selected: false, select: {}, close: {}
        )
        #expect(firstCell.toolTip == "Second controller")
        try await Task.sleep(for: .milliseconds(20))
        let callsAfterReplacement = presentationCalls

        first.titleOverride = "Old controller emission"
        try await Task.sleep(for: .milliseconds(20))
        #expect(presentationCalls == callsAfterReplacement)
        #expect(firstCell.toolTip == "Second controller")

        second.titleOverride = "New controller emission"
        try await Task.sleep(for: .milliseconds(20))
        #expect(presentationCalls == callsAfterReplacement + 1)
        #expect(firstCell.toolTip == "New controller emission")
    }

    @Test func measureRepeatedNativeTabCreationAndClose() async throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let first = TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        var controllers = [first]
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        first.showWindow(nil)
        var createTimes: [Double] = []
        var closeTimes: [Double] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            let next = try #require(TerminalController.newTab(delegate.ghostty, from: controllers.last?.window, withBaseConfig: config))
            createTimes.append(ProcessInfo.processInfo.systemUptime - start)
            controllers.append(next)
            try await Task.sleep(for: .milliseconds(30))
        }
        for controller in controllers.dropFirst().reversed() {
            let start = ProcessInfo.processInfo.systemUptime
            controller.closeTabImmediately(registerRedo: false)
            closeTimes.append(ProcessInfo.processInfo.systemUptime - start)
            try await Task.sleep(for: .milliseconds(30))
        }
        print("TAB_SYNC_COST create_ms=\(createTimes.map { Int($0 * 1000) }) close_ms=\(closeTimes.map { Int($0 * 1000) })")
    }

    @Test func everySingleMoveIsRecognized() throws {
        let original = ["a", "b", "c", "d", "e"]
        for source in original.indices {
            for destination in original.indices where source != destination {
                var expected = original
                expected.insert(expected.remove(at: source), at: destination)
                let (from, to) = try #require(NativeTabOutlineController.singleMove(from: original, to: expected))
                var actual = original
                actual.insert(actual.remove(at: from), at: to)
                #expect(actual == expected)
            }
        }
    }

    @Test func nativeWindowReorderPreservesSelectionAndSurfaces() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<5).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        let windows = controllers.compactMap(\.window)
        let surfaces = controllers.map { $0.surfaceTree.first?.id }
        defer { for window in windows { window.delegate = nil; window.close() } }
        for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
        let group = try #require(windows[0].tabGroup)
        let original = group.windows
        let selected = original[2]
        group.selectedWindow = selected
        for destination in [4, 0, 3, 1] {
            let moved = original[0]
            let source = try #require(group.windows.firstIndex(of: moved))
            let controller = try #require(moved.windowController as? TerminalController)
            #expect(controllers[0].reorderTab(controller, toInsertionIndex: destination + (source < destination ? 1 : 0)))
            #expect(group.windows[destination] === moved)
            #expect(group.selectedWindow === selected)
            #expect(Set(group.windows.map(ObjectIdentifier.init)) == Set(original.map(ObjectIdentifier.init)))
            #expect(controllers.map { $0.surfaceTree.first?.id } == surfaces)
        }
    }

    @Test func selectionUpdatesKeepNativeRowIdentityWithoutReloading() throws {
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 30"
        let controllers = (0..<3).map { _ in
            TerminalController(delegate.ghostty, withBaseConfig: config, tabLayout: .vertical)
        }
        defer {
            for controller in controllers {
                controller.window?.delegate = nil
                controller.window?.close()
            }
        }
        let state = VerticalTabWindowLayoutState(isSidebarVisible: true)
        let tabs = controllers.enumerated().map { GhosttyOrganizedTab(controller: $0.element, actualIndex: $0.offset + 1) }
        var groups = [GhosttyTabGroupPresentation(id: "test", title: "Project", icon: nil, tabs: tabs)]
        func view(selected: Int) -> NativeTabOutlineConfiguration {
            NativeTabOutlineConfiguration(
                groups: groups, selectedID: ObjectIdentifier(controllers[selected]),
                layoutState: state, controller: controllers[0], rowHeight: 32,
                presentation: { _ in nil }
            )
        }
        let coordinator = NativeTabOutlineController(view(selected: 0))
        let outline = coordinator.outline
        let column = NSTableColumn(identifier: .init("tab"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.update(view(selected: 0))
        let originalNode = try #require(outline.item(atRow: 2) as? NativeTabNode)
        #expect(outline.numberOfRows == 4)
        #expect(outline.selectedRow == 1)
        coordinator.update(view(selected: 1))
        #expect(outline.selectedRow == 2)
        #expect(coordinator.reloadCount == 1)
        #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        for index in 0..<20 { coordinator.update(view(selected: index % 3)) }
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.outlineView(outline, shouldSelectItem: coordinator.roots[0]) == false)
        groups[0].tabs = [tabs[1], tabs[2], tabs[0]]
        coordinator.update(view(selected: 1))
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.moveCount == 1)
        #expect(outline.item(atRow: 1) as? NativeTabNode === originalNode)
        #expect(outline.selectedRow == 1)
        groups[0].tabs = tabs
        coordinator.update(view(selected: 1))
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.moveCount == 2)
        #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        #expect(outline.selectedRow == 2)
        for _ in 0..<12 {
            groups[0].tabs = [tabs[1], tabs[2]]
            coordinator.update(view(selected: 1))
            #expect(outline.numberOfRows == 3)
            #expect(outline.item(atRow: 1) as? NativeTabNode === originalNode)
            groups[0].tabs = tabs
            coordinator.update(view(selected: 1))
            #expect(outline.numberOfRows == 4)
            #expect(outline.item(atRow: 2) as? NativeTabNode === originalNode)
        }
        #expect(coordinator.reloadCount == 1)
        #expect(coordinator.membershipUpdateCount == 24)
    }
}
