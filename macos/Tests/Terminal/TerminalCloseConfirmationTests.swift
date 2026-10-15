import AppKit
import XCTest
@testable import Ghostty

final class TerminalCloseConfirmationTests: XCTestCase {
    @MainActor
    func testExistingConfirmationDoesNotClose() async throws {
        try await checkClose(response: nil, shouldClose: false)
    }

    @MainActor
    func testCancelDoesNotClose() async throws {
        try await checkClose(response: .alertSecondButtonReturn, shouldClose: false)
    }

    @MainActor
    func testConfirmCloses() async throws {
        try await checkClose(response: .alertFirstButtonReturn, shouldClose: true)
    }

    @MainActor
    private func checkClose(response: NSApplication.ModalResponse?, shouldClose: Bool) async throws {
        let config = try TemporaryConfig("window-save-state = never")
        let ghostty = Ghostty.App(configPath: config.temporaryFile.path)
        let requested = expectation(description: "Confirmation requested")
        let closed = expectation(description: "Terminal closed")
        closed.isInverted = !shouldClose

        let controller = ConfirmationController(ghostty, surfaceTree: .init())
        controller.response = response
        controller.onConfirmation = { requested.fulfill() }
        controller.confirmClose(messageText: "Close Tab?", informativeText: "Running process") {
            closed.fulfill()
        }

        await fulfillment(of: [requested, closed], timeout: 1)
    }
}

private final class ConfirmationController: BaseTerminalController {
    var response: NSApplication.ModalResponse?
    var onConfirmation: (() -> Void)?

    override func confirmCloseAsync(
        messageText: String,
        informativeText: String,
        confirmButtonTitle: String = "Close"
    ) async -> NSApplication.ModalResponse? {
        onConfirmation?()
        return response
    }
}
