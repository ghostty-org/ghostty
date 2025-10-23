//
//  ConfigFileTests.swift
//  Ghostty
//
//  Created by luca on 23.10.2025.
//

@testable import Ghostty
import GhosttyKit
import Testing

class ConfigFileTests: ConfigFileTestSuite {
    @Test func configFileSaving() async throws {
        #expect(config.fontSize == 13)
    }
}
