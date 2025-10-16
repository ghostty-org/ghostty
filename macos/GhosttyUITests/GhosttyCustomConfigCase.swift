//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

class GhosttyCustomConfigCase: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    var configFile: URL?
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let customGhosttyConfig else {
            return
        }
        let temporaryConfig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try customGhosttyConfig.write(to: temporaryConfig, atomically: true, encoding: .utf8)
        configFile = temporaryConfig
    }

    override func tearDown() async throws {
        if let configFile {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    var customGhosttyConfig: String? {
        nil
    }

    func ghosttyApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile?.path
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        return app
    }
}
