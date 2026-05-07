import ArgumentParser
import Foundation
import GhosttiesCore

struct SmokeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke",
        abstract: "Offline self-check: create, verify, and clean up a temp task file. No app or Linear required."
    )

    func run() throws {
        // 1. Locate tasks directory
        let dir: URL
        do {
            dir = try TasksDirectory.require()
        } catch {
            print("FAIL: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let store = TaskStore(directory: dir)
        let uuid = UUID().uuidString
        let smokeId = "ghostties-smoke-\(uuid)"
        let title = "Smoke test \(uuid)"

        // 2. Create temp task file with minimal valid frontmatter
        let pairs: [(String, String)] = [
            ("id", smokeId),
            ("title", title),
            ("status", TaskLane.inbox.rawValue)
        ]
        let tempURL: URL
        do {
            tempURL = try store.create(id: smokeId, pairs: pairs, body: "")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Ensure cleanup happens even on early exit
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // 3. Assert task appears in loaded store
        let tasksAfterCreate = store.loadAll()
        guard tasksAfterCreate.contains(where: { $0.id == smokeId }) else {
            print("FAIL: task not found after create")
            throw ExitCode.failure
        }

        // 4. Mark done by rewriting frontmatter status
        do {
            let freshTask = store.loadFile(at: tempURL)!
            var updatedPairs = Frontmatter.set("status", TaskLane.done.rawValue, in: freshTask.frontmatter)
            let nowISO = isoFormatter.string(from: Date())
            updatedPairs = Frontmatter.set("completed", nowISO, in: updatedPairs)
            try store.write(pairs: updatedPairs, body: freshTask.body, to: tempURL)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 5. Reload and assert task is NOT in running or inbox lanes
        let tasksAfterDone = store.loadAll()
        let stillActive = tasksAfterDone.first(where: {
            $0.id == smokeId && ($0.lane == .running || $0.lane == .inbox)
        })
        if stillActive != nil {
            print("FAIL: task still active after done")
            throw ExitCode.failure
        }

        // 6. Cleanup happens via defer above

        print("OK — smoke passed")
    }
}
