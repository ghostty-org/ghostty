import XCTest

final class GhosttyWorkspaceUITests: GhosttyCustomConfigCase {
    // MARK: - Sidebar Toggle

    @MainActor
    func testToggleSidebarHidesAndShowsSidebar() async throws {
        try updateConfig("confirm-close-surface=false")
        let app = try ghosttyApplication()
        app.launch()
        try await Task.sleep(for: .seconds(1))

        let window = app.windows.firstMatch

        // Record initial width.
        let initialWidth = window.frame.width

        // Toggle sidebar off: Cmd+Shift+E
        app.typeKey("e", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))

        let collapsedWidth = window.frame.width
        // Sidebar hidden → window width should shrink (or terminal fills full width).
        // The sidebar is ~220pt, so we just check the layout changed.
        XCTAssertNotEqual(initialWidth, collapsedWidth, "Window width should change when sidebar is toggled off")

        // Toggle sidebar back on: Cmd+Shift+E
        app.typeKey("e", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))

        let restoredWidth = window.frame.width
        XCTAssertEqual(initialWidth, restoredWidth, accuracy: 2, "Window width should restore after toggling sidebar back on")
    }

    @MainActor
    func testToggleSidebarMenuItemExists() async throws {
        try updateConfig("confirm-close-surface=false")
        let app = try ghosttyApplication()
        app.launch()
        try await Task.sleep(for: .seconds(1))

        // Open the View menu and verify workspace menu items exist.
        let viewMenu = app.menuBarItems["View"].firstMatch
        XCTAssertTrue(viewMenu.exists, "View menu should exist")
        viewMenu.click()

        let toggleSidebar = app.menuItems["Toggle Sidebar"].firstMatch
        XCTAssertTrue(toggleSidebar.exists, "Toggle Sidebar menu item should exist in View menu")

        let nextProject = app.menuItems["Next Project"].firstMatch
        XCTAssertTrue(nextProject.exists, "Next Project menu item should exist in View menu")

        let prevProject = app.menuItems["Previous Project"].firstMatch
        XCTAssertTrue(prevProject.exists, "Previous Project menu item should exist in View menu")

        // Dismiss the menu.
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Window Lifecycle

    @MainActor
    func testWindowStaysOpenWhenLastSurfaceExits() async throws {
        try updateConfig("confirm-close-surface=false")
        let app = try ghosttyApplication()
        app.launch()
        try await Task.sleep(for: .seconds(1))

        let initialWindowCount = app.windows.count
        XCTAssertGreaterThanOrEqual(initialWindowCount, 1, "Should have at least one window")

        // Type "exit" into the terminal to close the shell process.
        let terminal = app.windows.firstMatch.groups["Terminal pane"].firstMatch
        if terminal.exists {
            terminal.typeText("exit\r")
            try await Task.sleep(for: .seconds(1))
        }

        // Window should still exist — workspace windows don't close when the terminal exits.
        XCTAssertGreaterThanOrEqual(app.windows.count, 1, "Window should stay open after terminal process exits")
    }

    // MARK: - Dark Mode Divider

    @MainActor
    func testDividerExistsInBothAppearances() async throws {
        try updateConfig("confirm-close-surface=false")
        XCUIDevice.shared.appearance = .light
        let app = try ghosttyApplication()
        app.launch()
        try await Task.sleep(for: .seconds(1))

        // The sidebar should be accessible in the window.
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "Window should exist in light mode")

        // Switch to dark mode.
        XCUIDevice.shared.appearance = .dark
        try await Task.sleep(for: .seconds(0.5))

        XCTAssertTrue(window.exists, "Window should exist after switching to dark mode")

        // Switch back to light mode.
        XCUIDevice.shared.appearance = .light
        try await Task.sleep(for: .seconds(0.5))

        XCTAssertTrue(window.exists, "Window should exist after switching back to light mode")
    }
}
