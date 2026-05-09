import XCTest
@testable import Ghostty

/// Tests for the recents-list sorting logic in RecentsListView.
///
/// Exercises the static `sorted(sessions:)` helper and `relativeLabel(_:)`
/// — both are pure functions with no SwiftUI or AppKit dependencies.
final class RecentsListViewTests: XCTestCase {

    // MARK: - Helpers

    private func session(
        name: String,
        lastActiveAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            name: name,
            templateId: UUID(),
            projectId: UUID(),
            lastActiveAt: lastActiveAt
        )
    }

    // MARK: - Sorting

    func testSortsByLastActiveAtDescending() {
        let early = session(name: "early", lastActiveAt: Date(timeIntervalSinceNow: -3600))
        let middle = session(name: "middle", lastActiveAt: Date(timeIntervalSinceNow: -1800))
        let recent = session(name: "recent", lastActiveAt: Date(timeIntervalSinceNow: -60))

        let sorted = RecentsListView.sorted(sessions: [early, recent, middle])

        XCTAssertEqual(sorted.map(\.name), ["recent", "middle", "early"])
    }

    func testNilLastActiveAtSinksToBottom() {
        let withDate = session(name: "withDate", lastActiveAt: Date(timeIntervalSinceNow: -300))
        let noDate1 = session(name: "noDate1", lastActiveAt: nil)
        let noDate2 = session(name: "noDate2", lastActiveAt: nil)

        let sorted = RecentsListView.sorted(sessions: [noDate1, withDate, noDate2])

        // withDate must be first; the two nil-date sessions can be in any order after.
        XCTAssertEqual(sorted.first?.name, "withDate")
        let tailNames = Set(sorted.dropFirst().map(\.name))
        XCTAssertEqual(tailNames, ["noDate1", "noDate2"])
    }

    func testEmptySessionListReturnsEmpty() {
        let sorted = RecentsListView.sorted(sessions: [])
        XCTAssertTrue(sorted.isEmpty)
    }

    func testSingleSessionReturnedUnchanged() {
        let s = session(name: "only", lastActiveAt: Date())
        let sorted = RecentsListView.sorted(sessions: [s])
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted.first?.name, "only")
    }

    func testAllNilTimestampsPreservesCount() {
        let sessions = (0..<5).map { session(name: "s\($0)", lastActiveAt: nil) }
        let sorted = RecentsListView.sorted(sessions: sessions)
        XCTAssertEqual(sorted.count, 5)
    }

    // MARK: - Relative Time Labels

    func testRelativeLabelJustNow() {
        let date = Date(timeIntervalSinceNow: -10)
        XCTAssertEqual(RecentsRowView.relativeLabel(date), "just now")
    }

    func testRelativeLabelMinutes() {
        let date = Date(timeIntervalSinceNow: -120) // 2 minutes ago
        XCTAssertEqual(RecentsRowView.relativeLabel(date), "2m")
    }

    func testRelativeLabelHours() {
        let date = Date(timeIntervalSinceNow: -7200) // 2 hours ago
        XCTAssertEqual(RecentsRowView.relativeLabel(date), "2h")
    }

    func testRelativeLabelDayAbbreviation() {
        // 2 days ago — formatter uses en_US_POSIX locale so output is always 3-char English
        let date = Date(timeIntervalSinceNow: -172800)
        let label = RecentsRowView.relativeLabel(date)
        let validAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        XCTAssertTrue(validAbbreviations.contains(label),
            "Day abbreviation '\(label)' should be an English 3-char weekday")
    }

    func testRelativeLabelOldDate() {
        // 10 days ago — should use "MMM d" format (en_US_POSIX, e.g. "May 1")
        let date = Date(timeIntervalSinceNow: -864000)
        let label = RecentsRowView.relativeLabel(date)
        // Contains a space between month abbreviation and day number
        XCTAssertTrue(label.contains(" "), "Old date label '\(label)' should be 'MMM d' format")
    }
}
