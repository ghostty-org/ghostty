#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def test-plan [arguments: list<string>] {
    let planner = ($env.FILE_PWD | path join ".." "dist" "omg_test_plan.py")
    let python_runner = ($env.FILE_PWD | path join ".." "dist" "macos" "dev-tool.sh")
    let result = (^bash $python_runner python3 $planner ...$arguments | complete)
    if $result.exit_code != 0 {
        error make {msg: ($result.stderr | str trim)}
    }
    $result.stdout | from json
}

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --only-testing: string = ""         # Comma-separated suite/method identifiers
    --test-modules: string              # Comma-separated modules, or all (Swift tests only)
    --changed-since: string             # Git ref/commit; includes staged, unstaged, untracked changes
    --include-desktop-tests             # Opt in to foreground/unlocked native interaction tests
    --test-plan-only                    # Print the selection as JSON without building/running tests
    --list-test-modules                 # List modules and direct dependents without building
    --marketing-version: string         # Optional local build version override
    --workspace-app                    # Build the isolated OMG Dev Workspace app
    --pty-app                          # Build the isolated OMG Dev PTY app
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    if $workspace_app and $pty_app { error make {msg: "Select only one isolated app"} }
    let build_dir = ($env.FILE_PWD | path join (if $workspace_app { "build-workspace" } else if $pty_app { "build-pty" } else { "build" }))
    if ($workspace_app or $pty_app) and $configuration != "Debug" {
        error make {msg: "Isolated apps require Debug configuration"}
    }
    let workspace_settings = if $pty_app {
        ["PRODUCT_BUNDLE_IDENTIFIER=com.jischeng.omg.debug.pty"
         "INFOPLIST_KEY_CFBundleDisplayName=OMG Dev PTY"
         "INFOPLIST_KEY_CFBundleName=OMG Dev PTY"]
    } else if $workspace_app {
        ["PRODUCT_BUNDLE_IDENTIFIER=com.jischeng.omg.debug.workspace"
         "INFOPLIST_KEY_CFBundleDisplayName=OMG Dev Workspace"
         "INFOPLIST_KEY_CFBundleName=OMG Dev Workspace"]
    } else { [] }

    if $list_test_modules {
        print (test-plan [--list-modules] | to json)
        return
    }
    if $action != "test" and ($test_modules != null or $changed_since != null or $only_testing != "" or $include_desktop_tests or $test_plan_only) {
        error make {msg: "Test selection flags require --action test"}
    }
    let module_args = if $test_modules == null { [] } else { [--modules $test_modules] }
    let changed_args = if $changed_since == null { [] } else { [--changed-since $changed_since] }
    let only_args = if $only_testing == "" { [] } else { [--only-testing $only_testing] }
    let desktop_args = if $include_desktop_tests { [--include-desktop-tests] } else { [] }
    let plan = if $action == "test" {
        test-plan [...$module_args ...$changed_args ...$only_args ...$desktop_args]
    } else {
        {only_testing: [], skip_testing: []}
    }
    if $test_plan_only {
        print ($plan | to json)
        return
    }
    if $action == "test" {
        print $"Swift test scope: ($plan.scope); modules: ($plan.modules | str join ', '); suites: ($plan.suite_count)"
        if ($plan.full_suite_paths | is-not-empty) or ($plan.unknown_paths | is-not-empty) {
            print "Shared infrastructure or unmapped changes: conservatively selecting all regular Swift suites."
        }
        if ($plan.deferred_desktop | is-not-empty) {
            print ("NOT RUN (optional interactive desktop): " + ($plan.deferred_desktop | str join ', ') + ". Use --include-desktop-tests with an unlocked foreground desktop.")
        }
        if not $plan.run_swift {
            print "No Swift suites selected; xcodebuild was not executed. Run applicable documentation/script/core checks separately."
            return
        }
    }
    # XCUITest still needs a separate permissions-enabled workflow. Native desktop
    # tests inside GhosttyTests are independently optional, not XCUITest.
    let skip_testing = if $action == "test" {
        $plan.skip_testing | each {|test| ["-skip-testing" $test] } | flatten | append [-parallel-testing-enabled NO]
    } else {
        []
    }
    let version_override = if $marketing_version == null {
        []
    } else {
        [$"MARKETING_VERSION=($marketing_version)"]
    }
    let selected_tests = ($plan.only_testing | each {|test| ["-only-testing" $test] } | flatten)
    # Optimized configurations still need @testable imports for app-hosted
    # performance/regression tests. This does not change normal release builds.
    let test_build_settings = if $action == "test" {
        ["ENABLE_TESTABILITY=YES" "ONLY_ACTIVE_ARCH=YES"]
    } else { [] }

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
        ...$workspace_settings
        ...$skip_testing
        ...$selected_tests
        ...$test_build_settings
        $action)
}
