import AppKit
import IOSurface
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceRetainedTabsTests {
    private struct RetainedTabProfile {
        let tabCount: Int
        let rounds: Int
        let isProfile: Bool

        static func consume() -> Self {
            let configURL = URL(fileURLWithPath: "/tmp/omg-workspace-switch-profile.json")
            guard let data = try? Data(contentsOf: configURL) else {
                return Self(tabCount: 40, rounds: 4, isProfile: false)
            }
            try? FileManager.default.removeItem(at: configURL)

            let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let requestedTabs = (values?["tabCount"] as? NSNumber)?.intValue ?? 40
            let requestedRounds = (values?["rounds"] as? NSNumber)?.intValue ?? 4
            return Self(
                tabCount: min(max(requestedTabs, 2), 60),
                rounds: min(max(requestedRounds, 1), 100),
                isProfile: true
            )
        }
    }

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

    @Test func retainedTabVerticalWorkspacesReuseHostNativeGroup() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let profile = RetainedTabProfile.consume()
        let personal = fixture.store.defaultID
        let first = try fixture.tab()
        first.showWindow(nil)
        var personalTabs = [first]
        for _ in 1..<profile.tabCount {
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

        let showBeforeNewTab = native.show
        let selectBeforeNewTab = native.selectRetained
        var newTabShowCalls = 0
        var newTabRetainedSelectionCalls = 0
        native.show = { controller in
            newTabShowCalls += 1
            return showBeforeNewTab(controller)
        }
        native.selectRetained = { controller in
            newTabRetainedSelectionCalls += 1
            return selectBeforeNewTab(controller)
        }
        defer {
            native.show = showBeforeNewTab
            native.selectRetained = selectBeforeNewTab
        }
        let notesTab = try #require(fixture.coordinator.switchWorkspace(to: notes, from: workTab))
        native.show = showBeforeNewTab
        native.selectRetained = selectBeforeNewTab
        fixture.controllers.append(notesTab)
        #expect(newTabShowCalls > 0, "A newly created retained tab must use the normal presentation path")
        #expect(newTabRetainedSelectionCalls == 0, "A newly attached window must not use retained selection")
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
        let originalShow = native.show
        let originalRetainedSelection = native.selectRetained
        var warmShowCalls = 0
        var warmRetainedSelectionCalls = 0
        native.show = { controller in
            warmShowCalls += 1
            return originalShow(controller)
        }
        native.selectRetained = { controller in
            warmRetainedSelectionCalls += 1
            return originalRetainedSelection(controller)
        }
        defer {
            native.show = originalShow
            native.selectRetained = originalRetainedSelection
        }
        var warmSwitchMilliseconds: [Double] = []
        var enterLargeMilliseconds: [Double] = []
        var leaveLargeMilliseconds: [Double] = []
        var active = notesTab
        var nativeGroupStable = true
        var surfacesStable = true

        if profile.isProfile {
            let readyURL = URL(fileURLWithPath: "/tmp/omg-workspace-profile-ready.json")
            try? FileManager.default.removeItem(at: readyURL)
            let readyData = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "tabCount": profile.tabCount,
                "rounds": profile.rounds,
            ])
            try readyData.write(to: readyURL, options: .atomic)
            print(
                "RETAINED_TABS_PROFILE_READY " +
                    "pid=\(ProcessInfo.processInfo.processIdentifier) tabs=\(profile.tabCount) rounds=\(profile.rounds)"
            )
        }

        for round in 0..<profile.rounds {
            let enterStart = ProcessInfo.processInfo.systemUptime
            active = try #require(fixture.coordinator.switchWorkspace(to: personal, from: active))
            let enterDuration = (ProcessInfo.processInfo.systemUptime - enterStart) * 1_000
            warmSwitchMilliseconds.append(enterDuration)
            enterLargeMilliseconds.append(enterDuration)
            expectRetainedGroup()
            expectWorkspaceProjection(active, workspace: personal)
            nativeGroupStable = nativeGroupStable &&
                Set(retainedGroup.windows.map(ObjectIdentifier.init)) == hostWindowIDs &&
                hostControllers.allSatisfy { $0.window?.tabGroup === retainedGroup }
            surfacesStable = surfacesStable && hostControllers.allSatisfy { controller in
                guard let expected = originalSurfaces[controller.tabSessionID] else { return false }
                return Array(controller.surfaceTree).map(ObjectIdentifier.init) == expected
            }
            try await Task.sleep(for: .milliseconds(20))

            let leaveWorkspace = round.isMultiple(of: 2) ? work : notes
            let leaveStart = ProcessInfo.processInfo.systemUptime
            active = try #require(fixture.coordinator.switchWorkspace(to: leaveWorkspace, from: active))
            let leaveDuration = (ProcessInfo.processInfo.systemUptime - leaveStart) * 1_000
            warmSwitchMilliseconds.append(leaveDuration)
            leaveLargeMilliseconds.append(leaveDuration)
            expectRetainedGroup()
            expectWorkspaceProjection(active, workspace: leaveWorkspace)
            nativeGroupStable = nativeGroupStable &&
                Set(retainedGroup.windows.map(ObjectIdentifier.init)) == hostWindowIDs &&
                hostControllers.allSatisfy { $0.window?.tabGroup === retainedGroup }
            surfacesStable = surfacesStable && hostControllers.allSatisfy { controller in
                guard let expected = originalSurfaces[controller.tabSessionID] else { return false }
                return Array(controller.surfaceTree).map(ObjectIdentifier.init) == expected
            }
            try await Task.sleep(for: .milliseconds(20))
            if profile.isProfile {
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        #expect(attachCalls == 0, "Warm vertical workspace switches must not reattach native tabs")
        #expect(warmShowCalls == 0, "Warm retained switches must not rerun window-controller positioning")
        #expect(warmRetainedSelectionCalls == warmSwitchMilliseconds.count)
        #expect(nativeGroupStable, "Warm switches must keep the retained native group membership stable")
        #expect(surfacesStable, "Warm switches must preserve each tab's surfaces")

        func mean(_ samples: [Double]) -> Double {
            samples.reduce(0, +) / Double(samples.count)
        }

        func percentile(_ samples: [Double], _ fraction: Double) -> Double {
            let sorted = samples.sorted()
            let index = max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)
            return sorted[index]
        }

        let warmMax = warmSwitchMilliseconds.max() ?? 0
        let totalSurfaceCount = originalSurfaces.values.reduce(0) { $0 + $1.count }
        print(String(
            format: "RETAINED_TABS_BENCHMARK pid=%d tabs=%d rounds=%d switches=%d " +
                "cold_to_work_ms=%.3f cold_attach_calls=%d warm_p50_ms=%.3f warm_p95_ms=%.3f " +
                "warm_max_ms=%.3f enter_large_mean_ms=%.3f leave_large_mean_ms=%.3f " +
                "warm_attach_calls=%d warm_show_calls=%d warm_retained_select_calls=%d " +
                "surfaces=%d surfaces_stable=%@ native_group_members=%d native_group_stable=%@",
            ProcessInfo.processInfo.processIdentifier,
            profile.tabCount,
            profile.rounds,
            warmSwitchMilliseconds.count,
            coldSwitchMilliseconds,
            workAttachCalls,
            percentile(warmSwitchMilliseconds, 0.50),
            percentile(warmSwitchMilliseconds, 0.95),
            warmMax,
            mean(enterLargeMilliseconds),
            mean(leaveLargeMilliseconds),
            attachCalls,
            warmShowCalls,
            warmRetainedSelectionCalls,
            totalSurfaceCount,
            surfacesStable ? "true" : "false",
            retainedGroup.windows.count,
            nativeGroupStable ? "true" : "false"
        ))
    }

    @Test func failedRetainedSelectionRollsBackWithoutUsingTheFastPathAgain() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        let work = try #require(fixture.store.create(name: "Warm rollback", symbol: "briefcase", color: "blue"))
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: second))
        fixture.controllers.append(workTab)
        try await Task.sleep(for: .milliseconds(100))

        let native = fixture.coordinator.native
        let originalRetainedSelection = native.selectRetained
        var retainedSelectionCalls = 0
        native.selectRetained = { _ in
            retainedSelectionCalls += 1
            return false
        }
        defer { native.selectRetained = originalRetainedSelection }

        #expect(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: workTab) == nil)
        #expect(retainedSelectionCalls == 1)
        #expect(fixture.store.snapshot.windows?[first.windowSessionID]?.currentWorkspace == work)
        let group = try #require(workTab.window?.tabGroup)
        let expectedWindowIDs = Set(try [first, second, workTab].map {
            ObjectIdentifier(try #require($0.window))
        })
        #expect(Set(group.windows.map(ObjectIdentifier.init)) == expectedWindowIDs)
        #expect(group.selectedWindow === workTab.window)
    }

    @Test func warmRetainedSelectionKeepsCurrentFrameAndNativeSelection() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let work = try #require(fixture.store.create(name: "Warm frame", symbol: "briefcase", color: "blue"))
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: first))
        fixture.controllers.append(workTab)
        try await Task.sleep(for: .milliseconds(80))

        let firstWindow = try #require(first.window)
        let workWindow = try #require(workTab.window)
        let group = try #require(workWindow.tabGroup)
        let visibleFrame = try #require(workWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        let expectedFrame = NSRect(
            x: visibleFrame.minX + 31,
            y: visibleFrame.minY + 43,
            width: min(920, visibleFrame.width - 62),
            height: min(610, visibleFrame.height - 86)
        )
        workWindow.setFrame(expectedFrame, display: false)

        let originalShow = fixture.coordinator.native.show
        var showCalls = 0
        fixture.coordinator.native.show = { controller in
            showCalls += 1
            return originalShow(controller)
        }
        defer { fixture.coordinator.native.show = originalShow }

        let returned = try #require(fixture.coordinator.switchWorkspace(to: first.workspaceID, from: workTab))
        try await Task.sleep(for: .milliseconds(40))
        #expect(returned === first)
        #expect(firstWindow.frame == expectedFrame)
        #expect(group.selectedWindow === firstWindow)
        if NSApp.isActive { #expect(firstWindow.isKeyWindow) }

        let restored = try #require(fixture.coordinator.switchWorkspace(to: work, from: first))
        try await Task.sleep(for: .milliseconds(40))
        #expect(restored === workTab)
        #expect(workWindow.frame == expectedFrame)
        #expect(group.selectedWindow === workWindow)
        #expect(showCalls == 0)
        if NSApp.isActive { #expect(workWindow.isKeyWindow) }
    }

    @Test func workspaceReturnPreparesOnlyTheSelectedTabsGeometry() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }
        let first = try fixture.tab()
        first.showWindow(nil)
        let second = try fixture.tab(parent: first)
        first.selectVerticalTab(first)
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        let secondSurface = try #require(second.surfaceTree.first)
        let work = try #require(fixture.store.create(name: "Geometry", symbol: "house", color: "blue"))
        let workTab = try #require(fixture.coordinator.switchWorkspace(to: work, from: first))
        fixture.controllers.append(workTab)
        let workWindow = try #require(workTab.window)
        var enlarged = workWindow.frame
        enlarged.size.width += 160
        enlarged.size.height += 100
        workWindow.setFrame(enlarged, display: false)
        workWindow.contentView?.layoutSubtreeIfNeeded()
        let parkedFrame = secondWindow.frame
        try #require(parkedFrame != workWindow.frame)
        let surfaceID = ObjectIdentifier(secondSurface)

        let returned = try #require(fixture.coordinator.switchWorkspace(to: first.workspaceID, from: workTab))
        #expect(returned === first)
        #expect(firstWindow.frame == workWindow.frame)
        #expect(secondWindow.frame == parkedFrame, "A workspace return must not resize every inactive tab")
        #expect(ObjectIdentifier(try #require(second.surfaceTree.first)) == surfaceID)

        first.selectVerticalTab(second)
        try await Task.sleep(for: .milliseconds(50))
        #expect(secondWindow.frame == firstWindow.frame)
        #expect(secondWindow.tabGroup?.selectedWindow === secondWindow)
        let layer = try #require(secondSurface.layer)
        let image = try #require(layer.contents as? IOSurface)
        #expect(image.width == Int((layer.bounds.width * layer.contentsScale).rounded(.down)))
        #expect(image.height == Int((layer.bounds.height * layer.contentsScale).rounded(.down)))
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
