import XCTest

/// Smoke test for the task-first sidebar (Concept F, v0).
///
/// Validates the single highest-value path XCUITest can cover that unit tests
/// cannot: the app launches cleanly, the ⌘⇧V toggle reaches the Task sidebar
/// view, the three zone headers render without crashing, and the toggle can
/// be driven on/off/on without tearing the view tree.
///
/// Intentionally narrow — broad UI coverage with fragile selectors flakes;
/// narrow coverage on robust selectors gets trusted.
///
/// ## Run policy
///
/// Gated behind `IDE_DISABLED_OS_ACTIVITY_DT_MODE` (same mechanism the upstream
/// `GhosttyCustomConfigCase` uses) so the test runs from the Xcode IDE but
/// stays inert under plain `xcodebuild test` CLI invocations. XCUITest in CLI
/// mode can't attach to the app runner reliably on this machine while
/// `/Applications/Ghostties.app` and the Debug build share bundle ID
/// `com.mitchellh.ghostty` (Fragile Area #1 in ORCHESTRATOR.md — parked in
/// `parked-dev-environments-and-dmg.md`). Once that's resolved the guard can
/// be removed and the test wired into CI.
///
/// To run locally from Xcode: ⌘U on the Ghostties scheme, or right-click the
/// test method in the gutter.
final class TaskSidebarSmokeUITests: XCTestCase {
    override static var defaultTestSuite: XCTestSuite {
        // Same guard `GhosttyCustomConfigCase` uses: Xcode IDE launches set
        // IDE_DISABLED_OS_ACTIVITY_DT_MODE, CLI-driven xcodebuild invocations
        // do not. See https://lldb.llvm.org/cpp_reference/PlatformDarwin_8cpp_source.html
        if ProcessInfo.processInfo.environment["IDE_DISABLED_OS_ACTIVITY_DT_MODE"] != nil {
            return XCTestSuite(forTestCaseClass: Self.self)
        } else {
            return XCTestSuite(name: "Skipping \(className()) — run from Xcode IDE")
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndTaskSidebarTogglesWithoutCrash() throws {
        let app = XCUIApplication()

        // Pin the starting sidebar mode to project-first so ⌘⇧V deterministically
        // flips into task-first regardless of the user's saved UserDefaults. The
        // "-key value" launch-argument pair is the standard NSUserDefaults
        // override mechanism on macOS.
        app.launchArguments.append(contentsOf: [
            "-ApplePersistenceIgnoreState", "YES",
            "-ghostties.sidebarViewMode", "projectFirst",
            "--uitest-task-sidebar-smoke",
        ])
        app.launch()

        // First launch on a fresh build can be slow (codesign, Gatekeeper).
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 10),
            "Main window should exist after app launch"
        )

        // Toggle into the task-first sidebar via ⌘⇧V.
        app.typeKey("v", modifierFlags: [.command, .shift])

        // The three zone headers are rendered via `Text("Needs you".uppercased())`
        // etc., so XCUITest exposes them as `staticTexts`.
        XCTAssertTrue(
            app.staticTexts["NEEDS YOU"].waitForExistence(timeout: 5),
            "NEEDS YOU zone header should appear after toggling task sidebar"
        )
        XCTAssertTrue(
            app.staticTexts["ACTIVE"].exists,
            "ACTIVE zone header should exist alongside NEEDS YOU"
        )
        XCTAssertTrue(
            app.staticTexts["GRAVEYARD"].exists,
            "GRAVEYARD zone header should exist alongside NEEDS YOU"
        )

        // Toggle back out — no crash tolerated.
        app.typeKey("v", modifierFlags: [.command, .shift])

        // Toggle back in — the sidebar must rehydrate cleanly.
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            app.staticTexts["NEEDS YOU"].waitForExistence(timeout: 5),
            "NEEDS YOU header should rehydrate after a second toggle"
        )
    }
}
