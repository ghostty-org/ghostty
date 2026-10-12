//
//  GhosttyTabSidebarUITests.swift
//  Ghostty
//

import XCTest

final class GhosttyTabSidebarUITests: GhosttyCustomConfigCase {
    /// Use a separate defaults suite so the sidebar width/visibility of the
    /// other UI tests doesn't affect these.
    private let defaultsSuite = "GHOSTTY_UI_TESTS_TAB_SIDEBAR"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        try updateConfig(
            """
            title = "GhosttyTabSidebarUITests"
            confirm-close-surface = false
            """
        )
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        let app = try ghosttyApplication(defaultsSuite: defaultsSuite)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 2), "Main window should exist")
        return app
    }

    @MainActor
    private func sidebar(_ app: XCUIApplication) -> XCUIElement {
        app.windows.firstMatch.tables["TabSidebar"]
    }

    @MainActor
    private func waitForRowCount(_ app: XCUIApplication, _ count: Int) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", count),
            object: sidebar(app).tableRows)
        return XCTWaiter.wait(for: [expectation], timeout: 2) == .completed
    }

    @MainActor
    private func newTab(_ app: XCUIApplication) {
        app.windows.firstMatch.groups["Terminal pane"].typeKey("t", modifierFlags: .command)
    }

    @MainActor
    func testSidebarListsTabs() throws {
        let app = try launch()
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 1), "Tab sidebar should exist")
        XCTAssertEqual(sidebar(app).tableRows.count, 1, "A single tab should still be listed")

        newTab(app)
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 3))

        // The native tab bar must not be visible.
        XCTAssertEqual(app.windows.firstMatch.tabs.count, 0, "Native tabs should be hidden")
        XCTAssertTrue(sidebar(app).staticTexts["⌘1"].exists, "Shortcut hints should be shown")
    }

    @MainActor
    func testNewTabButton() throws {
        let app = try launch()
        app.windows.firstMatch.buttons["TabSidebarNewTabButton"].click()
        XCTAssertTrue(waitForRowCount(app, 2))
    }

    @MainActor
    func testCloseButton() throws {
        let app = try launch()
        newTab(app)
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 3))

        let row = sidebar(app).tableRows.element(boundBy: 1)
        row.hover()
        row.buttons["TabSidebarCloseButton"].click()
        XCTAssertTrue(waitForRowCount(app, 2))
    }

    @MainActor
    func testRenameInline() throws {
        let app = try launch()
        newTab(app)

        let row = sidebar(app).tableRows.element(boundBy: 1)
        row.doubleClick()
        app.typeText("Renamed Tab\n")
        XCTAssertTrue(sidebar(app).staticTexts["Renamed Tab"].waitForExistence(timeout: 1))
        XCTAssertEqual(app.windows.firstMatch.title, "Renamed Tab")

        // Renaming to an empty title restores the default title.
        row.doubleClick()
        app.typeKey(.delete, modifierFlags: [])
        app.typeText("\n")
        XCTAssertTrue(sidebar(app).staticTexts["GhosttyTabSidebarUITests"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testContextMenuRename() throws {
        let app = try launch()
        sidebar(app).tableRows.element(boundBy: 0).rightClick()
        app.menuItems["Rename Tab..."].click()
        app.typeText("From Menu\n")
        XCTAssertTrue(sidebar(app).staticTexts["From Menu"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testRenameCommitsOnTerminalClick() throws {
        let app = try launch()
        sidebar(app).tableRows.element(boundBy: 0).doubleClick()
        app.typeText("Saved by Clicking")

        app.windows.firstMatch.groups["Terminal pane"].click()

        XCTAssertTrue(sidebar(app).staticTexts["Saved by Clicking"].waitForExistence(timeout: 1))
        XCTAssertEqual(app.windows.firstMatch.title, "Saved by Clicking")
        XCTAssertEqual(sidebar(app).textFields.count, 0)
    }

    @MainActor
    func testRenameCommitsOnNewTabButtonClick() throws {
        let app = try launch()
        sidebar(app).tableRows.element(boundBy: 0).doubleClick()
        app.typeText("Saved Before New Tab")

        app.windows.firstMatch.buttons["TabSidebarNewTabButton"].click()

        XCTAssertTrue(waitForRowCount(app, 2))
        XCTAssertTrue(sidebar(app).staticTexts["Saved Before New Tab"].exists)
        XCTAssertEqual(sidebar(app).textFields.count, 0)
    }

    @MainActor
    func testRenameCommitsOnTabSwitch() throws {
        let app = try launch()
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 2))
        sidebar(app).tableRows.element(boundBy: 1).doubleClick()
        app.typeText("Saved Before Switching")

        sidebar(app).tableRows.element(boundBy: 0).click()

        XCTAssertTrue(sidebar(app).staticTexts["Saved Before Switching"].waitForExistence(timeout: 1))
        XCTAssertEqual(app.windows.firstMatch.title, "GhosttyTabSidebarUITests")
        XCTAssertEqual(sidebar(app).textFields.count, 0)
    }

    @MainActor
    func testRenameLongTitle() throws {
        let app = try launch()
        sidebar(app).tableRows.element(boundBy: 0).doubleClick()
        let editor = sidebar(app).textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 1))
        XCTAssertGreaterThanOrEqual(editor.frame.width, sidebar(app).frame.width - 40)

        let title = String(repeating: "Long Tab Name ", count: 12)
        // Send the edit and commit together so test-runner activation between
        // separate keyboard actions doesn't blur (and commit) the editor early.
        editor.typeText(title + "\n")

        XCTAssertEqual(app.windows.firstMatch.title, title)
        XCTAssertTrue(sidebar(app).staticTexts.matching(NSPredicate(format: "value == %@", title)).firstMatch.exists)
    }

    @MainActor
    func testRenameEscapeCancels() throws {
        let app = try launch()
        sidebar(app).tableRows.element(boundBy: 0).doubleClick()
        let editor = sidebar(app).textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 1))
        editor.typeText("Discard This Name\u{1b}")

        XCTAssertEqual(app.windows.firstMatch.title, "GhosttyTabSidebarUITests")
        XCTAssertFalse(sidebar(app).staticTexts["Discard This Name"].exists)
        XCTAssertEqual(sidebar(app).textFields.count, 0)
    }

    @MainActor
    func testContextMenuCloseOtherTabs() throws {
        let app = try launch()
        newTab(app)
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 3))

        sidebar(app).tableRows.element(boundBy: 0).rightClick()
        app.menuItems["Close Other Tabs"].click()
        XCTAssertTrue(waitForRowCount(app, 1))
    }

    @MainActor
    func testToggleSidebar() throws {
        let app = try launch()
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 1))

        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertFalse(sidebar(app).isHittable, "Sidebar should be hidden")

        app.typeKey("b", modifierFlags: [.command, .shift])
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 1))
        XCTAssertTrue(sidebar(app).isHittable, "Sidebar should be visible again")
    }

    @MainActor
    func testDragReorder() throws {
        let app = try launch()
        newTab(app)
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 3))

        // Rename the last tab so we can find it after moving.
        let last = sidebar(app).tableRows.element(boundBy: 2)
        last.doubleClick()
        app.typeText("Moved\n")
        XCTAssertTrue(sidebar(app).staticTexts["Moved"].waitForExistence(timeout: 1))

        last.press(forDuration: 0.3, thenDragTo: sidebar(app).tableRows.element(boundBy: 0))

        let first = sidebar(app).tableRows.element(boundBy: 0)
        XCTAssertTrue(first.staticTexts["Moved"].waitForExistence(timeout: 1), "Dragged tab should be first")
    }

    @MainActor
    func testHiddenTitlebarAllowsTabs() throws {
        try updateConfig(
            """
            macos-titlebar-style = hidden
            title = "GhosttyTabSidebarUITests"
            """
        )
        let app = try launch()
        newTab(app)
        XCTAssertTrue(waitForRowCount(app, 2))
        XCTAssertEqual(app.windows.count, 1, "New tabs should not open new windows")
    }
}
