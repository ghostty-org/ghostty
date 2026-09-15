#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --only-testing: string = ""         # Comma-separated test identifiers, e.g. GhosttyTests/AgentIntegrationManagerTests
    --marketing-version: string         # Optional local build version override
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests -parallel-testing-enabled NO]
    } else {
        []
    }
    let version_override = if $marketing_version == null {
        []
    } else {
        [$"MARKETING_VERSION=($marketing_version)"]
    }
    let selected_tests = ($only_testing | split row "," | where {|test| $test != "" }
        | each {|test| ["-only-testing" $test] } | flatten)

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        # The editor packages' lint plugins declare an absent Output directory
        # under Xcode 26. Keep OMG's own Run SwiftLint phase as the lint gate.
        "DISABLE_SWIFTLINT=1"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        -skipPackagePluginValidation
        $"SYMROOT=($build_dir)"
        ...$version_override
        ...$skip_testing
        ...$selected_tests
        $action)
}
