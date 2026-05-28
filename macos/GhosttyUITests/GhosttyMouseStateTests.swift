//
//  GhosttyMouseStateTests.swift
//  Ghostty
//
//  Created by Lukas on 19.03.2026.
//

import XCTest

final class GhosttyMouseStateTests: GhosttyCustomConfigCase {
    // https://github.com/ghostty-org/ghostty/pull/11276
    @MainActor func testSelectionFocusChange() async throws {
        let app = XCUIApplication()
        app.activate()
        // Write dummy text to a temp file, cat it into the terminal, then clean up
        let lines = (1...200).map { "Line \($0): The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet, consectetur adipiscing elit." }
        let text = lines.joined(separator: "\n") + "\n"
        let tmpFile = NSTemporaryDirectory() + "ghostty_test_dummy.txt"
        try text.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        app.typeText("cat \(tmpFile)\r")
        app.menuItems["Command Palette"].firstMatch.click()

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()

        app.activate()

        app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] 'Clear Screen'"))
            .firstMatch
            .click()
        let surface = app.groups["Terminal pane"]
        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: 10))
            .click()

        surface
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: 20, dy: surface.frame.height * 0.5))
            .hover()

        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: .command)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), nil, "Moving mouse shouldn't select any texts")
    }

    @MainActor func testSearchFocusState() async throws {
        let app = try ghosttyApplication()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")
        app.typeKey("f", modifierFlags: .command)

        let textfield = app.textFields.firstMatch
        XCTAssertTrue(textfield.waitForExistence(timeout: 5), "Search field should appear")
        app.typeText("a")

        XCTAssertTrue(textfield.stringValue == "a", "Search text should be `a`")

        textfield.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: textfield.frame.width * 0.5, dy: 0))
            .click()

        app.typeText("b")

        XCTAssertTrue(textfield.stringValue == "ab", "Search text should be `ab`")

        // resign
        app.typeKey(.escape, modifierFlags: [])

        // dismiss
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(textfield.waitForNonExistence(timeout: 5), "Search field should disappear")
    }
}

private extension XCUIElement {
    var stringValue: String? {
        (value as? String)
    }
}
