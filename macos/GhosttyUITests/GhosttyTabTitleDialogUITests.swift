//
//  GhosttyTabTitleDialogUITests.swift
//  GhosttyUITests
//

import XCTest

final class GhosttyTabTitleDialogUITests: GhosttyCustomConfigCase {
    /// https://github.com/ghostty-org/ghostty/discussions/10623
    @MainActor
    func testIssue10623() throws {
        let app = try ghosttyApplication()
        app.launch()

        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Change Tab Title..."].firstMatch.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 1), "Change Tab Title sheet should appear")

        let textField = sheet.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 1), "Change Tab Title text field should exist")

        // Keep this deterministic and independent from prior pasteboard contents.
        let expectedText = "ghostty-title-\(UUID().uuidString)"

        textField.click()
        textField.typeText(expectedText)

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("a", modifierFlags: .command)
        textField.typeText("x")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(
            textField.value as? String,
            expectedText,
            "Cmd+C should copy selected text from the sheet field"
        )

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("x", modifierFlags: .command)

        XCTAssertEqual(
            textField.value as? String,
            "",
            "Cmd+X should cut selected text from the sheet field"
        )

        app.typeKey("v", modifierFlags: .command)

        XCTAssertEqual(
            textField.value as? String,
            expectedText,
            "Cmd+V should paste the cut text back into the sheet field"
        )
    }
}
