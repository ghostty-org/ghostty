//
//  GhosttyThemeTests.swift
//  Ghostty
//
//  Created by luca on 27.10.2025.
//

import XCTest
import AppKit

final class GhosttyThemeTests: GhosttyCustomConfigCase {

    /// https://github.com/ghostty-org/ghostty/issues/8282
    func testIssue8282() throws {
        try updateConfig("theme=light:3024 Day,dark:3024 Night\ntitle=GhosttyThemeTests")
        XCUIDevice.shared.appearance = .dark

        let app = try ghosttyApplication()
        app.launch()
        let windowTitle = app.windows.firstMatch.title
        let titleView = app.windows.firstMatch.staticTexts.element(matching: NSPredicate(format: "value == '\(windowTitle)'"))

        let image = titleView.screenshot().image
        guard let imageColor = image.colorAt(x: 0, y: 0) else {
            return
        }
        XCTAssertLessThanOrEqual(imageColor.luminance, 0.5, "Expected dark appearance for this test")
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        // create a new window
        app.typeKey("n", modifierFlags: [.command])

        for i in 0..<app.windows.count {
            let titleViewI = app.windows.element(boundBy: i).staticTexts.element(matching: NSPredicate(format: "value == '\(windowTitle)'"))

            let imageI = titleViewI.screenshot().image
            guard let imageColorI = imageI.colorAt(x: 0, y: 0) else {
                return
            }

            XCTAssertLessThanOrEqual(imageColorI.luminance, 0.5, "Expected dark appearance for this test")
        }
    }
}
