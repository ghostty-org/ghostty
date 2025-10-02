//
//  GhosttyConfigTests.swift
//  Ghostty
//
//  Created by luca on 24.09.2025.
//

import Foundation
@testable import GhosttyKit
import Testing

@Suite(.serialized)
struct GhosttyConfigTests {
    init() throws {
        try #require(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS, "ghostty_init failed")
    }

    @Test
    func defaultValues() async throws {
        let defaultProvider = DefaultConfigProvider()

        // src/config/Config.zig
        let background = try #require(defaultProvider.getColor("background"))
        #expect(background.r == 0x28)
        #expect(background.g == 0x2C)
        #expect(background.b == 0x34)

        let foreground = try #require(defaultProvider.getColor("foreground"))
        #expect(foreground.r == 0xFF)
        #expect(foreground.g == 0xFF)
        #expect(foreground.b == 0xFF)
    }
}

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    if let _ = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
        return true
    }

    return false
}
