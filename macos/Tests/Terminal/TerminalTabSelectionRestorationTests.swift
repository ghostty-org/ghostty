import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct TerminalTabSelectionRestorationTests {
    @Test func restoresSeventhTabByIdentityRegardlessOfCreationOrder() throws {
        let tabs = (0..<7).map { _ in UUID() }
        let state = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[6])], foreground: tabs[6]
        )
        let decoded = try JSONDecoder().decode(TerminalTabSelectionRestoration.Snapshot.self,
                                                from: JSONEncoder().encode(state))
        #expect(decoded.selection(for: Set(tabs.reversed())) == tabs[6])
        #expect(decoded.foreground == tabs[6])
        #expect(decoded.selection(for: Set(tabs.dropLast())) == nil)
        #expect(decoded.selection(for: [UUID()]) == nil)
    }

    @Test func quitCapturesSelectionBeforeTeardownAndCancellationUnfreezesIt() throws {
        let tabs = (0..<7).map { _ in UUID() }
        let seventh = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[6])], foreground: tabs[6]
        )
        let first = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: tabs, selected: tabs[0])], foreground: tabs[0]
        )
        var current = seventh
        let service = TerminalTabSelectionRestoration(captureSnapshot: { current })
        service.prepareToQuit()
        current = first // AppKit switches tabs during termination/confirmation.
        #expect(try encodedSnapshot(service) == seventh)
        service.cancelQuit()
        #expect(try encodedSnapshot(service) == first)
    }

    private func encodedSnapshot(_ service: TerminalTabSelectionRestoration) throws
        -> TerminalTabSelectionRestoration.Snapshot {
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encodedData(service))
        defer { decoder.finishDecoding() }
        let data = try #require(decoder.decodeObject(of: NSData.self,
            forKey: TerminalTabSelectionRestoration.codingKey) as Data?)
        return try JSONDecoder().decode(TerminalTabSelectionRestoration.Snapshot.self, from: data)
    }

    private func encodedData(_ service: TerminalTabSelectionRestoration) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        service.encode(into: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    @Test func independentWindowsRestoreTheirOwnSelectedTabs() {
        let first = [UUID(), UUID()]
        let second = [UUID(), UUID(), UUID()]
        let state = TerminalTabSelectionRestoration.Snapshot(groups: [
            .init(members: first, selected: first[1]),
            .init(members: second, selected: second[2]),
        ], foreground: second[2])
        #expect(state.selection(for: Set(first)) == first[1])
        #expect(state.selection(for: Set(second)) == second[2])
        #expect(state.selection(for: Set(first + second)) == nil)
    }

    @Test func invalidSelectedIdentityNeverSelectsAnUnrelatedTab() {
        let members = [UUID(), UUID()]
        let state = TerminalTabSelectionRestoration.Snapshot(
            groups: [.init(members: members, selected: UUID())], foreground: nil
        )
        #expect(state.selection(for: Set(members)) == nil)
    }

    @Test func retainedVerticalRestoreUsesLogicalSelectionsWithoutSelectingParkedTabs() async throws {
        let fixture = try TerminalWorkspaceRefactorTests.Fixture()
        defer { fixture.close() }

        let personal = fixture.store.defaultID
        let personalFirst = try fixture.tab()
        personalFirst.showWindow(nil)
        let personalSelected = try fixture.tab(parent: personalFirst)
        try await Task.sleep(for: .milliseconds(80))
        personalFirst.window?.isRestorable = false
        personalSelected.window?.isRestorable = true
        personalSelected.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(personalSelected)

        let work = try #require(fixture.store.create(name: "Restore Work", symbol: "briefcase", color: "blue"))
        let workFirst = try #require(fixture.coordinator.switchWorkspace(to: work, from: personalSelected))
        fixture.controllers.append(workFirst)
        let workSelected = try fixture.tab(workspace: work, parent: workFirst)
        try await Task.sleep(for: .milliseconds(80))
        workFirst.window?.isRestorable = true
        workSelected.window?.isRestorable = true
        workSelected.window?.makeKeyAndOrderFront(nil)
        fixture.coordinator.didActivate(workSelected)

        let group = try #require(workSelected.window?.tabGroup)
        #expect(personalFirst.window?.tabGroup === group)
        #expect(group.selectedWindow === workSelected.window)
        let controllers = [personalFirst, personalSelected, workFirst, workSelected]
        let snapshot = TerminalTabSelectionRestoration.capture(controllers, foreground: workSelected.window)
        #expect(snapshot.groups.count == 2)
        #expect(snapshot.selection(for: Set([personalSelected.tabSessionID])) == personalSelected.tabSessionID)
        #expect(!snapshot.groups.contains { $0.members.contains(personalFirst.tabSessionID) })
        #expect(snapshot.selection(for: Set([workFirst.tabSessionID, workSelected.tabSessionID])) ==
            workSelected.tabSessionID)
        #expect(snapshot.foreground == workSelected.tabSessionID)

        // A stale per-workspace record must not override the saved foreground.
        let restoredGroups = snapshot.groups.map { current in
            Set(current.members) == Set([workFirst.tabSessionID, workSelected.tabSessionID])
                ? TerminalTabSelectionRestoration.Group(members: current.members, selected: workFirst.tabSessionID)
                : current
        }
        let restoreSnapshot = TerminalTabSelectionRestoration.Snapshot(
            groups: restoredGroups,
            foreground: workSelected.tabSessionID
        )
        let archive = TerminalTabSelectionRestoration(
            captureSnapshot: { restoreSnapshot },
            finishRestoring: { fixture.coordinator.finishRestoring() }
        )
        let data = try encodedData(archive)
        var finishRestoringCalls = 0
        let restorer = TerminalTabSelectionRestoration(
            captureSnapshot: { restoreSnapshot },
            finishRestoring: {
                finishRestoringCalls += 1
                fixture.coordinator.finishRestoring()
            }
        )
        let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
        restorer.decode(from: decoder)
        decoder.finishDecoding()
        for controller in controllers { restorer.registerRestored(controller) }

        var selectedDuringRestore: [UUID] = []
        let observation = group.observe(\.selectedWindow, options: [.new]) { observedGroup, _ in
            MainActor.assumeIsolated {
                if let selected = observedGroup.selectedWindow?.windowController as? TerminalController {
                    selectedDuringRestore.append(selected.tabSessionID)
                }
            }
        }
        defer { observation.invalidate() }
        restorer.finishLaunching()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!selectedDuringRestore.contains(personalSelected.tabSessionID))
        #expect(selectedDuringRestore.last == workSelected.tabSessionID)
        #expect(finishRestoringCalls == 1)
        #expect(group.selectedWindow === workSelected.window)
        #expect(fixture.coordinator.store.snapshot.windows?[workSelected.windowSessionID]?.currentWorkspace == work)
        #expect(fixture.coordinator.store.group(window: workSelected.windowSessionID, workspace: personal)?.selected ==
            personalSelected.tabSessionID)
    }
}
