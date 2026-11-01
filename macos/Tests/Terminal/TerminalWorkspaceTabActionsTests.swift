import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceTabActionsTests {
    private struct WorkspaceTabs {
        let personal: [TerminalController]
        let work: [TerminalController]
        let workID: UUID
    }

    private func makeWorkspaceTabs(
        _ fixture: TerminalWorkspaceRefactorTests.Fixture,
        personalCount: Int = 2,
        workCount: Int = 3
    ) async throws -> WorkspaceTabs {
        let first = try fixture.tab()
        first.showWindow(nil)
        var personal = [first]
        for _ in 1..<personalCount {
            personal.append(try fixture.tab(parent: try #require(personal.last)))
        }
        try await Task.sleep(for: .milliseconds(100))
        let personalSelection = try #require(personal.last)
        personalSelection.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(personalSelection)

        let workID = try #require(fixture.store.create(name: "Work actions", symbol: "briefcase", color: "blue"))
        let firstWorkTab = try #require(fixture.coordinator.switchWorkspace(to: workID, from: personalSelection))
        fixture.controllers.append(firstWorkTab)
        var work = [firstWorkTab]
        for _ in 1..<workCount {
            work.append(try fixture.tab(workspace: workID, parent: try #require(work.last)))
        }
        try await Task.sleep(for: .milliseconds(100))
        let workSelection = try #require(work.last)
        workSelection.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(workSelection)
        try await Task.sleep(for: .milliseconds(80))
        return .init(personal: personal, work: work, workID: workID)
    }

    @Test func numericAndNextTabUseOnlyTheCurrentWorkspaceProjection() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture)
        let firstWork = try #require(tabs.work.first)
        let group = try #require(firstWork.window?.tabGroup)
        let workspaceWindows = firstWork.workspaceTabWindows
        let secondWindow = try #require(workspaceWindows.dropFirst().first)
        let thirdWindow = try #require(workspaceWindows.last)

        #expect(Set(firstWork.workspaceTabWindows.compactMap {
            ($0.windowController as? TerminalController)?.tabSessionID
        }) == Set(tabs.work.map(\.tabSessionID)))
        #expect(group.windows.count > firstWork.workspaceTabWindows.count)
        #expect(TerminalController.selectTab(digit: 2, in: firstWork.window))
        #expect(group.selectedWindow === secondWindow)

        guard let selectedController = secondWindow.windowController as? TerminalController,
              let focused = selectedController.focusedSurface else {
            Issue.record("The tab action fixture must have a focused surface.")
            return
        }
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyGotoTab,
            object: focused,
            userInfo: [Ghostty.Notification.GotoTabKey: GHOSTTY_GOTO_TAB_NEXT]
        )
        #expect(group.selectedWindow === thirdWindow)
        #expect(!tabs.personal.contains { $0.window === group.selectedWindow })
    }

    @Test func closeOtherAndRightLeaveParkedWorkspaceTabsAlone() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture, personalCount: 2, workCount: 3)
        let parkedSurfaces = Dictionary(uniqueKeysWithValues: tabs.personal.map {
            ($0.tabSessionID, Array($0.surfaceTree).map(ObjectIdentifier.init))
        })
        let workFirst = try #require(tabs.work.first)
        let workGroup = try #require(workFirst.window?.tabGroup)

        workFirst.closeOtherTabsImmediately()
        try await Task.sleep(for: .milliseconds(80))
        #expect(tabs.work.dropFirst().allSatisfy {
            !fixture.coordinator.liveControllers.contains($0)
        })
        for parked in tabs.personal {
            #expect(parked.workspacePresentationIsParked)
            #expect(Array(parked.surfaceTree).map(ObjectIdentifier.init) ==
                (try #require(parkedSurfaces[parked.tabSessionID])))
        }

        let notesID = try #require(fixture.store.create(name: "Notes actions", symbol: "doc.text", color: "mint"))
        let firstNotesTab = try #require(fixture.coordinator.switchWorkspace(to: notesID, from: workFirst))
        fixture.controllers.append(firstNotesTab)
        let secondNotesTab = try fixture.tab(workspace: notesID, parent: firstNotesTab)
        let thirdNotesTab = try fixture.tab(workspace: notesID, parent: secondNotesTab)
        firstNotesTab.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(firstNotesTab)
        try await Task.sleep(for: .milliseconds(100))

        firstNotesTab.closeTabsOnTheRightImmediately()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!fixture.coordinator.liveControllers.contains(secondNotesTab))
        #expect(!fixture.coordinator.liveControllers.contains(thirdNotesTab))
        #expect(tabs.personal.allSatisfy { $0.isAvailableForWorkspace })
        #expect(fixture.coordinator.liveControllers.contains(workFirst))
        #expect(workFirst.window?.tabGroup === workGroup)
    }

    @Test func closingTheLastParkedTabPreservesTheSelectedWorkspace() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture, personalCount: 1, workCount: 1)
        let parked = try #require(tabs.personal.first)
        let active = try #require(tabs.work.first)
        let group = try #require(active.window?.tabGroup)
        let activeSurface = try #require(active.surfaceTree.first)

        #expect(parked.workspacePresentationIsParked)
        #expect(group.selectedWindow === active.window)
        parked.closeTabImmediately(registerRedo: false)

        #expect(group.selectedWindow === active.window)
        #expect(active.isAvailableForWorkspace)
        #expect(active.window?.contentView != nil)
        #expect(active.surfaceTree.first === activeSurface)
        #expect(fixture.coordinator.store.snapshot.windows?[active.windowSessionID]?.currentWorkspace == tabs.workID)
    }

    @Test func closingTheLastActiveTabKeepsOtherWorkspaceSurfaces() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture, personalCount: 2, workCount: 1)
        let active = try #require(tabs.work.first)
        let parked = try #require(tabs.personal.first)
        let parkedSurface = try #require(parked.surfaceTree.first)

        active.closeTabImmediately(registerRedo: false)

        #expect(!fixture.coordinator.liveControllers.contains(active))
        #expect(parked.isAvailableForWorkspace)
        #expect(parked.window?.contentView != nil)
        #expect(parked.surfaceTree.first === parkedSurface)
    }

    @Test func nativePerformCloseCannotCloseParkedWorkspaceWindows() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture, personalCount: 2, workCount: 2)
        let active = try #require(tabs.work.first)
        let activeWindow = try #require(active.window)
        let parkedSurfaces = Dictionary(uniqueKeysWithValues: tabs.personal.map {
            ($0.tabSessionID, Array($0.surfaceTree).map(ObjectIdentifier.init))
        })

        activeWindow.performClose(nil)
        for _ in 0..<30 {
            if let sheet = activeWindow.attachedSheet {
                NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.cancel.rawValue)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        for parked in tabs.personal {
            #expect(parked.isAvailableForWorkspace)
            #expect(Array(parked.surfaceTree).map(ObjectIdentifier.init) ==
                (try #require(parkedSurfaces[parked.tabSessionID])))
        }
    }

    @Test func reorderingWorkspaceTabsDoesNotReorderForeignTabs() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let tabs = try await makeWorkspaceTabs(fixture, personalCount: 3, workCount: 2)
        let personal = tabs.personal
        let work = tabs.work
        let workTab = try #require(work.first)
        _ = try #require(fixture.coordinator.switchWorkspace(to: personal[0].workspaceID, from: workTab))
        let group = try #require(personal[0].window?.tabGroup)
        let originalSelection = group.selectedWindow
        let interleavedForeignWindow = try #require(work.last?.window)
        let arrangement = TerminalWorkspacePresentationTransaction([])
        group.removeWindow(interleavedForeignWindow)
        group.insertWindow(interleavedForeignWindow, at: 1)
        group.selectedWindow = originalSelection
        arrangement.publish { TerminalController.refreshTabs(in: group) }
        try await Task.sleep(for: .milliseconds(80))
        try #require(fixture.store.snapshot.windows?[personal[0].windowSessionID]?.currentWorkspace == personal[0].workspaceID)
        try #require(group.selectedWindow === personal[2].window)
        let foreignBefore = group.windows.filter {
            ($0.windowController as? TerminalController)?.workspaceID != personal[0].workspaceID
        }
        let activeBefore = personal[0].workspaceTabWindows
        let movedWindow = try #require(personal[2].window)
        let sourceIndex = try #require(activeBefore.firstIndex(of: movedWindow))
        let destinationIndex = VerticalTabDropPolicy.destinationIndex(
            sourceIndex: sourceIndex,
            insertionIndex: 0,
            tabCount: activeBefore.count
        )
        var expectedActiveOrder = activeBefore
        expectedActiveOrder.remove(at: sourceIndex)
        expectedActiveOrder.insert(movedWindow, at: destinationIndex)

        #expect(personal[2].workspaceID == personal[0].workspaceID)
        #expect(activeBefore.count == 3)
        #expect(sourceIndex > 0)
        #expect(personal[0].window?.tabGroup === group)
        #expect(personal[2].window?.tabGroup === group)
        let selectedBefore = group.selectedWindow
        let committed = personal[0].reorderTab(personal[2], toInsertionIndex: 0)
        #expect(committed)
        #expect(personal[0].workspaceTabWindows == expectedActiveOrder)
        #expect(group.selectedWindow === selectedBefore)
        #expect(fixture.store.snapshot.windows?[personal[0].windowSessionID]?.currentWorkspace == personal[0].workspaceID)
        try await Task.sleep(for: .milliseconds(120))
        let foreignAfter = group.windows.filter {
            ($0.windowController as? TerminalController)?.workspaceID != personal[0].workspaceID
        }
        #expect(personal[0].workspaceTabWindows == expectedActiveOrder)
        #expect(foreignAfter == foreignBefore)
        #expect(group.selectedWindow === selectedBefore)
        #expect(work.allSatisfy { $0.workspacePresentationIsParked })
    }
}
