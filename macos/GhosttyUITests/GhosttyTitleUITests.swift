//
//  GhosttyTitleUITests.swift
//  GhosttyUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class GhosttyTitleUITests: GhosttyCustomConfigCase {

    override var customGhosttyConfig: String? {
        #"title = "GhosttyUITestsLaunchTests""#
    }

    @MainActor
    func testTitle() throws {
        let app = try ghosttyApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "GhosttyUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
