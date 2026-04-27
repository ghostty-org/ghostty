// IDE-ONLY: not currently exercised in CI macos job (build-only).
// Run via Xcode Cmd+U or xcodebuild test locally.
// See .github/workflows/test-ghostties.yml — macos-app job is build-only due to
// XCTest host app hang in headless GH Actions runners.
import XCTest
@testable import Ghostty
import GhosttiesCore

/// Static-assertion tests that the macOS type bridge to GhosttiesCore stays in
/// sync. These tests will catch future drift between:
///   - macOS `TaskStatus` raw values and `GhosttiesCore.TaskLane` raw values
///   - macOS `TaskPriority` (a typealias of `GhosttiesCore.TaskPriority`) raw values
///
/// Per ADV-007 in the U2 spec: raw values must stay in sync across all three
/// surfaces (CLI, MCP, macOS). The TypeAlias for `TaskPriority` makes the
/// compiler enforce priority sync automatically; this test catches `TaskStatus`
/// drift since `TaskLane` is not `Codable` and can't be a direct typealias.
final class TaskTypeBridgeTests: XCTestCase {

    // MARK: - TaskStatus ↔ GhosttiesCore.TaskLane bridge

    /// Every macOS `TaskStatus` raw value must exist in `GhosttiesCore.TaskLane`.
    /// If this test fails, a new case was added to one enum without updating
    /// the other — the frontmatter round-trip will break silently on disk.
    func testTaskStatusIsSubsetOfTaskLane() {
        let macosRaws = Set(TaskStatus.allCases.map { $0.rawValue })
        let coreRaws = Set(GhosttiesCore.TaskLane.allCases.map { $0.rawValue })
        XCTAssertTrue(
            macosRaws.isSubset(of: coreRaws),
            "macOS TaskStatus drifted from GhosttiesCore.TaskLane: \(macosRaws.subtracting(coreRaws))"
        )
    }

    /// Spot-check the six known lanes so any raw-value rename is caught
    /// immediately rather than failing only when a real file is parsed.
    func testTaskStatusRawValuesMatchExpectedStrings() {
        XCTAssertEqual(TaskStatus.inbox.rawValue,   "inbox")
        XCTAssertEqual(TaskStatus.backlog.rawValue, "backlog")
        XCTAssertEqual(TaskStatus.running.rawValue, "running")
        XCTAssertEqual(TaskStatus.needsYou.rawValue, "needs-you")
        XCTAssertEqual(TaskStatus.review.rawValue,  "review")
        XCTAssertEqual(TaskStatus.done.rawValue,    "done")
    }

    // MARK: - TaskPriority ↔ GhosttiesCore.TaskPriority (typealias)

    /// `TaskPriority` IS `GhosttiesCore.TaskPriority` (typealias), so raw value
    /// identity is guaranteed by the compiler. This test is belt-and-suspenders:
    /// it verifies the known cases and catches any mis-application of the alias.
    func testTaskPriorityRawValuesMatchExpectedStrings() {
        XCTAssertEqual(TaskPriority.high.rawValue,   "high")
        XCTAssertEqual(TaskPriority.medium.rawValue, "medium")
        XCTAssertEqual(TaskPriority.low.rawValue,    "low")
        XCTAssertEqual(TaskPriority.none.rawValue,   "none")
    }

    /// Confirm that `TaskPriority` and `GhosttiesCore.TaskPriority` are the
    /// same type (not just structurally equivalent). A failed assignment here
    /// means the typealias was accidentally removed and replaced by a distinct
    /// enum, breaking the bridge.
    func testTaskPriorityIsTypealiasOfCoreTaskPriority() {
        // If TaskPriority is a typealias of GhosttiesCore.TaskPriority, this
        // assignment compiles without any conversion. If it fails to compile,
        // the typealias has been broken.
        let coreValue: GhosttiesCore.TaskPriority = .high
        let macosValue: TaskPriority = coreValue          // must compile as-is
        XCTAssertEqual(macosValue, .high)
    }
}
