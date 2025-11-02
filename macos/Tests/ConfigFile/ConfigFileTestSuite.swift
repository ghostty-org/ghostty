//
//  ConfigFileTestSuite.swift
//  Ghostty
//
//  Created by luca on 23.10.2025.
//

@testable import Ghostty

@MainActor
class ConfigFileTestSuite {
    let randomFile: URL
    let config: Ghostty.ConfigFile
    init() {
        randomFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        config = Ghostty.ConfigFile(configFile: randomFile, persistProvider: nil)
    }

    deinit {
        try? FileManager.default.removeItem(at: randomFile)
    }
}
