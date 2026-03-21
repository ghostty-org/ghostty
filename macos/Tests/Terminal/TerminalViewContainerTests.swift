//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test func customTabBarVisibilityTracksTabCount() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let tabBar = try await MainActor.run {
            let items = view.descendants(withClassName: "GhosttyCustomTabBar")
            return try #require(items.first as? GhosttyCustomTabBar)
        }

        await MainActor.run {
            view.updateCustomTabBar(
                items: [GhosttyCustomTabItem(id: UUID(), title: "One")],
                selectedIndex: 0,
                backgroundColor: .windowBackgroundColor,
                isKeyWindow: true,
                allowsWindowDrag: false
            )
        }
        #expect(await MainActor.run { tabBar.isHidden })

        await MainActor.run {
            view.updateCustomTabBar(
                items: [
                    GhosttyCustomTabItem(id: UUID(), title: "One"),
                    GhosttyCustomTabItem(id: UUID(), title: "Two"),
                ],
                selectedIndex: 0,
                backgroundColor: .windowBackgroundColor,
                isKeyWindow: true,
                allowsWindowDrag: false
            )
        }
        #expect(await MainActor.run { !tabBar.isHidden })
    }

    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }

#if compiler(>=6.2)
    @Test func configChangeUpdatesGlass() async throws {
        guard #available(macOS 26.0, *) else { return }
        let view = await MockTerminalViewContainer {
            EmptyView()
        }
        let config1 = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config1, preferredBackgroundColor: nil)
        let glassEffectView = await view.descendants(withClassName: "NSGlassEffectView").first as? NSGlassEffectView
        let effectView = try #require(glassEffectView)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        #expect(effectView.tintColor?.hexString == NSColor.clear.hexString)

        // Test with same config but with different preferredBackgroundColor
        await view.ghosttyConfigDidChange(config1, preferredBackgroundColor: .red)
        #expect(effectView.tintColor?.hexString == NSColor.red.hexString)

        // MARK: - Corner Radius

        #expect(effectView.cornerRadius == 0)
        await MainActor.run { view._windowCornerRadius = 10 }

        // This won't change, unless ghosttyConfigDidChange is called
        #expect(effectView.cornerRadius == 0)

        await view.ghosttyConfigDidChange(config1, preferredBackgroundColor: .red)
        #expect(effectView.cornerRadius == 10)

        // MARK: - Glass Style

        #expect(effectView.style == .regular)

        let config2 = MockConfig(backgroundBlur: .macosGlassClear, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config2, preferredBackgroundColor: .red)

        #expect(effectView.style == .clear)

    }
#endif // compiler(>=6.2)
}
