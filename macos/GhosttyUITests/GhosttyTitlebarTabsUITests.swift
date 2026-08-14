//
//  GhosttyTitlebarTabsUITests.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

final class GhosttyTitlebarTabsUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            macos-titlebar-style = tabs
            title = "GhosttyTitlebarTabsUITests"
            """
        )
    }

    @MainActor
    func testCustomTitlebar() throws {
        let app = try ghosttyApplication()
        app.launch()
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        app.typeKey("\n", modifierFlags: [.command, .shift])
        let resetZoomButton = app.groups.buttons["ResetZoom"]
        let windowTitle = app.windows.firstMatch.title
        let titleView = app.staticTexts.element(matching: NSPredicate(format: "value == '\(windowTitle)'"))

        XCTAssertEqual(titleView.frame.midY, resetZoomButton.frame.midY, accuracy: 1, "Window title should be vertically centered with reset zoom button: \(titleView.frame.midY) != \(resetZoomButton.frame.midY)")
    }

    @MainActor
    func testTabsGeometryInNormalWindow() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.tabs.count, 2, "There should be 2 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsGeometryInFullscreen() throws {
        let app = try ghosttyApplication()
        app.launch()
        app.typeKey("f", modifierFlags: [.command, .control])
        // using app to type ⌘+t might not be able to create tabs
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.tabs.count, 2, "There should be 2 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsGeometryAfterMovingTabs() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")
        // create another 2 tabs
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        // move to the left
        app.menuItems["_zoomLeft:"].firstMatch.click()

        // create another window with 2 tabs
        app.windows.firstMatch.groups["Terminal pane"].typeKey("n", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 2, "There should be 2 windows")

        // move to the right
        app.menuItems["_zoomRight:"].firstMatch.click()

        // now second window is the first/main one in the list
        app.windows.firstMatch.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        app.windows.element(boundBy: 1).tabs.firstMatch.click() // focus first window

        // now the first window is the main one
        let firstTabInFirstWindow = app.windows.firstMatch.tabs.firstMatch
        let firstTabInSecondWindow = app.windows.element(boundBy: 1).tabs.firstMatch

        // drag a tab from one window to another
        firstTabInFirstWindow.press(forDuration: 0.2, thenDragTo: firstTabInSecondWindow)

        // check tabs in the first
        checkTabsGeometry(app.windows.firstMatch)
        // focus another window
        app.windows.element(boundBy: 1).tabs.firstMatch.click()
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsGeometryAfterMergingAllWindows() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")

        // create another 2 windows
        app.typeKey("n", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)

        // merge into one window, resulting 3 tabs
        app.menuItems["mergeAllWindows:"].firstMatch.click()

        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 3, timeout: 1), "There should be 3 tabs")
        checkTabsGeometry(app.windows.firstMatch)
    }

    @MainActor
    func testTabsOnLeft() throws {
        try checkSideTabs(location: "left")
    }

    @MainActor
    func testTabsOnRight() throws {
        try checkSideTabs(location: "right")
    }

    /// `toggle_tabs_location` cycles the tabs of the current window through the
    /// top, the left side, and the right side.
    @MainActor
    func testToggleTabsLocationKeybind() throws {
        // Not `macos-titlebar-style = tabs`: those windows draw their tabs into a
        // custom titlebar that can't be replaced after the window is created, so
        // they can't move their tabs.
        try updateConfig(
            """
            keybind = cmd+ctrl+shift+e=toggle_tabs_location
            title = "GhosttySideTabsUITests"
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 2), "Terminal should exist")

        // A second tab, so the native tab bar is showing to begin with.
        terminal.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: \.tabs.count, toEqual: 2, timeout: 2), "There should be 2 native tabs")

        let window = app.windows.firstMatch
        let sideTabs = app.descendants(matching: .any)["Side Tabs"]
        XCTAssertFalse(sideTabs.exists, "Tabs should start at the top")

        // Top to left.
        terminal.typeKey("e", modifierFlags: [.command, .control, .shift])
        XCTAssertTrue(sideTabs.waitForExistence(timeout: 2), "Tabs should move into a sidebar")
        XCTAssertTrue(
            app.wait(for: \.tabs.count, toEqual: 0, timeout: 2),
            "The sidebar should replace the native tab bar")
        XCTAssertTrue(
            wait(until: { abs(sideTabs.frame.minX - window.frame.minX) <= 1 }),
            "Tabs should be on the left")

        // Left to right.
        terminal.typeKey("e", modifierFlags: [.command, .control, .shift])
        XCTAssertTrue(
            wait(until: { abs(sideTabs.frame.maxX - window.frame.maxX) <= 1 }),
            "Tabs should be on the right")

        // Right back to the top.
        terminal.typeKey("e", modifierFlags: [.command, .control, .shift])
        XCTAssertTrue(
            app.wait(for: \.tabs.count, toEqual: 2, timeout: 2),
            "The native tab bar should come back")
        XCTAssertFalse(sideTabs.exists, "The sidebar should be gone")
    }

    @MainActor
    private func checkSideTabs(location: String) throws {
        // `macos-titlebar-style = tabs` is intentional: a sidebar can't coexist
        // with tabs in the titlebar, so this also covers the fallback to the
        // transparent titlebar style.
        try updateConfig(
            """
            macos-titlebar-style = tabs
            macos-tabs-location = \(location)
            title = "GhosttySideTabsUITests"
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let sideTabs = app.descendants(matching: .any)["Side Tabs"]
        XCTAssertTrue(sideTabs.waitForExistence(timeout: 2), "Side tabs should exist")

        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        let tabRows = app.buttons.matching(identifier: "Side Tab")
        XCTAssertTrue(
            tabRows.element(boundBy: 1).waitForExistence(timeout: 2),
            "A new tab should show up in the sidebar")
        XCTAssertEqual(tabRows.count, 2, "There should be 2 tabs in the sidebar")

        // The sidebar replaces the native tab bar rather than doubling up on it.
        XCTAssertTrue(
            app.wait(for: \.tabs.count, toEqual: 0, timeout: 2),
            "There should be no native tabs")

        let window = app.windows.firstMatch
        if location == "left" {
            XCTAssertEqual(sideTabs.frame.minX, window.frame.minX, accuracy: 1)
        } else {
            XCTAssertEqual(sideTabs.frame.maxX, window.frame.maxX, accuracy: 1)
        }
    }

    /// Poll until `condition` holds. Moving the sidebar from one side to the
    /// other only changes frames, so there is no element to wait on.
    private func wait(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return condition()
    }

    func checkTabsGeometry(_ window: XCUIElement) {
        let closeTabButtons = window.buttons.matching(identifier: "_closeButton")

        XCTAssertEqual(closeTabButtons.count, window.tabs.count, "Close tab buttons count should match tabs count")

        var previousTabHeight: CGFloat?
        for idx in 0 ..< window.tabs.count {
            let currentTab = window.tabs.element(boundBy: idx)
            // focus
            currentTab.click()
            // switch to the tab
            window.typeKey("\(idx + 1)", modifierFlags: .command)
            // add a split
            window.typeKey("d", modifierFlags: .command)
            // zoom this split
            // haven't found a way to locate our reset zoom button yet..
            window.typeKey("\n", modifierFlags: [.command, .shift])
            window.typeKey("\n", modifierFlags: [.command, .shift])

            if let previousHeight = previousTabHeight {
                XCTAssertEqual(currentTab.frame.height, previousHeight, accuracy: 1, "The tab's height should stay the same")
            }
            previousTabHeight = currentTab.frame.height

            let titleFrame = currentTab.frame
            let shortcutLabelFrame = window.staticTexts.element(matching: NSPredicate(format: "value CONTAINS[c] '⌘\(idx + 1)'")).firstMatch.frame
            let closeButtonFrame = closeTabButtons.element(boundBy: idx).frame

            XCTAssertEqual(titleFrame.midY, shortcutLabelFrame.midY, accuracy: 1, "Tab title should be vertically centered with its shortcut label: \(titleFrame.midY) != \(shortcutLabelFrame.midY)")
            XCTAssertEqual(titleFrame.midY, closeButtonFrame.midY, accuracy: 1, "Tab title should be vertically centered with its close button: \(titleFrame.midY) != \(closeButtonFrame.midY)")
        }
    }
}
