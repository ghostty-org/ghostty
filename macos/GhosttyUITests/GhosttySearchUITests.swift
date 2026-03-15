//
//  GhosttySearchUITests.swift
//  GhosttyUITests
//

import XCTest

final class GhosttySearchUITests: GhosttyCustomConfigCase {

    /// Verifies that Cmd+G (Find Next) navigates search results when the
    /// search field is focused.
    ///
    /// This is a regression test for a bug where the NSTextView field editor
    /// consumed Cmd+G via performKeyEquivalent before Ghostty could handle it.
    /// Without the fix, the search match indicator never changes; with the fix,
    /// pressing Cmd+G advances to the next match.
    @MainActor
    func testCmdGNavigatesSearchWhileSearchFieldFocused() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Ghostty window should appear")

        // Type repeated text so we have multiple search matches.
        let terminalPane = window.groups["Terminal pane"]
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 5), "Terminal pane should exist")
        terminalPane.typeText("echo hello && echo hello && echo hello\r")

        // Wait for output to render.
        try await Task.sleep(for: .seconds(1))

        // Open search with Cmd+F. Focus should land in the search field.
        app.typeKey("f", modifierFlags: .command)

        // Find the search text field by its accessibility identifier.
        let searchField = window.textFields["ghostty-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should appear")

        // Type a search term that will have multiple matches.
        searchField.typeText("hello")

        // Wait for search results to populate.
        try await Task.sleep(for: .seconds(1))

        // Find the match counter text (e.g. "1/3"). It's a staticText
        // inside the search overlay whose value matches the N/M pattern.
        let matchCounter = window.staticTexts.matching(
            NSPredicate(format: "value MATCHES %@", "\\d+/\\d+")
        ).firstMatch

        // The counter should exist if there are matches.
        guard matchCounter.waitForExistence(timeout: 3) else {
            XCTFail("Match counter (e.g. '1/3') should appear after searching")
            return
        }

        let initialCounter = matchCounter.value as? String
        XCTAssertNotNil(initialCounter, "Match counter should have a string value")

        // Press Cmd+G to navigate to the next match.
        // WITHOUT the fix: the field editor consumes this and the counter doesn't change.
        // WITH the fix: the search navigates and the counter updates.
        app.typeKey("g", modifierFlags: .command)
        try await Task.sleep(for: .seconds(0.5))

        let afterNextCounter = matchCounter.value as? String
        XCTAssertNotNil(afterNextCounter, "Match counter should still have a value after Cmd+G")
        XCTAssertNotEqual(
            initialCounter, afterNextCounter,
            "Cmd+G should advance the search match (counter should change from \(initialCounter ?? "nil"))"
        )

        // Also verify Cmd+Shift+G goes back.
        app.typeKey("g", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))

        let afterPrevCounter = matchCounter.value as? String
        XCTAssertEqual(
            initialCounter, afterPrevCounter,
            "Cmd+Shift+G should return to the original match"
        )
    }
}
