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
        leadingColor: Color? = nil
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            description: description,
            leadingColor: leadingColor
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

    /// A strong color match outranks any text match.
    @Test func colorMatchOutranksTextMatch() {
        let byColor = option(title: "Alpha", leadingColor: .red)
        let byTitle = option(title: "Reduce Motion")

        let results = [byTitle, byColor].filteredAndSorted(query: "red")

        #expect(results == [byColor, byTitle])
    }

    /// Even a barely-matching color outranks a text match, and the option
    /// is not dropped from the results. (A previous integer-based score
    /// truncated weak color matches to 0-3, colliding with the text tiers.)
    @Test func weakColorMatchOutranksTextMatchAndIsKept() throws {
        // Weighted distance to the Apple color list's red is just under the
        // 1.5 match threshold, producing a color score near 0.
        let weakColor = Color(red: 0.31, green: 0.49, blue: 0.49)
        let byColor = option(title: "Alpha", leadingColor: weakColor)
        let byTitle = option(title: "Reduce Motion")

        // Sanity-check the fixture: the color must match, but only weakly.
        let match = try #require(CommandOptionMatch(option: byColor, query: "red"))
        #expect(match.colorScore > 0)
        #expect(match.colorScore < 0.05)

        let results = [byTitle, byColor].filteredAndSorted(query: "red")

        #expect(results == [byColor, byTitle])
    }

    /// Options with equal scores keep their original relative order.
    @Test func tiesPreserveOriginalOrder() {
        let first = option(title: "New Window")
        let second = option(title: "New Tab")

        #expect([first, second].filteredAndSorted(query: "new") == [first, second])
        #expect([second, first].filteredAndSorted(query: "new") == [second, first])
    }
}
