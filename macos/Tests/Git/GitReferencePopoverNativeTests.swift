import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitReferencePopoverNativeTests {
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test func referenceListUsesNativeSearchModeAndReusableRows() async throws {
        let refs = [
            GitRefDecoration(name: "main", kind: .currentBranch),
            GitRefDecoration(name: "release/2026", kind: .tag),
        ]
        var closed = false
        let pasteboard = NSPasteboard.withUniqueName()
        let controller = GitReferenceListPopoverController(
            refs: refs, selected: refs[1], state: GitCollectionState(),
            colors: GitCollectionColors(), pasteboard: pasteboard, close: { closed = true }
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: GitRefPopoverStyle.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        try await Task.sleep(for: .milliseconds(60))

        let table = try #require(find(GitCollectionTableView.self, in: controller.view).first)
        #expect(find(NSHostingView<AnyView>.self, in: controller.view).isEmpty)
        #expect(find(NSSearchField.self, in: controller.view).count == 1)
        #expect(controller.searchFieldForTesting.cell is GitSearchFieldCell)
        #expect(controller.searchFieldForTesting.focusRingType == .none)
        #expect(controller.view.layer?.backgroundColor != nil)
        #expect(find(GitPopoverSegments.self, in: controller.view).count == 1)
        let modes = try #require(find(GitPopoverSegments.self, in: controller.view).first)
        for button in modes.buttonsForTesting {
            #expect(!button.isBordered)
            #expect(abs(button.bounds.height - 24) < 1)
        }
        #expect(table.visibleRect.height > 200)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        let row = try #require(coordinator.rows.firstIndex { row in
            if case .ref(let ref) = row.item.kind { return ref.name == "release/2026" }
            return false
        })
        coordinator.activate(row: row)
        #expect(pasteboard.string(forType: .string) == "release/2026")
        #expect(controller.copiedLabelForTesting.stringValue == GitL10n.text("Copied"))
        #expect(controller.control(controller.searchFieldForTesting, textView: NSTextView(),
                                   doCommandBy: NSSelectorFromString("cancelOperation:")))
        #expect(closed)
    }
}
