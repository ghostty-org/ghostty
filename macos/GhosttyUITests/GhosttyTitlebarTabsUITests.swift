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
