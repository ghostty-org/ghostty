//
//  GhosttyTitleUITests.swift
//  GhosttyUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class GhosttyTitleUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(#"title = "GhosttyUITestsLaunchTests""#)
    }

    @MainActor
    func testTitle() throws {
        let app = try ghosttyApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "GhosttyUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
