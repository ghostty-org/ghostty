import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized) @MainActor
struct SessionRuntimeOverviewTests {
    private func report(error: Bool = false) throws -> SessionRuntimeOverviewReport {
        let failures = error ? #"{"host":"offline","message":"unavailable"}"# : ""
        return try JSONDecoder().decode(SessionRuntimeOverviewReport.self, from: Data("""
        {"sessions":[{"endpoint_id":"fixture","host":"This Mac","revision":"old",
        "id":"11111111-1111-4111-8111-111111111111","generation":"generation",
        "created_at":1,"updated_at":2,"pid":42,"ended":null,"resume":null,"cwd":"/tmp"}],
        "errors":[\(failures)],"closed":0}
        """.utf8))
    }
    @Test func incompleteInventoryDisablesBulkCloseAndCompleteInventoryRefreshesAfterClose() async throws {
        var closes = 0
        var incomplete = true
        let model = SessionRuntimeOverviewModel { close in
            if close { closes += 1 }
            return try report(error: incomplete)
        }
        model.refresh()
        try await waitForAppKit { !model.busy }
        #expect(model.runningCount == 1 && !model.canCloseAll)
        model.closeAll()
        #expect(closes == 0)
        incomplete = false
        model.refresh()
        try await waitForAppKit { !model.busy }
        #expect(model.canCloseAll)
        model.closeAll()
        try await waitForAppKit { !model.busy }
        #expect(closes == 1)
    }
    @Test func cancelledRefreshDoesNotPublishLateInventory() async throws {
        let model = SessionRuntimeOverviewModel { _ in
            try? await Task.sleep(for: .milliseconds(50))
            return try report()
        }
        model.refresh()
        model.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!model.busy && model.report.sessions.isEmpty)
    }
}
