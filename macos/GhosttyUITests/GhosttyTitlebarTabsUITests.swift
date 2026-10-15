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

    /// Tabs are shown in the tab sidebar, so the `tabs` titlebar style no longer
    /// shows native tabs in the titlebar.
    @MainActor
    func testTabsShownInSidebar() throws {
        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")
        app.groups["Terminal pane"].typeKey("t", modifierFlags: .command)

        let rows = app.windows.firstMatch.tables["TabSidebar"].tableRows
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: rows)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed, "There should be 2 tabs in the sidebar")
        XCTAssertEqual(app.windows.firstMatch.tabs.count, 0, "Native tabs should be hidden")
    }
}
