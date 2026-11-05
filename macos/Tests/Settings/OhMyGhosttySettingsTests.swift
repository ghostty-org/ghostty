import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct OhMyGhosttySettingsTests {
    @Test func developmentChannelSeedsButDoesNotShareStableSettings() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stable = OMGApplicationEnvironment.settingsFileURL(
            homeURL: home,
            development: false
        )
        let development = OMGApplicationEnvironment.settingsFileURL(
            homeURL: home,
            development: true
        )
        #expect(stable.path.contains("/.config/oh-my-ghostty/"))
        #expect(development.path.contains("/.config/oh-my-ghostty-dev/"))
        try FileManager.default.createDirectory(
            at: stable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"tabs.sidebarWidth":280}"#.write(
            to: stable,
            atomically: true,
            encoding: .utf8
        )

        OhMyGhosttySettings.seedDevelopmentSettingsIfNeeded(
            homeURL: home,
            development: true
        )
        #expect(try String(contentsOf: development, encoding: .utf8).contains("280"))
        try #"{"tabs.sidebarWidth":320}"#.write(
            to: development,
            atomically: true,
            encoding: .utf8
        )
        OhMyGhosttySettings.seedDevelopmentSettingsIfNeeded(
            homeURL: home,
            development: true
        )
        #expect(try String(contentsOf: development, encoding: .utf8).contains("320"))
        #expect(try String(contentsOf: stable, encoding: .utf8).contains("280"))
    }

    @Test func applicationSupportIsSeparatedByChannel() {
        #expect(OMGApplicationEnvironment.channel(development: false) == "release")
        #expect(OMGApplicationEnvironment.channel(development: true) == "debug")

        let base = URL(fileURLWithPath: "/tmp/omg-channel-test", isDirectory: true)
        #expect(OMGApplicationEnvironment.applicationSupportURL(
            baseURL: base,
            development: false
        ).lastPathComponent == "OMG")
        #expect(OMGApplicationEnvironment.applicationSupportURL(
            baseURL: base,
            development: true
        ).lastPathComponent == "OMG Dev")
    }

    @Test func terminalResizeRenderingDefaultsToOnRelease() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.terminalResizeRendering == .onRelease)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "terminal.resizeRendering"
        }
        #expect(descriptor?.defaultValue == "onRelease")
    }

    @Test func gitAutoFetchIntervalDefaultsToFiveMinutesAndPersists() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.gitAutoFetchInterval == 5)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "git.autoFetchInterval"
        }
        #expect(descriptor?.defaultValue == "5")
        #expect(descriptor?.category == "general")

        settings.gitAutoFetchInterval = 10
        #expect(settings.gitAutoFetchInterval == 10)
        let disk = OhMyGhosttySettings(fileURL: url)
        #expect(disk.gitAutoFetchInterval == 10)
    }

    @Test func quickInputHistorySettingsDefaultClampAndRoundTrip() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.quickInputHistoryScope == .tab)
        #expect(settings.quickInputHistoryInsertionMode == .append)
        #expect(settings.quickInputHistoryRetentionDays == 7)
        #expect(settings.quickInputHistoryKeepAfterQuit)
        settings.quickInputHistoryScope = .tab
        settings.quickInputHistoryRetentionDays = 30
        settings.quickInputHistoryKeepAfterQuit = false
        settings.quickInputHistoryInsertionMode = .replace
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.quickInputHistoryScope == .tab)
        #expect(restored.quickInputHistoryRetentionDays == 30)
        #expect(!restored.quickInputHistoryKeepAfterQuit)
        #expect(restored.quickInputHistoryInsertionMode == .replace)
        settings.quickInputHistoryScope = .pane
        #expect(OhMyGhosttySettings(fileURL: url).quickInputHistoryScope == .pane)
        settings.quickInputHistoryRetentionDays = 0
        #expect(settings.quickInputHistoryRetentionDays == 1)
        settings.quickInputHistoryRetentionDays = 400
        #expect(settings.quickInputHistoryRetentionDays == 365)
        settings.quickInputHistoryRetentionDays = 3.4
        #expect(settings.quickInputHistoryRetentionDays == 3)
        settings.quickInputHistoryRetentionDays = .nan
        #expect(settings.quickInputHistoryRetentionDays == 7)
        settings.quickInputHistoryScope = .global
        #expect(OhMyGhosttySettings(fileURL: url).quickInputHistoryScope == .global)
        let english = SettingsStrings(language: .english)
        let chinese = SettingsStrings(language: .simplifiedChinese)
        #expect(english.quickInputHistoryScopeName(.tab) == "Current Tab")
        #expect(chinese.quickInputHistoryScopeName(.tab) == "当前 Tab")
        #expect(english.quickInputHistoryRetentionValue(7) == "7 days")
        #expect(chinese.quickInputHistoryRetentionValue(7) == "7 天")
    }

    @Test func quickInputControlJNewlineDefaultsOffAndPersists() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.quickInputControlJNewline)
        settings.quickInputControlJNewline = true
        #expect(OhMyGhosttySettings(fileURL: url).quickInputControlJNewline)
    }

    @Test func typedSettingsRoundTripThroughHumanReadableFile() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        settings.tabLayout = .vertical
        settings.defaultSidebarWidth = 300
        settings.sidebarVisible = false
        settings.groupingMode = .project
        settings.orderingMode = .manual
        settings.tabPathDisplay = .folderName
        settings.notifyTaskComplete = false
        settings.openQuickInputOnAgentStart = true
        settings.openQuickInputOnAgentComplete = true
        settings.quickInputShortcut = "control+option+q"
        settings.inspectorPanel1Shortcut = "option+command+1"
        settings.inspectorPanel2Shortcut = "option+command+2"
        settings.inspectorPanel3Shortcut = "option+command+3"
        settings.inspectorPanel4Shortcut = "option+command+4"
        settings.quickInputHeight = 318
        settings.terminalResizeRendering = .onRelease
        settings.editorKeymapPreset = .vscode
        settings.editorBackgroundMode = .system
        settings.editorSyntaxTheme = .dracula
        settings.editorFontFamily = .sfMono
        settings.editorFontSize = 15.5
        settings.editorTabWidth = 2
        settings.editorWordWrap = false
        settings.startupMode = .newTerminal
        settings.quitWithoutConfirmation = true

        let data = try Data(contentsOf: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["tabs.layout"] as? String == "vertical")
        #expect((object["tabs.sidebarWidth"] as? NSNumber)?.doubleValue == 300)
        #expect(object["tabs.sidebarVisible"] as? Bool == false)
        #expect(object["tabs.grouping"] as? String == "project")
        #expect(object["tabs.ordering"] as? String == "manual")
        #expect(object["tabs.pathDisplay"] as? String == "folderName")
        #expect(object["notifications.taskComplete"] as? Bool == false)
        #expect(object["agents.openQuickInputOnStart"] as? Bool == true)
        #expect(object["agents.openQuickInputOnComplete"] as? Bool == true)
        #expect(object["keyboard.quickInput"] as? String == "control+option+q")
        #expect(object["keyboard.inspectorPanel1"] as? String == "option+command+1")
        #expect(object["keyboard.inspectorPanel2"] as? String == "option+command+2")
        #expect(object["keyboard.inspectorPanel3"] as? String == "option+command+3")
        #expect(object["keyboard.inspectorPanel4"] as? String == "option+command+4")
        #expect((object["keyboard.quickInputHeight"] as? NSNumber)?.doubleValue == 318)
        #expect(object["terminal.resizeRendering"] as? String == "onRelease")
        #expect(object["editor.keymapPreset"] as? String == "vscode")
        #expect(object["editor.backgroundMode"] as? String == "system")
        #expect(object["editor.syntaxTheme"] as? String == "dracula")
        #expect(object["editor.fontFamily"] as? String == "sfMono")
        #expect((object["editor.fontSize"] as? NSNumber)?.doubleValue == 15.5)
        #expect((object["editor.tabWidth"] as? NSNumber)?.doubleValue == 2)
        #expect(object["editor.wordWrap"] as? Bool == false)
        #expect(object["sessions.startupMode"] as? String == "newTerminal")
        #expect(object["general.quitWithoutConfirmation"] as? Bool == true)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.tabLayout == .vertical)
        #expect(restored.defaultSidebarWidth == 300)
        #expect(!restored.sidebarVisible)
        #expect(restored.groupingMode == .project)
        #expect(restored.orderingMode == .manual)
        #expect(restored.tabPathDisplay == .folderName)
        #expect(!restored.notifyTaskComplete)
        #expect(restored.openQuickInputOnAgentStart)
        #expect(restored.openQuickInputOnAgentComplete)
        #expect(restored.quickInputShortcut == "control+option+q")
        #expect(restored.inspectorPanel1Shortcut == "option+command+1")
        #expect(restored.inspectorPanel2Shortcut == "option+command+2")
        #expect(restored.inspectorPanel3Shortcut == "option+command+3")
        #expect(restored.inspectorPanel4Shortcut == "option+command+4")
        #expect(restored.inspectorPanelShortcut(slot: 1) == "option+command+1")
        #expect(restored.inspectorPanelShortcut(slot: 2) == "option+command+2")
        #expect(restored.inspectorPanelShortcut(slot: 3) == "option+command+3")
        #expect(restored.inspectorPanelShortcut(slot: 4) == "option+command+4")
        #expect(restored.quickInputHeight == 318)
        #expect(restored.terminalResizeRendering == .onRelease)
        #expect(restored.editorSettings.keymapPreset == .vscode)
        #expect(restored.editorSettings.backgroundMode == .system)
        #expect(restored.editorSettings.syntaxTheme == .dracula)
        #expect(restored.editorSettings.fontFamily == .sfMono)
        #expect(restored.editorSettings.fontSize == 15.5)
        #expect(restored.editorSettings.tabWidth == 2)
        #expect(!restored.editorSettings.wordWrap)
        #expect(restored.startupMode == .newTerminal)
        #expect(restored.quitWithoutConfirmation)
    }

    @Test func legacyRestoreBooleanMigratesWithoutChangingTheEffectiveMode() throws {
        for (legacy, expected) in [(false, OMGStartupMode.newTerminal),
                                   (true, OMGStartupMode.restoreSessions)] {
            let (_, url) = temporarySettings()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try Data("{\"sessions.restoreOnLaunch\":\(legacy)}".utf8).write(to: url)
            let settings = OhMyGhosttySettings(fileURL: url)
            #expect(settings.startupMode == expected)
            let object = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["sessions.startupMode"] as? String == expected.rawValue)
            #expect(object["sessions.restoreOnLaunch"] == nil)
        }
    }

    @Test func newStartupModeWinsOverLegacyBooleanDuringMigration() throws {
        let (_, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data("{\"sessions.startupMode\":\"restoreTabs\",\"sessions.restoreOnLaunch\":false}".utf8)
            .write(to: url)
        let settings = OhMyGhosttySettings(fileURL: url)
        #expect(settings.startupMode == .restoreTabs)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["sessions.restoreOnLaunch"] == nil)
    }

    @Test func allStartupModesPersistAndInvalidValueFailsSafe() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for mode in OMGStartupMode.allCases {
            settings.startupMode = mode
            #expect(OhMyGhosttySettings(fileURL: url).startupMode == mode)
        }
        try Data("{\"sessions.startupMode\":\"bad\"}".utf8).write(to: url)
        settings.reloadFromDisk()
        #expect(settings.startupMode == .restoreSessions)
        #expect(!OMGStartupMode.newTerminal.restoresTabs)
        #expect(OMGStartupMode.restoreTabs.restoresTabs)
        #expect(!OMGStartupMode.restoreTabs.restoresSessions)
        #expect(OMGStartupMode.restoreSessions.restoresSessions)
    }

    @Test func legacySmoothResizeBooleanMigratesToRenderingMode() throws {
        let (_, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"terminal.smoothResize\":false}".utf8).write(to: url)

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.terminalResizeRendering == .onRelease)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["terminal.resizeRendering"] as? String == "onRelease")
        #expect(object["terminal.smoothResize"] == nil)
    }

    @Test func externalEditReloadsTheSameRuntimeModel() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let edited: [String: Any] = [
            "tabs.layout": "horizontal",
            "tabs.sidebarWidth": 280,
            "tabs.grouping": "date",
            "tabs.ordering": "recentlyUsed",
            "tabs.pathDisplay": "folderName",
        ]
        let data = try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)

        settings.reloadFromDisk()

        #expect(settings.tabLayout == .horizontal)
        #expect(settings.defaultSidebarWidth == 280)
        #expect(settings.groupingMode == .date)
        #expect(settings.orderingMode == .recentlyUsed)
        #expect(settings.tabPathDisplay == .folderName)
    }

    @Test func ghosttyConfigIsOnlyTheUnsetLayoutFallback() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        settings.configureGhosttyFallback(tabLayout: .horizontal)
        #expect(settings.tabLayout == .horizontal)
        settings.tabLayout = .vertical
        settings.configureGhosttyFallback(tabLayout: .horizontal)
        #expect(settings.tabLayout == .vertical)
    }

    @Test func appearanceResolutionPreservesGhosttyBaselineAndTracksSource() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ghosttyURL = url.deletingLastPathComponent().appendingPathComponent("ghostty.conf")
        try """
        font-size = 15
        background-opacity = 0.7
        background-blur = 12
        cursor-style = bar
        window-theme = dark
        """.write(to: ghosttyURL, atomically: true, encoding: .utf8)
        let config = Ghostty.Config(at: ghosttyURL.path)

        var appearance = settings.effectiveAppearance(using: config)
        #expect(appearance.fontSize.effectiveValue == 15)
        #expect(appearance.fontSize.source == .ghosttyConfig)
        #expect(appearance.backgroundOpacity.effectiveValue == 0.7)
        #expect(appearance.cursorStyle.effectiveValue == "bar")

        settings.fontSizeOverride = 18
        settings.backgroundOpacityOverride = 0.45
        settings.cursorStyleOverride = .underline
        appearance = settings.effectiveAppearance(using: config)

        #expect(appearance.fontSize.effectiveValue == 18)
        #expect(appearance.fontSize.inheritedValue == 15)
        #expect(appearance.fontSize.source == .ohMyGhosttyOverride)
        #expect(appearance.backgroundOpacity.effectiveValue == 0.45)
        #expect(appearance.cursorStyle.effectiveValue == "underline")
    }

    @Test func appearanceOverlayIsGeneratedAndResetWithoutEditingGhosttyConfig() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let overlayURL = url.deletingLastPathComponent().appendingPathComponent("appearance.ghostty")

        settings.windowThemeOverride = .system
        settings.lightThemeOverride = "Builtin Light"
        settings.darkThemeOverride = "Builtin Dark"
        settings.fontFamilyOverride = "Berkeley Mono"
        settings.backgroundOpacityOverride = 0.6
        settings.backgroundBlurOverride = .enabled

        let overlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(overlay.contains("window-theme = system"))
        #expect(overlay.contains("theme = light:Builtin Light,dark:Builtin Dark"))
        #expect(overlay.contains("font-family = Berkeley Mono"))
        #expect(overlay.contains("background-opacity = 0.6"))
        #expect(overlay.contains("background-blur = true"))

        settings.resetAppearance()
        let resetOverlay = try String(contentsOf: overlayURL, encoding: .utf8)
        #expect(!resetOverlay.contains("window-theme ="))
        #expect(!resetOverlay.contains("background-opacity ="))
        #expect(settings.windowThemeOverride == nil)
        #expect(settings.backgroundOpacityOverride == nil)
    }

    @Test func settingsWindowTracksExplicitAndSystemAppearance() async throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = OhMyGhosttySettingsWindowController(settings: settings)
        let window = try #require(controller.window)

        settings.windowThemeOverride = .dark
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance?.name == .darkAqua)

        settings.windowThemeOverride = .light
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance?.name == .aqua)

        settings.windowThemeOverride = .system
        try await Task.sleep(for: .milliseconds(20))
        #expect(window.appearance == nil)
    }

    @Test func themeCatalogCombinesBundledAndUserThemes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources/ghostty/themes")
        let home = root.appendingPathComponent("Home")
        let userThemes = home.appendingPathComponent(".config/ghostty/themes")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userThemes, withIntermediateDirectories: true)
        try "background = 000000".write(
            to: resources.appendingPathComponent("Bundled"),
            atomically: true,
            encoding: .utf8
        )
        try "background = ffffff".write(
            to: userThemes.appendingPathComponent("Custom"),
            atomically: true,
            encoding: .utf8
        )

        let themes = GhosttyThemeCatalog.availableThemes(
            resourceURL: root.appendingPathComponent("Resources"),
            homeURL: home
        )
        #expect(themes == ["Bundled", "Custom"])
    }

    @Test func schemaDescriptorsAreUniqueAndMachineReadable() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let descriptors = OhMyGhosttySettings.descriptors

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(descriptors.contains { $0.id == "tabs.layout" })
        #expect(descriptors.contains { $0.id == "tabs.ordering" })
        #expect(descriptors.contains { $0.id == "tabs.pathDisplay" })
        #expect(descriptors.contains { $0.id == "tabs.sidebarVisible" })
        #expect(descriptors.contains { $0.id == "agents.historyLimit" })
        #expect(descriptors.contains { $0.id == "agents.statusHooks" })
        #expect(descriptors.contains { $0.id == "agents.openQuickInputOnStart" })
        #expect(descriptors.contains { $0.id == "agents.openQuickInputOnComplete" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInput" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHeight" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryScope" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryInsertionMode" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryRetentionDays" })
        #expect(descriptors.contains { $0.id == "keyboard.quickInputHistoryKeepAfterQuit" })
        #expect(descriptors.contains { $0.id == "terminal.resizeRendering" })
        #expect(descriptors.contains { $0.id == "editor.keymapPreset" })
        #expect(descriptors.contains { $0.id == "editor.backgroundMode" })
        #expect(descriptors.contains { $0.id == "editor.fontSize" })
        #expect(descriptors.contains { $0.id == "editor.tabWidth" })
        #expect(descriptors.contains { $0.id == "editor.wordWrap" })
        #expect(descriptors.contains { $0.id == "sessions.startupMode" })
        #expect(descriptors.contains { $0.id == "general.language" })
        #expect(descriptors.contains { $0.id == "general.quitWithoutConfirmation" })
        #expect(descriptors.contains { $0.id == "appearance.backgroundOpacity" })
        #expect(descriptors.contains { $0.id == "appearance.cursorStyle" })
        let schema = try settings.schemaData()
        #expect(!schema.isEmpty)
    }

    @Test func quitConfirmationDefaultTracksApplicationChannel() {
        #expect(!OMGApplicationEnvironment.quitWithoutConfirmationDefault(
            development: false
        ))
        #expect(OMGApplicationEnvironment.quitWithoutConfirmationDefault(
            development: true
        ))
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let expected = OMGApplicationEnvironment.quitWithoutConfirmationDefault()
        #expect(settings.quitWithoutConfirmation == expected)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "general.quitWithoutConfirmation"
        }
        #expect(descriptor?.defaultValue == String(expected))
    }

    @Test func quickInputOnAgentStartDefaultsOff() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.openQuickInputOnAgentStart)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "agents.openQuickInputOnStart"
        }
        #expect(descriptor?.defaultValue == "false")
    }

    @Test func quickInputOnAgentCompleteDefaultsOff() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!settings.openQuickInputOnAgentComplete)
        let descriptor = OhMyGhosttySettings.descriptors.first {
            $0.id == "agents.openQuickInputOnComplete"
        }
        #expect(descriptor?.defaultValue == "false")
    }

    @Test func editorOpenDestinationsPersistIndependently() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.editorFileOpenDestination == .currentPane)
        #expect(settings.editorDirectoryOpenDestination == .currentPane)
        for destination in EditorOpenDestination.allCases {
            settings.editorFileOpenDestination = destination
            settings.editorDirectoryOpenDestination = .splitLeft
            let restored = OhMyGhosttySettings(fileURL: url)
            #expect(restored.editorSettings.fileOpenDestination == destination)
            #expect(restored.editorSettings.directoryOpenDestination == .splitLeft)
        }
        try #"{"editor.fileOpenDestination":"invalid","editor.directoryOpenDestination":"invalid"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.editorFileOpenDestination == .currentPane)
        #expect(restored.editorDirectoryOpenDestination == .currentPane)
    }

    @Test func editorSettingsDefaultToIdeaAndFollowTerminal() {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.editorSettings == EditorSettings(
            keymapPreset: .idea,
            backgroundMode: .followTerminal,
            syntaxTheme: .followTerminal,
            fontFamily: .jetbrainsMono,
            fontSize: 13,
            tabWidth: 4,
            wordWrap: false
        ))
        #expect(settings.editorSettings.keymapProfile == .idea)
        #expect(settings.editorSettings.keymap.action(
            for: EditorKeyStroke(key: "d", modifiers: .command)
        ) == .duplicateLine)
    }

    @Test func languageSettingRoundTripsAndDefaultsToSystem() throws {
        let (settings, url) = temporarySettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.language == .system)

        settings.language = .simplifiedChinese
        let data = try Data(contentsOf: url)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["general.language"] as? String == "zh-Hans")

        let restored = OhMyGhosttySettings(fileURL: url)
        #expect(restored.language == .simplifiedChinese)
    }

    @Test func settingsLanguageResolvesSystemPreferenceAndExplicitPins() {
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: ["zh-Hans-CN", "en"]
        ).languageCode == "zh-Hans")
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: ["en-US"]
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .system,
            preferredLanguages: []
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .english,
            preferredLanguages: ["zh-Hans-CN"]
        ).languageCode == "en")
        #expect(SettingsStrings(
            language: .simplifiedChinese,
            preferredLanguages: ["en-US"]
        ).languageCode == "zh-Hans")
    }

    @Test func settingsStringsTranslateTheSettingsPage() {
        let zh = SettingsStrings(language: .simplifiedChinese, preferredLanguages: [])
        let en = SettingsStrings(language: .english, preferredLanguages: [])

        #expect(zh.windowTitle == "设置")
        #expect(en.windowTitle == "Settings")
        #expect(zh.tabTitle(.general) == "通用")
        #expect(zh.tabTitle(.plugins) == "插件")
        #expect(zh.tabTitle(.editor) == "编辑器")
        #expect(en.tabTitle(.editor) == "Editor")
        #expect(zh.resetEditorButton == "重置编辑器设置")
        #expect(zh.editorOpenDestinationTitle(.currentPane) == "当前窗格")
        #expect(en.editorOpenDestinationTitle(.newTab) == "New Tab")
        #expect(zh.languageSystem == "跟随系统")
        #expect(zh.startupModeLabel == "重新打开 OMG 时")
        #expect(en.startupModeTitle(.newTerminal) == "Open a New Terminal")
        #expect(en.startupModeTitle(.restoreTabs) == "Restore All Tabs")
        #expect(zh.startupModeTitle(.restoreSessions) == "恢复所有会话")
        #expect(zh.quitWithoutConfirmationLabel == "退出时无需确认")
        #expect(en.quitWithoutConfirmationLabel == "Quit Without Confirmation")
        #expect(zh.groupingTitle(.project) == "按项目")
        #expect(en.groupingTitle(.project) == "By Project")
        #expect(zh.pathDisplayTitle(.folderName) == "当前文件夹")
        #expect(zh.orderingTitle(.recentlyUsed) == "最近使用")
        #expect(zh.agentHooksUpdateRequired == "需要更新 Hooks")
        #expect(zh.agentDetectorMissing == "未安装检测器")
        #expect(zh.agentDetectorUpdateExplanation.contains("尚未接入厂商状态 Hook"))
        #expect(en.agentDetectorUpdateExplanation.contains("not a vendor status Hook"))
    }

    private func temporarySettings() -> (OhMyGhosttySettings, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        return (OhMyGhosttySettings(fileURL: url), url)
    }
}
