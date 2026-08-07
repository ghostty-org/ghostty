import SwiftUI
@testable import Ghostty
import Testing

@MainActor
struct AppearanceCoordinatorTests {
    // MARK: - BlurStyle

    /// The system glass material was removed as a picker option; configs
    /// still holding one of its values must keep loading as the blurred
    /// background it now maps to, rather than erroring or going solid.
    @Test(arguments: [
        (nil, false),
        ("false", false),
        ("", false),
        ("0", false),
        ("true", true),
        ("macos-glass-regular", true),
        ("macos-glass-clear", true),
        ("45", true),
    ])
    func blurStyleClassification(configValue: String?, isRadius: Bool) {
        let style = AppearanceCoordinator.BlurStyle(configValue: configValue)
        switch style {
        case .off:
            #expect(!isRadius)
        case .radius:
            #expect(isRadius)
        }
    }

    @Test func blurStyleGlassValuesUseTheDefaultRadius() {
        for value in ["true", "macos-glass-regular", "macos-glass-clear"] {
            guard case .radius(let amount) = AppearanceCoordinator.BlurStyle(configValue: value) else {
                Issue.record("\(value) should classify as .radius")
                continue
            }
            #expect(amount == 20)
        }
    }

    @Test func blurStyleNumericRadiusIsPreserved() {
        guard case .radius(let amount) = AppearanceCoordinator.BlurStyle(configValue: "45") else {
            Issue.record("numeric value should classify as .radius")
            return
        }
        #expect(amount == 45)
    }

    // MARK: - DividerMode

    /// `SidebarDividerMode` lives in plain `UserDefaults`, not
    /// `GuiConfigStore`, so these tests read and restore it directly rather
    /// than through a seam — set up here once so failures don't leak into
    /// other tests or the running app's own defaults.
    private func withDividerMode<T>(
        _ mode: String?,
        colorHex: String? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        let defaults = UserDefaults.standard
        let previousMode = defaults.string(forKey: "SidebarDividerMode")
        let previousHex = defaults.string(forKey: "SidebarDividerColorHex")
        defer {
            defaults.set(previousMode, forKey: "SidebarDividerMode")
            defaults.set(previousHex, forKey: "SidebarDividerColorHex")
        }
        defaults.set(mode, forKey: "SidebarDividerMode")
        defaults.set(colorHex, forKey: "SidebarDividerColorHex")
        return try body()
    }

    @Test func dividerModeDefaultsToSystem() {
        withDividerMode(nil) {
            #expect(AppearanceCoordinator.dividerMode.isHidden == false)
            if case .system = AppearanceCoordinator.dividerMode {} else {
                Issue.record("expected .system")
            }
        }
    }

    @Test func dividerModeHidden() {
        withDividerMode("hidden") {
            #expect(AppearanceCoordinator.dividerMode.isHidden)
        }
    }

    @Test func dividerModeCustomColor() {
        withDividerMode("custom", colorHex: "#ff0000") {
            guard case .custom(let color) = AppearanceCoordinator.dividerMode else {
                Issue.record("expected .custom")
                return
            }
            #expect(color.hexString?.lowercased() == "#ff0000")
            #expect(!AppearanceCoordinator.dividerMode.isHidden)
        }
    }

    @Test func dividerModeCustomWithoutColorFallsBackToSystem() {
        withDividerMode("custom", colorHex: nil) {
            if case .system = AppearanceCoordinator.dividerMode {} else {
                Issue.record("a custom mode with no stored colour should fall back to .system")
            }
        }
    }

    // MARK: - Hidden dividers take no space

    /// Regresses a divider drawn `.clear` instead of collapsed to zero
    /// width: painting it clear still reserved the strip, which showed the
    /// window through it as a line of its own over a transparent
    /// background — the same visible seam by another route.

    @Test func sidebarDividerThicknessCollapsesWhenHidden() {
        withDividerMode("hidden") {
            let split = SidebarSplitView()
            #expect(split.dividerThickness == 0)
        }
    }

    @Test func sidebarDividerThicknessIsNonZeroOtherwise() {
        withDividerMode("default") {
            let split = SidebarSplitView()
            #expect(split.dividerThickness > 0)
        }
        withDividerMode("custom", colorHex: "#00ff00") {
            let split = SidebarSplitView()
            #expect(split.dividerThickness > 0)
        }
    }

    @Test func splitDividerVisibleSizeCollapsesWhenHidden() {
        withDividerMode("hidden") {
            let split = SplitView(
                .horizontal,
                .constant(0.5),
                dividerColor: .clear,
                left: { Color.clear },
                right: { Color.clear },
                onEqualize: {}
            )
            #expect(split.splitterVisibleSize == 0)
        }
    }

    @Test func splitDividerVisibleSizeIsNonZeroOtherwise() {
        withDividerMode("default") {
            let split = SplitView(
                .horizontal,
                .constant(0.5),
                dividerColor: .clear,
                left: { Color.clear },
                right: { Color.clear },
                onEqualize: {}
            )
            #expect(split.splitterVisibleSize > 0)
        }
    }
}
