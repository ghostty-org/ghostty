//
//  GhosttyCommandPaletteTests.swift
//  Ghostty
//
//  Created by Lukas on 19.03.2026.
//

import XCTest

final class GhosttyCommandPaletteTests: GhosttyCustomConfigCase {
    override static var runsForEachTargetApplicationUIConfiguration: Bool { false }
    @MainActor func testDismissingCommandPalette() async throws {
        let app = try ghosttyApplication()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        app.menuItems["Command Palette"].firstMatch.click()

        let clearScreenButton = app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'"))
            .firstMatch

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        clearScreenButton.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: -30, dy: 0))
            .click()

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after clicking outside")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after typing escape")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after submitting query")

        app.typeKey("p", modifierFlags: [.command, .shift])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")

        app.typeText("Clear Screen")
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after selecting a command by keyboard")

        app.typeKey("p", modifierFlags: [.command, .shift])
        app.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(clearScreenButton.waitForExistence(timeout: 5), "Command Palette should appear")
        clearScreenButton.click()

        XCTAssertTrue(clearScreenButton.waitForNonExistence(timeout: 5), "Command Palette should disappear after selecting a command by mouse")
    }

    @MainActor func testSelectCommandWithMouse() async throws {
        let app = try ghosttyApplication()
        app.activate()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        app.menuItems["Command Palette"].firstMatch.click()

        app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Close All Windows'"))
            .firstMatch.click()

        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 2), "All windows should be closed")
    }
}

