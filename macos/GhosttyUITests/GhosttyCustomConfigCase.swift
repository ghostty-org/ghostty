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
    }

    override func tearDown() async throws {
        if let configFile {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    func updateConfig(_ newConfig: String) throws {
        if let configFile {
            try FileManager.default.removeItem(at: configFile)
        }
        let temporaryConfig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try newConfig.write(to: temporaryConfig, atomically: true, encoding: .utf8)
        configFile = temporaryConfig
    }

    func ghosttyApplication() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        guard let configFile else {
            return app
        }
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile.path
        return app
    }
}
