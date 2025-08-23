//
//  GhosttyTests.swift
//  GhosttyTests
//
//  Created by Mitchell Hashimoto on 7/9/25.
//

import Testing
import GhosttyKit

extension Tag {
    @Tag static var benchmark: Self
}

/// The whole idea behind these benchmarks is that they're run by right-clicking
/// in Xcode and using "Profile" to open them in instruments. They aren't meant to
/// be run in general.
///
/// When running them, set the `if:` to `true`. There's probably a better
/// programmatic way to do this but I don't know it yet!
@Suite(
    "Benchmarks",
    .enabled(if: false),
    .tags(.benchmark)
)
struct BenchmarkTests {
    @Test func example() async throws {
        ghostty_benchmark_cli(
            "terminal-stream",
            "--data=/Users/mitchellh/Documents/ghostty/bug.osc.txt")
    }
}
