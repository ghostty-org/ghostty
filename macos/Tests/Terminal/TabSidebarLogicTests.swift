import Foundation
import Testing
@testable import Ghostty

struct TabSidebarLogicTests {
    // MARK: abbreviatePath

    @Test(arguments: [
        ("/Users/bob", "~"),
        ("/Users/bob/", "~"),
        ("/Users/bob/src/ghostty", "~/src/ghostty"),
        ("/Users/bobby", "/Users/bobby"),
        ("/Users/bobby/src", "/Users/bobby/src"),
        ("/tmp", "/tmp"),
        ("/", "/"),
    ])
    func abbreviatePath(path: String, expected: String) {
        #expect(TabSidebarLogic.abbreviatePath(path, home: "/Users/bob") == expected)
    }

    @Test func abbreviatePathHomeWithTrailingSlash() {
        #expect(TabSidebarLogic.abbreviatePath("/Users/bob/x", home: "/Users/bob/") == "~/x")
    }

    @Test func abbreviatePathEmpty() {
        #expect(TabSidebarLogic.abbreviatePath(nil, home: "/Users/bob") == nil)
        #expect(TabSidebarLogic.abbreviatePath("", home: "/Users/bob") == nil)
    }

    @Test func abbreviatePathRootHome() {
        #expect(TabSidebarLogic.abbreviatePath("/x", home: "/") == "/x")
    }

    // MARK: rowText

    @Test(arguments: [
        ("~/src/app", "app", "~/src/app"),
        ("/Users/bob/src/app", "app", "~/src/app"),
        ("…/src/app", "app", "~/src/app"),
        ("🔔 ~/src/app", "🔔 app", "~/src/app"),
        ("vim main.c", "vim main.c", "~/src/app"),
    ])
    func rowText(title: String, expectedTitle: String, expectedSubtitle: String) {
        let text = TabSidebarLogic.rowText(title: title, isOverride: false, pwd: "/Users/bob/src/app", home: "/Users/bob")
        #expect(text.title == expectedTitle)
        #expect(text.subtitle == expectedSubtitle)
    }

    @Test func rowTextKeepsOverrideAndHidesDuplicates() {
        let renamed = TabSidebarLogic.rowText(title: "~/src/app", isOverride: true, pwd: "/Users/bob/src/app", home: "/Users/bob")
        #expect(renamed.title == "~/src/app")
        #expect(renamed.subtitle == nil)

        let home = TabSidebarLogic.rowText(title: "~", isOverride: false, pwd: "/Users/bob", home: "/Users/bob")
        #expect(home.title == "~")
        #expect(home.subtitle == nil)

        let noPwd = TabSidebarLogic.rowText(title: "zsh", isOverride: false, pwd: nil, home: "/Users/bob")
        #expect(noPwd.title == "zsh")
        #expect(noPwd.subtitle == nil)
    }

    // MARK: Agents

    @Test func detectAgent() {
        #expect(TabSidebarAgent.detect(path: "/Users/bob/.local/share/claude/versions/2.0.14", arguments: ["claude"]) == .claude)
        #expect(TabSidebarAgent.detect(path: "/usr/local/bin/node", arguments: ["node", "/usr/local/bin/claude"]) == .claude)
        #expect(TabSidebarAgent.detect(path: "/opt/homebrew/bin/codex", arguments: ["codex"]) == .codex)
        #expect(TabSidebarAgent.detect(path: "/usr/local/bin/npx", arguments: ["npx", "@google/gemini-cli"]) == .gemini)
        #expect(TabSidebarAgent.detect(path: "/bin/cat", arguments: ["cat", "claude"]) == nil)
        #expect(TabSidebarAgent.detect(path: "/bin/zsh", arguments: ["-zsh"]) == nil)
    }

    // MARK: Width

    @Test func clampStoredWidth() {
        #expect(TabSidebarLogic.clampStoredWidth(10) == TabSidebarLogic.minWidth)
        #expect(TabSidebarLogic.clampStoredWidth(10_000) == TabSidebarLogic.maxWidth)
        #expect(TabSidebarLogic.clampStoredWidth(300) == 300)
        #expect(TabSidebarLogic.clampStoredWidth(.nan) == TabSidebarLogic.defaultWidth)
        #expect(TabSidebarLogic.clampStoredWidth(.infinity) == TabSidebarLogic.defaultWidth)
    }

    @Test func effectiveWidthHidden() {
        #expect(TabSidebarLogic.effectiveWidth(stored: 300, containerWidth: 1000, visible: false) == 0)
    }

    @Test func effectiveWidthWideContainer() {
        #expect(TabSidebarLogic.effectiveWidth(stored: 300, containerWidth: 1000, visible: true) == 300)
    }

    @Test func effectiveWidthNarrowContainer() {
        // Leaves the minimum terminal width when possible...
        #expect(TabSidebarLogic.effectiveWidth(stored: 300, containerWidth: 400, visible: true) == 200)
        // ...but never goes below the minimum sidebar width.
        #expect(TabSidebarLogic.effectiveWidth(stored: 300, containerWidth: 250, visible: true) == TabSidebarLogic.minWidth)
    }

    // MARK: Reordering

    @Test func destinationIndexDraggingDown() {
        #expect(TabSidebarLogic.destinationIndex(from: 0, dropRow: 2, count: 3) == 1)
        #expect(TabSidebarLogic.destinationIndex(from: 0, dropRow: 3, count: 3) == 2)
    }

    @Test func destinationIndexDraggingUp() {
        #expect(TabSidebarLogic.destinationIndex(from: 2, dropRow: 0, count: 3) == 0)
        #expect(TabSidebarLogic.destinationIndex(from: 2, dropRow: 1, count: 3) == 1)
    }

    @Test func destinationIndexNoop() {
        #expect(TabSidebarLogic.destinationIndex(from: 1, dropRow: 1, count: 3) == nil)
        #expect(TabSidebarLogic.destinationIndex(from: 1, dropRow: 2, count: 3) == nil)
    }

    @Test func destinationIndexOutOfRange() {
        #expect(TabSidebarLogic.destinationIndex(from: 3, dropRow: 0, count: 3) == nil)
        #expect(TabSidebarLogic.destinationIndex(from: 0, dropRow: 4, count: 3) == nil)
        #expect(TabSidebarLogic.destinationIndex(from: -1, dropRow: 0, count: 3) == nil)
    }

    @Test func moveIndex() {
        #expect(TabSidebarLogic.moveIndex(selected: 1, amount: 1, count: 4) == 2)
        #expect(TabSidebarLogic.moveIndex(selected: 1, amount: -1, count: 4) == 0)
        #expect(TabSidebarLogic.moveIndex(selected: 1, amount: 5, count: 4) == 3)
        #expect(TabSidebarLogic.moveIndex(selected: 1, amount: -5, count: 4) == 0)
        #expect(TabSidebarLogic.moveIndex(selected: 3, amount: 1, count: 4) == 3)
    }
}
