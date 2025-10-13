//
//  GhosttyTitleUITests.swift
//  GhosttyUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class GhosttyTitleUITests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    var configFile: URL?
    override func setUpWithError() throws {
        continueAfterFailure = false
        let temporaryConfig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try #"title = "GhosttyUITestsLaunchTests""#.write(to: temporaryConfig, atomically: true, encoding: .utf8)
        configFile = temporaryConfig
    }

    override func tearDown() async throws {
        if let configFile {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    @MainActor
    func testTitle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile?.path
        app.launch()

        XCTAssert(app.windows.firstMatch.title == "GhosttyUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
