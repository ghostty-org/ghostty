import XCTest
@testable import Ghostty

/// Behavior tests for `TaskFileWatcher`. These exercise `DispatchSource`
/// vnode events and are inherently timing-sensitive — timeouts are set
/// generously for CI runners that may be loaded.
final class TaskFileWatcherTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ghostties-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func writeFile(_ name: String, contents: String = "x") throws {
        try contents.write(to: tmp.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
    }

    /// Await the next `onChange` fire. TaskFileWatcher always fires once on
    /// attach, so most tests skip that initial fire before the real assertion.
    private func makeWatcher(
        debounce: DispatchTimeInterval = .milliseconds(100)
    ) -> (TaskFileWatcher, () -> Int) {
        var count = 0
        let lock = NSLock()
        let watcher = TaskFileWatcher(url: tmp, debounceInterval: debounce) {
            lock.lock()
            count += 1
            lock.unlock()
        }
        return (watcher, { lock.lock(); defer { lock.unlock() }; return count })
    }

    /// Spin the main runloop until `condition` returns true or `timeout` passes.
    /// Watcher fires onto `DispatchQueue.main.async`, so we must let the main
    /// loop process events.
    @discardableResult
    private func waitForCondition(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: - Tests

    func testAttachFiresInitialCallback() throws {
        let (watcher, getCount) = makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        XCTAssertTrue(waitForCondition(timeout: 2.0) { getCount() >= 1 },
                      "watcher should fire once on attach; count=\(getCount())")
    }

    func testNewFileFiresReload() throws {
        let (watcher, getCount) = makeWatcher()
        watcher.start()
        defer { watcher.stop() }

        // Swallow the on-attach fire.
        _ = waitForCondition(timeout: 2.0) { getCount() >= 1 }
        let before = getCount()

        try writeFile("new-file.md")
        XCTAssertTrue(waitForCondition(timeout: 2.0) { getCount() > before },
                      "expected watcher to fire after new file write; count=\(getCount())")
    }

    func testModifyExistingFileFiresReload() throws {
        // Create file up front so its creation isn't what triggers us.
        try writeFile("existing.md", contents: "v1")

        let (watcher, getCount) = makeWatcher()
        watcher.start()
        defer { watcher.stop() }
        _ = waitForCondition(timeout: 2.0) { getCount() >= 1 }
        let before = getCount()

        try writeFile("existing.md", contents: "v2-modified")
        XCTAssertTrue(waitForCondition(timeout: 2.0) { getCount() > before },
                      "expected watcher to fire after modify; count=\(getCount())")
    }

    func testDeleteFileFiresReload() throws {
        try writeFile("todelete.md")

        let (watcher, getCount) = makeWatcher()
        watcher.start()
        defer { watcher.stop() }
        _ = waitForCondition(timeout: 2.0) { getCount() >= 1 }
        let before = getCount()

        try FileManager.default.removeItem(at: tmp.appendingPathComponent("todelete.md"))
        XCTAssertTrue(waitForCondition(timeout: 2.0) { getCount() > before },
                      "expected watcher to fire after delete; count=\(getCount())")
    }

    func testDirectoryRecreateRecoversWatcher() throws {
        let (watcher, getCount) = makeWatcher()
        watcher.start()
        defer { watcher.stop() }
        _ = waitForCondition(timeout: 2.0) { getCount() >= 1 }
        let before = getCount()

        // Remove + recreate the directory. The watcher's retry loop should
        // reattach, fire its on-attach callback, and fire again on the
        // subsequent write.
        try FileManager.default.removeItem(at: tmp)
        // Give the watcher a moment to notice.
        _ = waitForCondition(timeout: 1.0) { false }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        XCTAssertTrue(waitForCondition(timeout: 5.0) { getCount() > before },
                      "watcher should reattach within 5s after dir recreate; count=\(getCount())")

        let afterRecreate = getCount()
        try writeFile("after-recreate.md")
        XCTAssertTrue(waitForCondition(timeout: 3.0) { getCount() > afterRecreate },
                      "reattached watcher should fire on subsequent writes")
    }

    func testBurstOfWritesDebouncesToOneFire() throws {
        // Use a longer debounce so the burst clearly falls inside one window.
        let (watcher, getCount) = makeWatcher(debounce: .milliseconds(300))
        watcher.start()
        defer { watcher.stop() }
        _ = waitForCondition(timeout: 2.0) { getCount() >= 1 }
        let before = getCount()

        // 5 writes back-to-back.
        for i in 0..<5 {
            try writeFile("burst-\(i).md")
        }

        // Wait past the debounce window plus slack.
        _ = waitForCondition(timeout: 1.5) { false }

        let after = getCount()
        let fired = after - before
        XCTAssertEqual(fired, 1,
                       "burst of 5 writes should debounce to ONE fire, got \(fired)")
    }
}
