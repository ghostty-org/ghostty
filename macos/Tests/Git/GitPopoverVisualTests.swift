import AppKit
import Testing
@testable import Ghostty

@MainActor
struct GitPopoverVisualTests {
    @Test func compactSegmentsKeepVisibleTitlesAndUpdateSelectionOnNativeActivation() throws {
        let control = GitPopoverSegments()
        var chosen: String?
        control.onSelect = { chosen = $0 }
        control.configure(
            segments: [
                .init(id: "current", title: "Current branch", accessibilityLabel: "Current branch"),
                .init(id: "all", title: "All branches", accessibilityLabel: "All branches"),
            ],
            selectedID: "all", colors: .init(), widths: [110, 110]
        )
        control.frame = NSRect(origin: .zero, size: control.intrinsicContentSize)
        control.layoutSubtreeIfNeeded()
        #expect(control.bounds.width == 222 && control.bounds.height == 26)
        #expect(control.buttonsForTesting.map(\.imagePosition) == [.noImage, .noImage])
        #expect(control.buttonsForTesting.map(\.state) == [.off, .on])
        let current = try #require(control.buttonsForTesting.first)
        #expect(NSApp.sendAction(try #require(current.action), to: current.target, from: current))
        #expect(chosen == "current")
        #expect(control.buttonsForTesting.map(\.state) == [.on, .off])
        for button in control.buttonsForTesting {
            #expect(button.bounds.height == 24 && button.bounds.width == 110)
        }
    }

    @Test func opaquePopoverBackgroundFollowsAppearanceChanges() throws {
        let view = GitPopoverBackgroundView(backgroundColor: .windowBackgroundColor)
        view.appearance = NSAppearance(named: .aqua)
        view.updateLayer()
        let light = try #require(view.layer?.backgroundColor)
        view.appearance = NSAppearance(named: .darkAqua)
        view.updateLayer()
        let dark = try #require(view.layer?.backgroundColor)
        #expect(light.alpha == 1 && dark.alpha == 1)
        #expect(light != dark)
    }
}
