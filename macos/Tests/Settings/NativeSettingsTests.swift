import AppKit
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct NativeSettingsTests {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func themePickerPreservesDistinctOptionsWithTheSameDisplayName() {
        var selected: Int?
        let picker = SettingsPopup(titles: ["Follow OMG", "Shared name", "Shared name"], selected: 2) { selected = $0 }
        #expect(picker.numberOfItems == 3)
        #expect(picker.indexOfSelectedItem == 2)
        picker.sendAction(picker.action, to: picker.target)
        #expect(selected == 2)
    }

    @Test(.tags(.interactiveDesktop))
    func foregroundSettingsNavigationReceivesNativeMouseClicks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        let name = "NativeSettingsDesktop." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
        let controller = NativeSettingsController(settings: settings, initialSelection: .general, registry: registry, agents: agents)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OMG Native Settings Test"
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let previous = NSApp.activationPolicy()
        defer { window.close(); NSApp.setActivationPolicy(previous) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<600 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSApp.isActive && window.isKeyWindow, "Requires an unlocked foreground desktop")
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for tab in [OhMyGhosttySettingsTab.ssh, .appearance] {
                let row = try #require(OhMyGhosttySettingsTab.navigationOrder.firstIndex(of: tab))
                table.scrollRowToVisible(row)
                let rect = table.rect(ofRow: row)
                let point = table.convert(.init(x: rect.midX, y: rect.midY), to: nil)
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                }
                NSApp.postEvent(try event(.leftMouseUp), atStart: false)
                NSApp.sendEvent(try event(.leftMouseDown))
                try await Task.sleep(for: .milliseconds(150))
                #expect(controller.selection == tab)
                window.displayIfNeeded()
                try capture(controller.view, name: "\(tab.rawValue)-\(appearance.rawValue)-foreground")
            }
        }
    }

    @Test func nativeEditorShortcutsAndGitActionsPreserveSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .english
        settings.editorThemeName = "custom-fixture-theme"
        let controller = NativeSettingsController(settings: settings, initialSelection: .editor)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let strings = SettingsStrings(language: .english)
        func button(_ label: String) throws -> NSButton {
            try #require(descendants(controller.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == label })
        }
        try button(strings.editorThemeSection).performClick(nil)
        let theme = try #require(descendants(controller.view).compactMap { $0 as? SettingsPopup }
            .first { $0.accessibilityLabel() == strings.editorSyntaxThemeLabel })
        let opacity = try #require(descendants(controller.view).compactMap { $0 as? SettingsNumberField }.first)
        #expect(opacity.field.isEnabled)
        theme.selectItem(at: 0)
        theme.sendAction(theme.action, to: theme.target)
        try await Task.sleep(for: .milliseconds(30))
        #expect(settings.editorThemeName == nil)
        #expect(settings.editorSettings.followsOMG)
        #expect(!opacity.field.isEnabled && !opacity.stepper.isEnabled)
        theme.selectItem(at: theme.numberOfItems - 1)
        theme.sendAction(theme.action, to: theme.target)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!settings.editorSettings.followsOMG)
        #expect(opacity.field.isEnabled && opacity.stepper.isEnabled)
        controller.select(.editor)
        settings.editorFontSize = 25
        try button(strings.resetEditorButton).performClick(nil)
        #expect(settings.editorSettings.followsOMG && settings.editorFontSize == 13)

        controller.select(.keyboard)
        let recorder = try #require(descendants(controller.view).compactMap { $0 as? ShortcutRecorderButton }.first)
        let captured = OMGKeyboardShortcut.defaultInspectorPanel(slot: 2)
        recorder.onCapture?(captured)
        #expect(settings.quickInputShortcut == captured.storageValue)
        recorder.performClick(nil)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        recorder.keyDown(with: escape)
        #expect(recorder.title == captured.displayValue)
        let reset = try #require(recorder.superview?.subviews.compactMap { $0 as? SettingsActionButton }.first)
        reset.performClick(nil)
        #expect(settings.quickInputShortcut == OMGKeyboardShortcut.defaultQuickInput.storageValue)

        let first = GitCommitAIRoute(agent: .codex, model: "first")
        let second = GitCommitAIRoute(agent: .claude, model: "second")
        settings.gitCommitAIRoutes = [first, second]
        controller.select(.git)
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityIdentifier() == "git.commit-ai.routes" })
        let coordinator = try #require(table.delegate as? GitCommitAIRoutesTable.Coordinator)
        #expect(coordinator.move(first.id, by: 1))
        #expect(settings.gitCommitAIRoutes == [second, first])
        coordinator.remove(second.id)
        #expect(settings.gitCommitAIRoutes == [first])
        #expect(table.numberOfRows == 1)
    }

    @Test func nativePagesPreserveNavigationAndFitWithoutHostingViews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        settings.language = .simplifiedChinese
        let name = "NativeSettingsTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] }, inventory: { _ in .init() })
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
        let controller = NativeSettingsController(settings: settings, initialSelection: .general, registry: registry, agents: agents)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 900, height: 680))
        defer { window.close() }
        for tab in OhMyGhosttySettingsTab.allCases {
            controller.select(tab)
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutSubtreeIfNeeded()
            // AppKit itself uses _NSCoreHostingView for controls on newer macOS.
            let hosting = Set(descendants(controller.view).map { String(describing: type(of: $0)) }.filter { $0.contains("NSHostingView<") })
            #expect(hosting.isEmpty, "\(hosting)")
            let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
                .first { $0.accessibilityIdentifier() == "settings.navigation" })
            #expect(table.numberOfRows == OhMyGhosttySettingsTab.allCases.count)
            #expect(controller.selection == tab)
            for row in 0..<table.numberOfRows {
                let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let label = try #require(descendants(cell).compactMap { $0 as? NSTextField }.first)
                #expect(label.bounds.width > 20 && label.bounds.height > 10)
            }
            let form = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
            #expect(!form.rowTitles.isEmpty)
            #expect(form.stack.fittingSize.height > 50)
            for label in descendants(form.view).compactMap({ $0 as? NSTextField })
                where !label.isEditable && !label.stringValue.isEmpty && !label.isHiddenOrHasHiddenAncestor {
                #expect(label.bounds.height >= 12, "\(tab): readable label \(label.stringValue)")
            }
            for control in form.controls {
                if control.isHiddenOrHasHiddenAncestor { continue }
                let frame = control.convert(control.bounds, to: controller.view)
                #expect(frame.maxX > controller.view.bounds.maxX - 70, "\(tab): right-aligned control")
                #expect(frame.maxX <= controller.view.bounds.maxX, "\(tab): bounded control")
            }
            try capture(controller.view, name: tab.rawValue)
        }
        window.setContentSize(.init(width: 820, height: 540))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for tab in [OhMyGhosttySettingsTab.appearance, .editor, .keyboard, .ssh] {
                controller.select(tab)
                controller.view.layoutSubtreeIfNeeded()
                let form = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
                for control in form.controls where !control.isHiddenOrHasHiddenAncestor {
                    let frame = control.convert(control.bounds, to: controller.view)
                    #expect(frame.minX >= 238 && frame.maxX <= 820, "\(tab): minimum window width")
                }
                try capture(controller.view, name: "\(tab.rawValue)-\(appearance.rawValue)-minimum")
            }
        }
        controller.select(.general)
        let toggle = try #require(descendants(controller.view).compactMap { $0 as? SettingsSwitch }.first)
        let before = settings.quitWithoutConfirmation
        toggle.state = before ? .off : .on
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(settings.quitWithoutConfirmation == !before)
        controller.searchFor("剪贴板")
        #expect(controller.isShowing("search"))
        let result = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
        #expect(!result.rowTitles.isEmpty)
        let clipboard = try #require(SettingsSearchCatalog.entries(strings: .init(language: .simplifiedChinese)).first { $0.id == "core:clipboard" })
        controller.navigate(to: clipboard)
        let destination = try #require(controller.children.compactMap { $0 as? NativeSettingsForm }.first)
        #expect(destination.rowTitles.contains(CoreSetting.all.first { $0.group == .clipboard }!.title(.init(language: .simplifiedChinese))))
        controller.select(.editor)
        #expect(controller.isShowing("editor"))
    }

    @Test func legacyHostPreferencesRemainUnchangedWhenAddedAgain() throws {
        let name = "LegacyHostSettings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let connection = try GitSSHConnection(destination: "legacy-fixture")
        let record = RegisteredSSHHost(id: RegisteredSSHHost.id(for: connection), name: "Legacy",
                                       connection: connection, snapshot: .init(), capturedAt: .distantPast)
        let host = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        let data = try JSONSerialization.data(withJSONObject: ["hosts": [host], "automaticallyRegister": false, "excluded": []])
        defaults.set(data, forKey: "OMG.SSH.Registry.v1")
        let registry = SSHHostRegistry(defaults: defaults, live: { [] })
        #expect(registry.host(record.id)?.autoInstallRuntime == nil)
        #expect(registry.host(record.id)?.autoInstallHooks == nil)
        registry.addConfigured(connection)
        #expect(registry.host(record.id)?.name == "Legacy")
        #expect(registry.host(record.id)?.autoInstallRuntime == nil)
        #expect(registry.host(record.id)?.autoInstallHooks == nil)
    }

    @Test func registrationIsExplicitOfflineAndRefreshPreservesHostChoices() async throws {
        let name = "NativeSettingsHosts." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let connection = try GitSSHConnection(destination: "build-host")
        let registry = SSHHostRegistry(defaults: defaults, live: { [connection] }, inventory: { _ in .init() })
        registry.reconcile()
        #expect(registry.hosts.isEmpty)
        let id = registry.addConfigured(connection, endpoint: "user@build-host:22", fromConfiguration: true)
        #expect(registry.hosts.count == 1)
        #expect(registry.host(id)?.capturedAt == .distantPast)
        #expect(registry.host(id)?.autoInstallRuntime == true)
        #expect(registry.host(id)?.autoInstallHooks == false)
        registry.configure(id, name: "Build server", runtime: false, hooks: true)
        await registry.register(connection, endpoint: "user@build-host:22", targetID: id)
        #expect(registry.host(id)?.name == "Build server")
        #expect(registry.host(id)?.autoInstallRuntime == false)
        #expect(registry.host(id)?.autoInstallHooks == true)
        let restored = SSHHostRegistry(defaults: defaults, live: { [] })
        #expect(restored.host(id)?.name == "Build server")
        #expect(restored.host(id)?.autoInstallRuntime == false)
        restored.unregister(id)
        #expect(restored.hosts.isEmpty)
    }

    @Test func remoteHostAndAgentPagesKeepTargetAndBackNavigation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = OhMyGhosttySettings(fileURL: directory.appendingPathComponent("settings.json"))
        let name = "NativeSettingsRoutes." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = SSHHostRegistry(defaults: defaults, live: { [] })
        let id = registry.addConfigured(try GitSSHConnection(destination: "build-host"))
        let agents = AgentIntegrationManager(defaults: defaults, connectionTargets: { [] }, registry: registry)
        let controller = NativeSettingsController(settings: settings, initialSelection: .ssh, registry: registry, agents: agents)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(.init(width: 900, height: 680))
        defer { window.close() }
        controller.showHost(id)
        #expect(controller.isShowing("host:" + id))
        try capture(controller.view, name: "host-detail")
        controller.showAgents(target: id)
        #expect(controller.isShowing("agents:" + id))
        let back = try #require(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.back" })
        let others = try #require(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == controller.text("Other Agents", "其他 Agent") })
        others.performClick(nil)
        #expect(controller.isShowing("agents:" + id + ":all"))
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityIdentifier() == "settings.agents." + id })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.sendAction(table.action, to: table.target)
        #expect(controller.routeID.hasPrefix("agent:" + id + ":"))
        back.performClick(nil)
        #expect(controller.isShowing("agents:" + id + ":all"))
        back.performClick(nil)
        #expect(controller.isShowing("agents:" + id))
        back.performClick(nil)
        #expect(controller.isShowing("host:" + id))
        back.performClick(nil)
        #expect(controller.isShowing("ssh"))
        controller.select(.general)
        #expect(!controller.isShowing("agents:" + id))
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/omg-native-settings-\(name).png"))
    }
}
