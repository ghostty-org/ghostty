//
//  GhosttyThemeTests.swift
//  Ghostty
//
//  Created by luca on 27.10.2025.
//

import AppKit
import XCTest

final class GhosttyThemeTests: GhosttyCustomConfigCase {
    let windowTitle = "GhosttyThemeTests"
    private func assertTitlebarAppearance(
        _ appearance: XCUIDevice.Appearance,
        for app: XCUIApplication,
        title: String? = nil,
        colorLocation: CGPoint? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for i in 0 ..< app.windows.count {
            let titleView = app.windows.element(boundBy: i).staticTexts.element(matching: NSPredicate(format: "value == '\(title ?? windowTitle)'"))

            let image = titleView.screenshot().image
            guard let imageColor = image.colorAt(x: Int(colorLocation?.x ?? 1), y: Int(colorLocation?.y ?? 1)) else {
                throw XCTSkip("failed to get pixel color", file: file, line: line)
            }

            switch appearance {
            case .dark:
                XCTAssertLessThanOrEqual(imageColor.luminance, 0.5, "Expected dark appearance for this test", file: file, line: line)
            default:
                XCTAssertGreaterThanOrEqual(imageColor.luminance, 0.5, "Expected light appearance for this test", file: file, line: line)
            }
        }
    }

    /// https://github.com/ghostty-org/ghostty/issues/8282
    @MainActor
    func testIssue8282() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .dark

        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        // create a new window
        app.typeKey("n", modifierFlags: [.command])
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightTransparentWindowThemeWithDarkTerminal() async throws {
        try updateConfig("title=\(windowTitle) \n window-theme=light")
        let app = try ghosttyApplication()
        app.launch()
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightNativeWindowThemeWithDarkTerminal() async throws {
        try updateConfig("title=\(windowTitle) \n window-theme = light \n macos-titlebar-style = native")
        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testReloadingLightTransparentWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        let app = try ghosttyApplication()
        app.launch()
        // default dark theme
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme = light")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testSwitchingSystemTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .dark
        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        XCUIDevice.shared.appearance = .light
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testReloadFromLightWindowThemeToDefaultTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
        try updateConfig("title=\(windowTitle) \n ")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testReloadFromDefaultThemeToDarkWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme=dark")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testReloadingFromDarkThemeToSystemLightTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n window-theme=dark")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testQuickTerminalThemeChange() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:3024 Day,dark:3024 Night \n confirm-close-surface=false")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication()
        app.launch()
        // close default window
        app.typeKey("w", modifierFlags: [.command])
        // open quick terminal
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Quick Terminal"].firstMatch.click()
        let title = "Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development."
        try assertTitlebarAppearance(.light, for: app, title: title, colorLocation: CGPoint(x: 5, y: 5)) // to avoid dark edge
        XCUIDevice.shared.appearance = .dark
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app, title: title, colorLocation: CGPoint(x: 5, y: 5))
    }
}
