//
//  GhosttyWindowPositionUITests.swift
//  GhosttyUITests
//
//  Created by Claude on 2026-03-11.
//

import XCTest

final class GhosttyWindowPositionUITests: GhosttyCustomConfigCase {
    // MARK: - Cascading

    @MainActor func testWindowCascading() async throws {
        try updateConfig(
            """
            window-width = 30
            window-height = 10
            title = "GhosttyWindowPositionUITests"
            """
        )

        let app = try ghosttyApplication()
        // Suppress Restoration
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        // Clean run
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"

        app.launch() // window in the center

        app.menuBarItems["Window"].firstMatch.click()
        app.menuItems["_zoomTopLeft:"].firstMatch.click()

        // wait for the animation to finish
        try await Task.sleep(for: .seconds(0.5))

        let window = app.windows.firstMatch
        let windowFrame = window.frame
        XCTAssertEqual(windowFrame.minX, 0, "Window should be on the left")

        app.typeKey("n", modifierFlags: [.command])

        let window2 = app.windows.firstMatch
        XCTAssertTrue(window2.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame2 = window2.frame
        XCTAssertNotEqual(windowFrame, windowFrame2, "New window should have moved")

        XCTAssertEqual(windowFrame2.minX, windowFrame.minX + 30, accuracy: 5, "New window should be on the right")

        XCTAssertEqual(windowFrame2.minY, windowFrame.minY + 30, accuracy: 5, "New window should be on the bottom right")

        app.typeKey("n", modifierFlags: [.command])

        let window3 = app.windows.firstMatch
        XCTAssertTrue(window3.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame3 = window3.frame
        XCTAssertNotEqual(windowFrame2, windowFrame3, "New window should have moved")

        XCTAssertEqual(windowFrame3.minX, windowFrame2.minX + 30, accuracy: 5, "New window should be on the right")

        XCTAssertEqual(windowFrame3.minY, windowFrame2.minY + 30, accuracy: 5, "New window should be on the bottom right")

        app.typeKey("n", modifierFlags: [.command])

        let window4 = app.windows.firstMatch
        XCTAssertTrue(window4.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame4 = window4.frame
        XCTAssertNotEqual(windowFrame3, windowFrame4, "New window should have moved")

        XCTAssertEqual(windowFrame4.minX, windowFrame3.minX + 30, accuracy: 5, "New window should be on the right")

        XCTAssertEqual(windowFrame4.minY, windowFrame3.minY + 30, accuracy: 5, "New window should be on the bottom right")
    }

    @MainActor func testDragSplitWindowPosition() async throws {
        try updateConfig(
            """
            window-width = 40
            window-height = 20
            title = "GhosttyWindowPositionUITests"
            macos-titlebar-style = hidden
            """
        )

        let app = try ghosttyApplication()
        // Suppress Restoration
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        // Clean run
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"

        app.launch() // window in the center

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "New window should appear")

        // remove fixed size
        try updateConfig(
            """
            title = "GhosttyWindowPositionUITests"
            macos-titlebar-style = hidden
            """
        )
        app.typeKey(",", modifierFlags: [.command, .shift])

        app.typeKey("d", modifierFlags: [.command])

        let rightSplit = app.groups["Right pane"]
        let rightFrame = rightSplit.frame

        let sourcePos = rightSplit.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: rightFrame.size.width / 2, dy: 3))

        let targetPos = rightSplit.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: rightFrame.size.width + 100, dy: 0))

        sourcePos.click(forDuration: 0.2, thenDragTo: targetPos)

        let window2 = app.windows.firstMatch
        XCTAssertTrue(window2.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame2 = window2.frame

        try await Task.sleep(for: .seconds(0.5))

        XCTAssertEqual(windowFrame2.minX, rightFrame.maxX + 100, accuracy: 5, "New window should be target position")
        XCTAssertEqual(windowFrame2.minY, rightFrame.minY, accuracy: 5, "New window should be target position")
        XCTAssertEqual(windowFrame2.width, rightFrame.width, accuracy: 5, "New window should use size from config")
         XCTAssertEqual(windowFrame2.height, rightFrame.height, accuracy: 5, "New window should use size from config")
    }

    @MainActor func testDragSplitWindowPositionWithFixedSize() async throws {
        try updateConfig(
            """
            window-width = 40
            window-height = 20
            title = "GhosttyWindowPositionUITests"
            macos-titlebar-style = hidden
            """
        )

        let app = try ghosttyApplication()
        // Suppress Restoration
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        // Clean run
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"

        app.launch() // window in the center

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame = window.frame

        app.typeKey("d", modifierFlags: [.command])

        let rightSplit = app.groups["Right pane"]
        let rightFrame = rightSplit.frame

        let sourcePos = rightSplit.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: rightFrame.size.width / 2, dy: 3))

        let targetPos = rightSplit.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: rightFrame.size.width + 100, dy: 0))

        sourcePos.click(forDuration: 0.2, thenDragTo: targetPos)

        let window2 = app.windows.firstMatch
        XCTAssertTrue(window2.waitForExistence(timeout: 5), "New window should appear")
        let windowFrame2 = window2.frame

        try await Task.sleep(for: .seconds(0.5))

        XCTAssertEqual(windowFrame2.minX, rightFrame.maxX + 100, accuracy: 5, "New window should be target position")
        XCTAssertEqual(windowFrame2.minY, rightFrame.minY, accuracy: 5, "New window should be target position")
        XCTAssertEqual(windowFrame2.width, windowFrame.width, accuracy: 5, "New window should use size from config")
        // We're still using right frame, because of the debug banner
         XCTAssertEqual(windowFrame2.height, rightFrame.height, accuracy: 5, "New window should use size from config")
    }

    // MARK: - Restore round-trip per titlebar style

    @MainActor func testRestoredNative() throws { try runRestoreTest(titlebarStyle: "native") }
    @MainActor func testRestoredHidden() throws { try runRestoreTest(titlebarStyle: "hidden") }
    @MainActor func testRestoredTransparent() throws { try runRestoreTest(titlebarStyle: "transparent") }
    @MainActor func testRestoredTabs() throws { try runRestoreTest(titlebarStyle: "tabs") }

    // MARK: - Config overrides cached position/size

    @MainActor
    func testConfigOverridesCachedPositionAndSize() async throws {
        // Launch maximized so the cached frame is fullscreen-sized.
        try updateConfig(
            """
            maximize = true
            title = "GhosttyWindowPositionUITests"
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should appear")

        let maximizedFrame = window.frame

        // Now update the config with a small explicit size and position,
        // reload, and open a new window. It should respect the config, not the cache.
        try updateConfig(
            """
            window-position-x = 50
            window-position-y = 50
            window-width = 30
            window-height = 30
            title = "GhosttyWindowPositionUITests"
            """
        )
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        app.typeKey("n", modifierFlags: [.command])

        XCTAssertEqual(app.windows.count, 2, "Should have 2 windows")
        let newWindow = app.windows.element(boundBy: 0)
        let newFrame = newWindow.frame

        // The new window should be smaller than the maximized one.
        XCTAssertLessThan(newFrame.size.width, maximizedFrame.size.width,
                          "30 columns should be narrower than maximized")
        XCTAssertLessThan(newFrame.size.height, maximizedFrame.size.height,
                          "30 rows should be shorter than maximized")

        app.terminate()
    }

    // MARK: - Size-only config change preserves position

    @MainActor
    func testSizeOnlyConfigPreservesPosition() async throws {
        // Launch maximized so the window has a known position (top-left of visible frame).
        try updateConfig(
            """
            maximize = true
            title = "GhosttyWindowPositionUITests"
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should appear")

        let initialFrame = window.frame

        // Reload with only size changed, close current window, open new one.
        // Position should be restored from cache.
        try updateConfig(
            """
            window-width = 30
            window-height = 30
            title = "GhosttyWindowPositionUITests"
            """
        )
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        app.typeKey("w", modifierFlags: [.command])
        app.typeKey("n", modifierFlags: [.command])

        let newWindow = app.windows.firstMatch
        XCTAssertTrue(newWindow.waitForExistence(timeout: 5), "New window should appear")

        let newFrame = newWindow.frame

        // Position should be preserved from the cached value.
        // Compare x and maxY since the window is anchored at the top-left
        // but AppKit uses bottom-up coordinates (origin.y changes with height).
        XCTAssertEqual(newFrame.origin.x, initialFrame.origin.x, accuracy: 2,
                        "x position should not change with size-only config")
        XCTAssertEqual(newFrame.maxY, initialFrame.maxY, accuracy: 2,
                        "top edge (maxY) should not change with size-only config")

        app.terminate()
    }

    // MARK: - Shared round-trip helper

    /// Opens a new window, records its frame, closes it, opens another,
    /// and verifies the frame is restored consistently.
    private func runRestoreTest(titlebarStyle: String) throws {
        try updateConfig(
            """
            macos-titlebar-style = \(titlebarStyle)
            title = "GhosttyWindowPositionUITests"
            """
        )

        let app = try ghosttyApplication()
        // Suppress Restoration
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "NO"]
        // Clean run
        app.launchEnvironment["GHOSTTY_CLEAR_USER_DEFAULTS"] = "YES"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should appear")

        let firstFrame = window.frame
        let screenFrame = NSScreen.main?.frame ?? .zero

        XCTAssertEqual(firstFrame.midX, screenFrame.midX, accuracy: 5.0, "First window should be centered horizontally")

        // Close the window and open a new one — it should restore the same frame.
        app.typeKey("w", modifierFlags: [.command])
        app.typeKey("n", modifierFlags: [.command])

        let window2 = app.windows.firstMatch
        XCTAssertTrue(window2.waitForExistence(timeout: 5), "New window should appear")

        let restoredFrame = window2.frame

        XCTAssertEqual(restoredFrame.origin.x, firstFrame.origin.x, accuracy: 2,
                        "[\(titlebarStyle)] x position should be restored")
        XCTAssertEqual(restoredFrame.origin.y, firstFrame.origin.y, accuracy: 2,
                        "[\(titlebarStyle)] y position should be restored")
        XCTAssertEqual(restoredFrame.size.width, firstFrame.size.width, accuracy: 2,
                        "[\(titlebarStyle)] width should be restored")
        XCTAssertEqual(restoredFrame.size.height, firstFrame.size.height, accuracy: 2,
                        "[\(titlebarStyle)] height should be restored")

        app.terminate()
    }
}
