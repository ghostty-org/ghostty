import AppKit
import Testing
@testable import Ghostty

@MainActor
struct GitCommitAISettingsNativeTests {
    @Test func routeDragKeepsStableIdentityAndUsesTheProposedInsertionIndex() {
        let first = GitCommitAIRoute(agent: .claude, model: "first")
        let second = GitCommitAIRoute(agent: .pi, model: "second")
        let third = GitCommitAIRoute(agent: .codex, model: "third")
        let routes = [first, second, third]

        #expect(GitCommitAIRoutesTable.Coordinator.moved(routes, routeID: first.id, toInsertionRow: 3)
                == [second, third, first])
        #expect(GitCommitAIRoutesTable.Coordinator.moved(routes, routeID: third.id, toInsertionRow: 0)
                == [third, first, second])
        #expect(GitCommitAIRoutesTable.Coordinator.moved(routes, routeID: second.id, toInsertionRow: 2)
                == routes)
    }

    @Test func promptEditorOwnsNativeTextViewAndFitsItsPanel() throws {
        var savedPrompt: String?
        let controller = GitCommitAIPromptController(prompt: "Use concise commit messages.") {
            savedPrompt = $0
        }
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        root.layoutSubtreeIfNeeded()

        #expect(controller.promptView.string == "Use concise commit messages.")
        #expect(controller.promptView.isRichText == false)
        #expect(controller.promptView.textContainer?.widthTracksTextView == true)
        #expect(controller.promptView.frame.width >= 500)
        let scroll = try #require(controller.promptView.enclosingScrollView)
        #expect(scroll.contentSize.height >= 240)
        #expect(controller.promptView.frame.height >= scroll.contentSize.height)
        #expect(controller.saveButton.isEnabled)

        controller.promptView.string = "Write a short summary.\nAdd useful context."
        controller.textDidChange(Notification(name: NSText.didChangeNotification,
                                              object: controller.promptView))
        #expect(controller.saveButton.target === controller)
        #expect(controller.saveButton.action != nil)
        #expect(savedPrompt == nil)
    }

    @Test func addModelsPanelUsesNativePickerSearchAndTableWithoutStartingNetworkWork() {
        let controller = GitCommitAIAddModelsController { _, _ in }
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        root.layoutSubtreeIfNeeded()

        func containsHostingView(_ view: NSView) -> Bool {
            if String(describing: type(of: view)).contains("NSHostingView") { return true }
            return view.subviews.contains(where: containsHostingView)
        }

        #expect(!containsHostingView(root))
        #expect(root.subviews.contains { $0 is NSStackView })
        #expect(root.findViews(of: NSPopUpButton.self).contains { $0.numberOfItems == GitCommitAgent.allCases.count })
        #expect(root.findViews(of: NSSearchField.self).count == 1)
        #expect(root.findViews(of: NSTableView.self).contains { $0.numberOfColumns == 1 })
    }
}

private extension NSView {
    func findViews<T: NSView>(of type: T.Type) -> [T] {
        (self as? T).map { [$0] } ?? subviews.flatMap { $0.findViews(of: type) }
    }
}
