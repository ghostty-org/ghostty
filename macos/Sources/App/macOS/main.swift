import AppKit
import Cocoa
import GhosttyKit

// Detect XCTest hosting. When the process is launched as the host for an
// XCTest bundle, the `XCTestConfigurationFilePath` env var is set by the
// test runner before main runs. We must skip `ghostty_init` and
// `ghostty_cli_try_action` in that case — both do heavy / blocking work
// (loading the global config, parsing CLI flags, hitting libghostty
// internals) that delays NSApplicationMain long enough for xcodebuild
// to time out with "test runner hung before establishing connection" on
// headless GitHub Actions runners (~6 minutes before failure).
//
// AppDelegate has a matching guard (`isRunningUnderXCTest`) plus lazy
// initialization for `ghostty` / `updateController`, so the delegate's
// launch hooks short-circuit and the heavy properties are never touched
// under XCTest. NSApplicationMain still runs so XCTest can establish its
// connection and load the test bundle.
let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

if !isRunningUnderXCTest {
    // Initialize Ghostty global state. We do this once right away because the
    // CLI APIs require it and it lets us ensure it is done immediately for the
    // rest of the app.
    if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
        Ghostty.logger.critical("ghostty_init failed")

        // We also write to stderr if this is executed from the CLI or zig run
        switch Ghostty.launchSource {
        case .cli, .zig_run:
            let stderrHandle = FileHandle.standardError
            stderrHandle.write(
                "Ghostties failed to initialize! If you're executing Ghostties from the command line\n" +
                "then this is usually because an invalid action or multiple actions were specified.\n" +
                "Actions start with the `+` character.\n\n" +
                "View all available actions by running `ghostty +help`.\n")
            exit(1)

        case .app:
            // For the app we exit immediately. We should handle this case more
            // gracefully in the future.
            exit(1)
        }
    }

    // This will run the CLI action and exit if one was specified. A CLI
    // action is a command starting with a `+`, such as `ghostty +boo`.
    ghostty_cli_try_action()
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
