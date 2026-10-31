import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct TerminalWorkspaceManagementTests {
    @Test func nativeWorkspacePopupUsesOneOpaqueThemeForHeaderRowsAndFooter() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = fixture.store.create(name: "Work", symbol: "briefcase", color: "blue")
        let picker = TerminalWorkspacePickerController(model: fixture.model)
        let root = try #require(picker.view as? OMGNativeSurfaceView)
        let window = NSWindow(contentRect: .init(origin: .zero, size: picker.fittingSize(proposedWidth: nil)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.setContentSize(picker.fittingSize(proposedWidth: nil))
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        let themes: [(String, OMGNativeTheme)] = [
            ("dark", .init(background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.19, alpha: 1),
                           foreground: NSColor(white: 0.85, alpha: 1))),
            ("light", .init(background: NSColor(white: 0.96, alpha: 1), foreground: NSColor(white: 0.15, alpha: 1))),
        ]
        for (name, theme) in themes {
            root.applyTheme(theme)
            root.updateLayer()
            #expect(root.layer?.backgroundColor == theme.background.cgColor)
            if FileManager.default.fileExists(atPath: "/tmp/omg-unified-theme-preview") {
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.effectiveAppearance.performAsCurrentDrawingAppearance {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                }
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/omg-workspace-unified-\(name).png"))
            }
        }
    }

    @MainActor final class Fixture {
        let store = TerminalWorkspaceStore(fileURL: nil)
        let coordinator: TerminalWorkspaceCoordinator
        let controller: TerminalController
        var deferred: (() -> Void)?
        var reopenCount = 0
        lazy var model = TerminalWorkspacePickerModel(controller: controller, dismiss: { [weak self] in self?.deferred = $0 },
            reopen: { [weak self] in self?.reopenCount += 1 })

        init() throws {
            let app = try #require(NSApp.delegate as? AppDelegate).ghostty
            coordinator = TerminalWorkspaceCoordinator(store: store)
            coordinator.finishRestoring()
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/sleep 60"
            controller = TerminalController(app, withBaseConfig: config, workspaceCoordinator: coordinator)
            _ = controller.window
        }
        func close() { for controller in coordinator.liveControllers { controller.window?.close() } }
    }

    @Test func deferredRestoreDoesNotToggleOffUserEnteredFullscreen() async throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let fixture = try Fixture()
        let sessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: fixture.store)
        fixture.coordinator.useSessions(sessions)
        sessions.start(app)
        fixture.store.transaction {
            $0.windows?[fixture.controller.windowSessionID]?.fullscreen = true
            $0.windows?[fixture.controller.windowSessionID]?.fullscreenMode = .nonNative
        }
        sessions.capture()
        sessions.flush()
        fixture.coordinator.prepareToQuit()
        fixture.controller.window?.close()
        let store = TerminalWorkspaceStore(fileURL: nil)
        let restoredSessions = TerminalWorkspaceSessionStore(url: url, testing: true, workspaces: store)
        let runtime = TerminalWorkspaceCoordinator(store: store, sessions: restoredSessions)
        restoredSessions.prepare()
        restoredSessions.start(app)
        runtime.finishRestoring()
        defer { for controller in runtime.liveControllers { controller.window?.close() } }
        let controller = try #require(runtime.liveControllers.first)
        // User action wins before the queued automatic restore executes.
        controller.toggleFullscreen(mode: .nonNative)
        try #require(controller.fullscreenStyle?.isFullscreen == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.fullscreenStyle?.isFullscreen == true)
        controller.toggleFullscreen(mode: .nonNative)
    }

    @Test func fullscreenCompletionDoesNotReenterTheNativeNotification() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        var completed = false
        fixture.coordinator.native.transitionCompleted = { _ in completed = true }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(!completed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(completed)
    }

    @Test func incomingHeaderAndLayoutResolveBeforeTheWindowIsShown() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var inspected = false
        fixture.coordinator.native.show = { controller in
            inspected = true
            // Catalog commit deliberately follows native presentation.
            #expect(!fixture.store.workspaces.contains { $0.id == controller.workspaceID })
            #expect(fixture.coordinator.presentationWorkspace(controller.workspaceID)?.name == "Destination")
            #expect(controller.tabLayoutState.workspaceBindingID == controller.workspaceID)
            return controller.showWindowSafely(nil)
        }
        let result = fixture.coordinator.createWorkspace(name: "Destination", symbol: "house", color: "blue", from: fixture.controller)
        #expect(result != nil)
        #expect(inspected)
        #expect(fixture.coordinator.presentationWorkspace(UUID()) == nil)
    }

    @Test func currentWorkspaceCannotBeDeletedButPersonalCan() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let personal = fixture.store.defaultID
        let target = try #require(fixture.coordinator.createWorkspace(name: "Current", symbol: "house", color: "blue", from: fixture.controller))
        let model = TerminalWorkspacePickerModel(controller: target, dismiss: { $0() }, reopen: {})
        #expect(!model.canDelete(target.workspaceID))
        #expect(model.canDelete(personal))
        let before = fixture.store.snapshot
        #expect(!fixture.coordinator.deleteWorkspace(target.workspaceID, from: target))
        #expect(fixture.store.snapshot == before)
        model.beginDelete(personal)
        model.confirmDelete()
        #expect(!fixture.store.workspaces.contains { $0.id == personal })
        #expect(target.isAvailableForWorkspace)
        #expect(target.window?.isVisible == true)
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
        #expect(!model.canDelete(target.workspaceID))
    }

    @Test func closingIndependentPersonalThenSwitchingDoesNotReuseClosedWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let other = try #require(fixture.store.create(name: "Other window", symbol: "house", color: "blue"))
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let second = TerminalController(app, withBaseConfig: config, workspaceID: other, workspaceCoordinator: fixture.coordinator)
        second.window?.makeKeyAndOrderFront(nil)
        fixture.controller.closeWindowImmediately()
        let reopened = try #require(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: second))
        #expect(reopened !== fixture.controller)
        #expect(reopened.windowSessionID == second.windowSessionID)
        #expect(reopened.window?.isVisible == true)
        #expect(fixture.coordinator.switchWorkspace(to: other, from: reopened) === second)
        #expect(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: second) === reopened)
        #expect(reopened.window?.tabGroup?.windows.contains(reopened.window!) != false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }

    @Test func createCommitsCatalogAndTerminalTogetherAfterDismissal() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = fixture.model
        model.beginCreate()
        model.name = "Created together"
        model.save()
        #expect(model.isPerforming)
        #expect(fixture.store.workspaces.count == 1)
        fixture.deferred?()
        #expect(!model.isPerforming)
        let created = try #require(fixture.store.workspaces.first { $0.name == "Created together" })
        let controller = try #require(fixture.coordinator.controllers(in: created.id).first)
        #expect(controller.window?.isVisible == true)
        #expect(fixture.store.snapshot.windows?[fixture.controller.windowSessionID]?.currentWorkspace == created.id)
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }

    @Test func failedCreateRetainsFormAndDoesNotLeaveAnEmptyWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.coordinator.native.show = { _ in false }
        let before = fixture.store.snapshot
        let model = fixture.model
        model.beginCreate()
        model.name = "Retry me"
        model.symbol = "cloud"
        model.save()
        fixture.deferred?()
        #expect(fixture.store.snapshot == before)
        #expect(model.page == .create)
        #expect(model.name == "Retry me" && model.symbol == "cloud")
        #expect(model.error != nil)
        #expect(fixture.reopenCount == 1)
    }

    @Test func editAndDeleteUseTheExplicitRowInsteadOfTheActiveWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let other = try #require(fixture.store.create(name: "Other", symbol: "house", color: "blue"))
        let model = fixture.model
        model.beginEdit(other)
        model.selectedID = fixture.store.defaultID
        model.name = "Renamed other"
        model.save()
        #expect(fixture.store.workspace(other).name == "Renamed other")
        #expect(fixture.store.workspace(fixture.store.defaultID).name == "Personal")
        #expect(fixture.controller.workspaceID == fixture.store.defaultID)
        model.beginDelete(other)
        model.selectedID = fixture.store.defaultID
        model.confirmDelete()
        fixture.deferred?()
        #expect(!fixture.store.workspaces.contains { $0.id == other })
        #expect(fixture.controller.isAvailableForWorkspace)
    }

    @Test func moveListExcludesCurrentWorkspaceAndSearchDoesNotChangeOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let other = try #require(fixture.store.create(name: "Destination", symbol: "house", color: "blue"))
        let model = fixture.model
        model.beginMove()
        #expect(model.filtered.map(\.id) == [other])
        model.query = "missing"
        #expect(model.filtered.isEmpty)
        #expect(fixture.controller.workspaceID == fixture.store.defaultID)
        model.cancel()
        #expect(model.page == .switcher)
    }

    @Test func nativeTransitionOwnershipSurvivesLogicalIdentityChanges() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let host = fixture.controller.windowSessionID
        let unrelated = TerminalWorkspaceNativeAdapter()
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        #expect(fixture.coordinator.native.transitioningWindows.contains(host))
        #expect(unrelated.transitioningWindows.isEmpty)
        fixture.controller.windowSessionID = UUID()
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(!fixture.coordinator.native.transitioningWindows.contains(host))
        fixture.controller.windowSessionID = host
    }

    @Test func sharedWorkspacePersistenceIsDisabledForTestProcesses() {
        #expect(ProcessInfo.processInfo.environment["OMG_TESTING"] == "1")
        #expect(OMGApplicationEnvironment.isRunningTests)
    }

    @Test func managementPagesRenderAtBoundedSize() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for index in 1...8 { _ = fixture.store.create(name: "Project \(index)", symbol: "briefcase", color: "blue") }
        let model = fixture.model
        let picker = TerminalWorkspacePickerController(model: model)
        let host = picker.view
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.appearance = NSAppearance(named: .aqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(picker.fittingSize(proposedWidth: nil))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == 360)
            #expect(host.fittingSize.width <= host.bounds.width)
            #expect(host.fittingSize.height < 600)
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/omg-workspace-management-\(name).png"))
        }
        try await capture("switcher")
        model.beginCreate()
        model.name = "New project"
        try await capture("create")
        model.beginMove()
        try await capture("move")
        model.beginDelete(try #require(fixture.store.workspaces.last).id)
        try await capture("delete")
    }

    @Test func nativePickerUsesRecycledRowsAndKeepsTheWorkspaceTargetExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let destination = try #require(fixture.store.create(name: "Destination", symbol: "house", color: "blue"))
        let controller = TerminalWorkspacePickerController(model: fixture.model)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(50))

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }

        let table = try #require(find(NSTableView.self, in: controller.view).first)
        #expect(table.numberOfRows == 2)
        #expect(find(NSSearchField.self, in: controller.view).count == 1)

        let move = try #require(find(NSButton.self, in: controller.view).first {
            $0.accessibilityIdentifier() == "workspace.move"
        })
        move.performClick(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.filtered.map(\.id) == [destination])
        #expect(table.numberOfRows == 1)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        #expect(fixture.model.selectedID == destination)
        #expect(fixture.model.page == .move)
        #expect(fixture.model.currentID == fixture.controller.workspaceID)
        controller.view.layoutSubtreeIfNeeded()
        let destinationRow = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let open = try #require(find(NSButton.self, in: destinationRow).first {
            $0.accessibilityIdentifier() == "workspace.open.\(destination)"
        })
        open.performClick(nil)
        #expect(fixture.model.isPerforming)
        fixture.deferred?()
        #expect(fixture.coordinator.controllers(in: destination).count == 1)
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutSubtreeIfNeeded()
        let currentIndex = try #require(fixture.model.filtered.firstIndex { $0.id == destination })
        let currentRow = try #require(table.view(atColumn: 0, row: currentIndex, makeIfNecessary: true))
        let currentDelete = try #require(find(NSButton.self, in: currentRow).first {
            $0.accessibilityIdentifier() == "workspace.delete.\(destination)"
        })
        #expect(!currentDelete.isEnabled)

        fixture.model.beginDelete(TerminalWorkspace.defaultID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.model.page == .delete(TerminalWorkspace.defaultID))
        #expect(fixture.model.canDelete(TerminalWorkspace.defaultID))
        let confirm = try #require(find(NSButton.self, in: controller.view).first {
            $0.accessibilityIdentifier() == "workspace.confirm-delete"
        })
        #expect(confirm.isEnabled)
        confirm.performClick(nil)
        #expect(fixture.model.isPerforming)
        #expect(fixture.store.workspaces.contains(where: { $0.id == TerminalWorkspace.defaultID }))
        fixture.deferred?()
        #expect(!fixture.store.workspaces.contains(where: { $0.id == TerminalWorkspace.defaultID }))
    }

    @Test func nativeWorkspaceNameFieldLetsTheInputMethodFinishBeforeSubmitting() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let controller = TerminalWorkspacePickerController(model: fixture.model)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        fixture.model.beginCreate()
        try await Task.sleep(for: .milliseconds(50))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        let name = try #require(find(NSTextField.self, in: controller.view).first {
            $0.accessibilityIdentifier() == "workspace.name"
        })
        #expect(find(NSButton.self, in: controller.view).filter {
            $0.identifier?.rawValue.hasPrefix("symbol.") == true
        }.count == TerminalWorkspace.symbols.count)
        #expect(find(NSButton.self, in: controller.view).filter {
            $0.identifier?.rawValue.hasPrefix("color.") == true
        }.count == TerminalWorkspace.colors.count)

        #expect(window.makeFirstResponder(name))
        let editor = try #require(name.currentEditor() as? NSTextView)
        editor.setMarkedText("新", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!controller.control(name, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")))
        #expect(fixture.model.page == .create)
        editor.unmarkText()
        #expect(controller.control(name, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")))
        #expect(fixture.model.isPerforming)
        #expect(fixture.store.workspaces.count == 1)
        fixture.deferred?()
        #expect(fixture.store.workspaces.count == 2)
    }

    @Test func immediateExitCancelsDeferredBorderlessEntryGeometry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        window.setFrame(.init(x: 80, y: 100, width: 780, height: 520), display: false)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        let restored = window.frame
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.controller.fullscreenStyle?.isFullscreen == false)
        #expect(window.frame == restored)
    }

    @Test func nativeTabObservationSurvivesRepeatedBorderlessStyleChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let window = try #require(fixture.controller.window)
        let sibling = try #require(TerminalController.newTab(app, from: window, withBaseConfig: config))
        try await Task.sleep(for: .milliseconds(80))
        fixture.controller.selectVerticalTab(fixture.controller)
        let pane = try #require(fixture.controller.surfaceTree.first)
        for _ in 0..<8 {
            fixture.controller.toggleFullscreen(mode: .nonNative)
            try await Task.sleep(for: .milliseconds(60))
            #expect(!window.styleMask.contains(.titled))
            #expect(fixture.controller.surfaceTree.first === pane)
            fixture.controller.toggleFullscreen(mode: .nonNative)
            try await Task.sleep(for: .milliseconds(60))
            #expect(window.styleMask.contains(.titled))
            #expect(window.tabGroup?.windows.contains(sibling.window!) == true)
            #expect(window.isVisible)
        }
    }

    @Test func nonNativeFullscreenSupportsWorkspaceCreationAndReturn() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let sibling = try #require(TerminalController.newTab(app, from: fixture.controller.window!, withBaseConfig: config))
        try await Task.sleep(for: .milliseconds(80))
        fixture.controller.selectVerticalTab(fixture.controller)
        fixture.controller.window?.makeKeyAndOrderFront(nil)
        fixture.controller.toggleFullscreen(mode: .nonNative)
        try await Task.sleep(for: .milliseconds(100))
        try #require(fixture.controller.fullscreenStyle?.isFullscreen == true)
        #expect(fixture.controller.tabControllers.map(\.tabSessionID) == [fixture.controller.tabSessionID, sibling.tabSessionID])
        let target = try #require(fixture.coordinator.createWorkspace(name: "Borderless", symbol: "house", color: "blue", from: fixture.controller))
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.fullscreenStyle?.fullscreenMode == .nonNative)
        #expect(target.fullscreenStyle?.isFullscreen == true)
        #expect(target.window?.isVisible == true)
        #expect(fixture.store.snapshot.windows?[target.windowSessionID]?.fullscreenMode == .nonNative)
        for _ in 0..<5 {
            try #require(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: target) === fixture.controller)
            try #require(fixture.coordinator.switchWorkspace(to: target.workspaceID, from: fixture.controller) === target)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(target.window?.isVisible == true)
        #expect(fixture.controller.window?.isVisible == false)
        #expect(fixture.coordinator.switchWorkspace(to: fixture.store.defaultID, from: target) === fixture.controller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.controller.fullscreenStyle?.isFullscreen == true)
        #expect(fixture.controller.tabControllers.map(\.tabSessionID) == [fixture.controller.tabSessionID, sibling.tabSessionID])
        fixture.controller.selectVerticalTab(sibling)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sibling.fullscreenStyle?.isFullscreen == true)
        #expect(sibling.tabControllers.count == 2)
        sibling.toggleFullscreen(mode: .nonNative)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sibling.window?.tabGroup?.windows.count == 2)
        #expect(fixture.store.snapshot.validationErrors.isEmpty)
    }
}
