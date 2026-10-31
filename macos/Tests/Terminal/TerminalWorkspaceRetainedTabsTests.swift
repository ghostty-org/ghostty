import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceRetainedTabsTests {
    @Test func scriptingWindowsKeepWorkspaceTabAndSelectionBoundaries() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        try #require(NSApp.isAppleScriptEnabled, "This integration test needs the default macos-applescript setting")
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        second.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(second)
        let work = try #require(fixture.store.create(name: "Script workspace", symbol: "briefcase", color: "blue"))
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: second))
        fixture.controllers.append(workTab)
        try await Task.sleep(for: .milliseconds(50))
        let personalWindow = ScriptWindow(primaryController: first)
        let workWindow = ScriptWindow(primaryController: workTab)
        #expect(personalWindow.tabs.count == 2)
        #expect(personalWindow.tabIsSelected(second))
        #expect(personalWindow.tabIndex(for: workTab) == nil)
        #expect(workWindow.tabs.count == 1)
        #expect(workWindow.tabIsSelected(workTab))
        #expect(workWindow.tabIndex(for: second) == nil)
        #expect(workTab.window?.tabGroup === first.window?.tabGroup)
    }

    @Test func fortyTabVerticalWorkspacesReuseHostNativeGroup() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let personal = fixture.store.defaultID
        let first = try fixture.tab()
        first.showWindow(nil)
        var personalTabs = [first]
        for _ in 1..<40 {
            personalTabs.append(try fixture.tab(parent: personalTabs.last))
        }
        try await Task.sleep(for: .milliseconds(120))
        let personalSelection = try #require(personalTabs.last)
        personalSelection.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(personalSelection)

        let work = try #require(fixture.store.create(name: "Work retained", symbol: "briefcase", color: "blue"))
        let notes = try #require(fixture.store.create(name: "Notes retained", symbol: "doc.text", color: "mint"))

        let native = fixture.coordinator.native
        let originalAttach = native.attach
        var attachCalls = 0
        native.attach = { parent, child, ordering in
            attachCalls += 1
            return originalAttach(parent, child, ordering)
        }
        defer { native.attach = originalAttach }

        let coldStart = ProcessInfo.processInfo.systemUptime
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: personalSelection))
        let coldSwitchMilliseconds = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        fixture.controllers.append(workTab)
        let workAttachCalls = attachCalls

        let notesTab = try #require(fixture.coordinator.switchWorkspace(to: notes, from: workTab))
        fixture.controllers.append(notesTab)
        try await Task.sleep(for: .milliseconds(120))

        let host = first.windowSessionID
        let hostControllers = fixture.coordinator.liveControllers
            .filter { $0.windowSessionID == host }
            .sorted { $0.tabSessionID.uuidString < $1.tabSessionID.uuidString }
        let hostWindowIDs = Set(try hostControllers.map { controller in
            ObjectIdentifier(try #require(controller.window))
        })
        let retainedGroup = try #require(notesTab.window?.tabGroup)

        func expectRetainedGroup() {
            #expect(Set(retainedGroup.windows.map(ObjectIdentifier.init)) == hostWindowIDs)
            #expect(hostControllers.allSatisfy { $0.window?.tabGroup === retainedGroup })
        }

        func expectWorkspaceProjection(_ selected: TerminalController, workspace: UUID) {
            let expected = fixture.coordinator.controllers(in: workspace).map(\.tabSessionID)
            #expect(selected.workspaceID == workspace)
            #expect(selected.tabControllers.map(\.tabSessionID) == expected)
        }

        expectRetainedGroup()
        expectWorkspaceProjection(notesTab, workspace: notes)

        let originalSurfaces = Dictionary(uniqueKeysWithValues: hostControllers.map {
            ($0.tabSessionID, Array($0.surfaceTree).map(ObjectIdentifier.init))
        })
        attachCalls = 0
        var warmSwitchMilliseconds: [Double] = []
        var active = notesTab
        for workspace in [personal, work, personal, notes, personal, work, personal, notes] {
            let start = ProcessInfo.processInfo.systemUptime
            active = try #require(fixture.coordinator.switchWorkspace(to: workspace, from: active))
            warmSwitchMilliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            expectRetainedGroup()
            expectWorkspaceProjection(active, workspace: workspace)
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(attachCalls == 0, "Warm vertical workspace switches must not reattach native tabs")
        for controller in hostControllers {
            let expected = try #require(originalSurfaces[controller.tabSessionID])
            #expect(Array(controller.surfaceTree).map(ObjectIdentifier.init) == expected)
        }
        let warmMean = warmSwitchMilliseconds.reduce(0, +) / Double(warmSwitchMilliseconds.count)
        let warmMax = warmSwitchMilliseconds.max() ?? 0
        print(String(
            format: "RETAINED_TABS_BENCHMARK tabs=40 cold_A_to_B_ms=%.3f cold_attach_calls=%d warm_mean_ms=%.3f warm_max_ms=%.3f warm_attach_calls=%d",
            coldSwitchMilliseconds, workAttachCalls, warmMean, warmMax, attachCalls
        ))
    }

    @Test func retainedVerticalGroupSplitsForHorizontalAndRejoins() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let personal = fixture.store.defaultID
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        let third = try fixture.tab(parent: second)
        try await Task.sleep(for: .milliseconds(100))
        let personalTabs = [first, second, third]
        let work = try #require(fixture.store.create(name: "Work layout", symbol: "briefcase", color: "blue"))
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: third))
        fixture.controllers.append(workTab)
        let notes = try #require(fixture.store.create(name: "Notes layout", symbol: "doc.text", color: "mint"))
        let notesTab = try #require(fixture.coordinator.switchWorkspace(to: notes, from: workTab))
        fixture.controllers.append(notesTab)
        _ = try #require(fixture.coordinator.switchWorkspace(to: personal, from: notesTab))

        let host = first.windowSessionID
        let hostControllers = fixture.coordinator.liveControllers.filter { $0.windowSessionID == host }
        let hostWindowIDs = Set(try hostControllers.map { controller in
            ObjectIdentifier(try #require(controller.window))
        })
        let personalWindowIDs = Set(try personalTabs.map { controller in
            ObjectIdentifier(try #require(controller.window))
        })
        let surfaceIDs = Dictionary(uniqueKeysWithValues: hostControllers.map {
            ($0.tabSessionID, Array($0.surfaceTree).map(ObjectIdentifier.init))
        })

        fixture.coordinator.requestTabLayout(.horizontal, from: first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(hostControllers.allSatisfy { $0.tabLayout == .horizontal })
        let horizontalPersonalGroup = try #require(first.window?.tabGroup)
        #expect(Set(horizontalPersonalGroup.windows.map(ObjectIdentifier.init)) == personalWindowIDs)
        #expect(workTab.window?.tabGroup !== horizontalPersonalGroup)
        #expect(notesTab.window?.tabGroup !== horizontalPersonalGroup)
        #expect(Set(horizontalPersonalGroup.windows.map(ObjectIdentifier.init)).isSubset(of: hostWindowIDs))

        fixture.coordinator.requestTabLayout(.vertical, from: first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(hostControllers.allSatisfy { $0.tabLayout == .vertical })
        let verticalGroup = try #require(first.window?.tabGroup)
        #expect(Set(verticalGroup.windows.map(ObjectIdentifier.init)) == hostWindowIDs)
        #expect(hostControllers.allSatisfy { $0.window?.tabGroup === verticalGroup })
        let firstSurfaces = try #require(surfaceIDs[first.tabSessionID])
        let workSurfaces = try #require(surfaceIDs[workTab.tabSessionID])
        let notesSurfaces = try #require(surfaceIDs[notesTab.tabSessionID])
        #expect(Array(first.surfaceTree).map(ObjectIdentifier.init) == firstSurfaces)
        #expect(Array(workTab.surfaceTree).map(ObjectIdentifier.init) == workSurfaces)
        #expect(Array(notesTab.surfaceTree).map(ObjectIdentifier.init) == notesSurfaces)
        #expect(fixture.coordinator.store.snapshot.windows?[host]?.currentWorkspace == personal)
    }

    @Test func failedHorizontalToVerticalAttachRollsBackLayoutAndWorkspaceGroups() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let personal = fixture.store.defaultID
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        let third = try fixture.tab(parent: second)
        try await Task.sleep(for: .milliseconds(100))

        let work = try #require(fixture.store.create(name: "Work rollback", symbol: "briefcase", color: "blue"))
        let workFirst = try #require(fixture.coordinator.switchWorkspace(to: work, from: third))
        fixture.controllers.append(workFirst)
        let workSecond = try fixture.tab(workspace: work, parent: workFirst)
        let notes = try #require(fixture.store.create(name: "Notes rollback", symbol: "doc.text", color: "mint"))
        let notesTab = try #require(fixture.coordinator.switchWorkspace(to: notes, from: workSecond))
        fixture.controllers.append(notesTab)
        _ = try #require(fixture.coordinator.switchWorkspace(to: personal, from: notesTab))

        let host = first.windowSessionID
        let personalTabs = [first, second, third]
        let workTabs = [workFirst, workSecond]
        let notesTabs = [notesTab]
        let hostTabs = personalTabs + workTabs + notesTabs
        let surfaces = Dictionary(uniqueKeysWithValues: hostTabs.map {
            ($0.tabSessionID, Array($0.surfaceTree).map(ObjectIdentifier.init))
        })
        fixture.coordinator.requestTabLayout(.horizontal, from: first)
        try await Task.sleep(for: .milliseconds(120))
        #expect(hostTabs.allSatisfy { $0.tabLayout == .horizontal })
        #expect(!fixture.coordinator.native.retainedVerticalHosts.contains(host))
        let stateBeforeFailure = fixture.coordinator.store.snapshot
        let nativeMembershipBefore = try Dictionary(uniqueKeysWithValues: hostTabs.map { controller in
            let window = try #require(controller.window)
            let members = window.tabGroup?.windows ?? [window]
            return (controller.tabSessionID, Set(members.map(ObjectIdentifier.init)))
        })

        let native = fixture.coordinator.native
        let originalAttach = native.attach
        var attachCalls = 0
        native.attach = { anchor, member, ordering in
            attachCalls += 1
            if attachCalls == 2 { return false }
            return originalAttach(anchor, member, ordering)
        }
        defer { native.attach = originalAttach }

        fixture.coordinator.requestTabLayout(.vertical, from: first)

        #expect(attachCalls >= 2)
        #expect(hostTabs.allSatisfy { $0.tabLayout == .horizontal })
        #expect(fixture.coordinator.store.snapshot.windows?[host]?.tabLayout ==
            Ghostty.Config.MacOSTabLayout.horizontal.rawValue)
        #expect(fixture.coordinator.store.snapshot == stateBeforeFailure)
        #expect(!native.retainedVerticalHosts.contains(host))
        let firstWindow = try #require(first.window)
        let activeGroupWindows = firstWindow.tabGroup?.windows ?? [firstWindow]
        #expect(Set(activeGroupWindows.map(ObjectIdentifier.init)) ==
            Set(try personalTabs.map { ObjectIdentifier(try #require($0.window)) }))
        for controller in hostTabs {
            let window = try #require(controller.window)
            let actual = window.tabGroup?.windows ?? [window]
            #expect(Set(actual.map(ObjectIdentifier.init)) ==
                (try #require(nativeMembershipBefore[controller.tabSessionID])))
        }
        for controller in hostTabs {
            #expect(Array(controller.surfaceTree).map(ObjectIdentifier.init) ==
                (try #require(surfaces[controller.tabSessionID])))
        }
    }
}
