//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

class GhosttyCustomConfigCase: XCTestCase {
    /// We only want run these UI tests
    /// when testing manually with Xcode IDE
    ///
    /// So that we don't have to wait for each ci check
    /// to run these tedious tests
    override class var defaultTestSuite: XCTestSuite {
        // https://lldb.llvm.org/cpp_reference/PlatformDarwin_8cpp_source.html#:~:text==%20%22-,IDE_DISABLED_OS_ACTIVITY_DT_MODE

        if ProcessInfo.processInfo.environment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] != nil {
            return XCTestSuite(forTestCaseClass: Self.self)
        } else {
            return XCTestSuite(name: "Skipping \(className())")
        }
    }

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
        if configFile == nil {
            let temporaryConfig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("ghostty")
            configFile = temporaryConfig
        }
        try newConfig.write(to: configFile!, atomically: true, encoding: .utf8)
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
