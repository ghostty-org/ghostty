//
//  CommandPaletteTests.swift
//  GhosttyTests
//
//  Tests for command palette query filtering and match ranking.
//

import Testing
import SwiftUI
@testable import Ghostty

struct CommandPaletteFilterTests {
    private func option(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        leadingColor: Color? = nil,
        sortKey: ObjectIdentifier? = nil
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            description: description,
            leadingColor: leadingColor,
            sortKey: sortKey
        ) {}
    }

    /// Title matches outrank subtitle matches, which outrank description
    /// matches. Options that don't match at all are dropped.
    @Test func textMatchTiers() {
        let byDescription = option(title: "Alpha", description: "make it fast")
        let bySubtitle = option(title: "Beta", subtitle: "fast scrolling")
        let byTitle = option(title: "Fast Redraw")
        let noMatch = option(title: "Quit")

        let results = [noMatch, byDescription, bySubtitle, byTitle]
            .filteredAndSorted(query: "fast")

        #expect(results == [byTitle, bySubtitle, byDescription])
    }

    /// Options with equal scores keep their original relative order.
    @Test func tiesPreserveOriginalOrder() {
        let first = option(title: "New Window")
        let second = option(title: "New Tab")

        #expect([first, second].filteredAndSorted(query: "new") == [first, second])
        #expect([second, first].filteredAndSorted(query: "new") == [second, first])
    }

    /// Equal titles use their sort keys independent of input order.
    @Test func equalTitlesUseSortKey() {
        let firstKey = NSObject()
        let secondKey = NSObject()
        let first = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(firstKey)
        )
        let second = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(secondKey)
        )

        let forward = sortedTerminalPaletteOptions([first, second])
        let reverse = sortedTerminalPaletteOptions([second, first])
        #expect(forward == reverse)
    }
}

@MainActor
struct CommandPaletteNativeTests {
    @Test func filteringClampsSelectionAndNavigationWraps() {
        let controller = CommandPaletteController()
        controller.update(options: [CommandOption(title: "New Window") {}, CommandOption(title: "Quit") {}]) { _ in }
        _ = controller.view
        #expect(controller.tableView.selectedRow == -1)
        controller.moveSelection(by: -1)
        #expect(controller.tableView.selectedRow == 1)
        controller.moveSelection(by: 1)
        #expect(controller.tableView.selectedRow == 0)
        controller.searchField.stringValue = "quit"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(controller.results.map(\.title) == ["Quit"])
        #expect(controller.tableView.selectedRow == 0)
        controller.searchField.stringValue = "no match"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.moveSelection(by: 1)
        #expect(controller.tableView.selectedRow == -1)
    }

    @Test func compositionOwnsReturnEscapeAndArrows() {
        let controller = CommandPaletteController()
        var completions = 0
        controller.update(options: [CommandOption(title: "Quit") {}]) { _ in completions += 1 }
        _ = controller.view
        let editor = PaletteMarkedTextView()
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                         #selector(NSResponder.moveDown(_:))] {
            #expect(!controller.control(controller.searchField, textView: editor, doCommandBy: selector))
        }
        #expect(completions == 0)
        #expect(controller.tableView.selectedRow == -1)
    }

    @Test func updateReplacesActionWithoutResettingSelection() {
        let controller = CommandPaletteController()
        var actionVersion = 0
        var completions = 0
        let finish: (CommandOption?) -> Void = { option in completions += 1; option?.action() }
        controller.update(options: [CommandOption(title: "Open") { actionVersion = 1 }], finish: finish)
        _ = controller.view
        controller.moveSelection(by: 1)
        controller.update(options: [CommandOption(title: "Open") { actionVersion = 2 }], finish: finish)
        #expect(controller.tableView.selectedRow == 0)
        let editor = NSTextView()
        for _ in 0..<2 {
            #expect(controller.control(controller.searchField, textView: editor,
                                       doCommandBy: #selector(NSResponder.insertNewline(_:))))
        }
        #expect(actionVersion == 2)
        #expect(completions == 1)
    }
}

private final class PaletteMarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
