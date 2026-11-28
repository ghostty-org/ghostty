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

    var _reduceTransparency = false
    override var reduceTransparency: Bool {
        _reduceTransparency
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

    /// The sidebar glass is AppKit's sidebar split view, added only for its style.
    @MainActor
    @Test func sidebarGlassSplitView() async throws {
        guard #available(macOS 26.0, *) else { return }
        let view = MockTerminalViewContainer {
            EmptyView()
        }

        let sidebar = MockConfig(backgroundBlur: .macosGlassSidebar, backgroundColor: .clear, backgroundOpacity: 0.5)
        view.ghosttyConfigDidChange(sidebar, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        #expect(containsSplitView(view.glassEffectView))
        // background-opacity applies to the glass itself.
        #expect(sidebarGlassView(in: view.glassEffectView)?.alphaValue == 0.5)

        let regular = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        view.ghosttyConfigDidChange(regular, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8))
        #expect(!containsSplitView(view.glassEffectView))
    }

    /// With Reduce Transparency the sidebar style uses the regular glass, and
    /// it follows the setting when it changes.
    @MainActor
    @Test func sidebarGlassReduceTransparency() async throws {
        guard #available(macOS 26.0, *) else { return }
        let view = MockTerminalViewContainer {
            EmptyView()
        }
        view._reduceTransparency = true

        let sidebar = MockConfig(backgroundBlur: .macosGlassSidebar, backgroundColor: .clear, backgroundOpacity: 1)
        view.ghosttyConfigDidChange(sidebar, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        #expect(view.glassEffectView != nil)
        #expect(!containsSplitView(view.glassEffectView))

        view._reduceTransparency = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        try await Task.sleep(nanoseconds: UInt64(1e8))
        #expect(containsSplitView(view.glassEffectView))
    }
}

private func containsSplitView(_ view: NSView?) -> Bool {
    splitView(in: view) != nil
}

private func splitView(in view: NSView?) -> NSSplitView? {
    guard let view else { return nil }
    if let splitView = view as? NSSplitView { return splitView }
    return view.subviews.lazy.compactMap(splitView(in:)).first
}

/// The subview of the glass view that hosts the split view.
private func sidebarGlassView(in glassView: NSView?) -> NSView? {
    var view: NSView? = splitView(in: glassView)
    while let current = view, current.superview !== glassView {
        view = current.superview
    }
    return view
}
