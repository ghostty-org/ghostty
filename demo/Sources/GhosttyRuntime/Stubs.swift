// Stubs for types referenced by Ghostty source files but not included in the demo.
// These are minimal definitions to satisfy compilation.

import AppKit
import SwiftUI
import os
import GhosttyKit

// MARK: - FullscreenMode

enum FullscreenMode: String, Codable {
    case native
    case nonNative
    case nonNativeVisibleMenu
    case nonNativePaddedNotch
}

// MARK: - AppDelegate stub

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, GhosttyAppDelegate {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.demo",
        category: "AppDelegate"
    )

    var undoManager: UndoManager? { UndoManager() }
    let ghostty = Ghostty.App()

    func applicationDidFinishLaunching(_ notification: Notification) {}
    func applicationWillTerminate(_ notification: Notification) {}
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func toggleVisibility(_ sender: Any?) {}
    func checkForUpdates(_ sender: Any?) {}
    func closeAllWindows(_ sender: Any?) {}
    func setSecureInput(_ sender: Any?) {}
    func syncFloatOnTopMenu(_ window: NSWindow?) {}
    func toggleQuickTerminal(_ sender: Any?) {}

    @discardableResult
    func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        return false
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return nil
    }
}

// MARK: - BaseTerminalController stub

class BaseTerminalController: NSWindowController, NSWindowDelegate {
    var surfaceTree: SurfaceTree = SurfaceTree()
    var focusedSurface: Ghostty.SurfaceView? { nil }
    var titleOverride: String?
    var commandPaletteIsShowing: Bool { false }
    var focusFollowsMouse: Bool { false }

    func toggleBackgroundOpacity() {}
    func promptTabTitle() {}
    @objc func changeTabTitle(_ sender: Any) {}
    func windowDidBecomeKey(_ notification: Notification) {}
    func windowDidResignKey(_ notification: Notification) {}
    func windowWillClose(_ notification: Notification) {}
    func windowDidResize(_ notification: Notification) {}
    func windowDidChangeScreen(_ notification: Notification) {}
}

// MARK: - SurfaceTree stub

class SurfaceTree {
    var isSplit: Bool { false }
    var root: SurfaceTreeNode? { nil }

    struct SurfaceTreeNode {
        func node<ViewType>(view: ViewType) -> SurfaceTreeNode? { nil }
    }

    func focusTarget<ViewType>(for direction: SplitTree<ViewType>.FocusDirection, from node: SurfaceTreeNode) -> SurfaceTreeNode? {
        nil
    }
}

// MARK: - TerminalWindow stub

class TerminalWindow: NSWindow {
    func isTabBar(_ controller: Any) -> Bool { false }
}

// MARK: - HiddenTitlebarTerminalWindow stub

class HiddenTitlebarTerminalWindow: NSWindow {
    var fullScreen: Bool { false }
}

// MARK: - SplitTree stub

struct SplitTree<ViewType> {
    enum FocusDirection {
        case previous
        case next
        case spatial(SpatialDirection)
    }

    enum SpatialDirection {
        case up, down, left, right
    }
}

extension Ghostty.SplitFocusDirection {
    func toSplitTreeFocusDirection<ViewType>() -> SplitTree<ViewType>.FocusDirection {
        switch self {
        case .previous: return .previous
        case .next: return .next
        case .up: return .spatial(.up)
        case .down: return .spatial(.down)
        case .left: return .spatial(.left)
        case .right: return .spatial(.right)
        }
    }
}

// MARK: - SplitViewDirection

enum SplitViewDirection: Codable {
    case horizontal, vertical
}

// MARK: - SplitView stub (SwiftUI)

struct SplitView<L: View, R: View>: View {
    let direction: SplitViewDirection
    let dividerColor: Color
    let left: L
    let right: R
    let onEqualize: () -> Void
    @Binding var split: CGFloat

    init(
        _ direction: SplitViewDirection,
        _ split: Binding<CGFloat>,
        dividerColor: Color,
        resizeIncrements: NSSize = .init(width: 1, height: 1),
        @ViewBuilder left: () -> L,
        @ViewBuilder right: () -> R,
        onEqualize: @escaping () -> Void
    ) {
        self.direction = direction
        self._split = split
        self.dividerColor = dividerColor
        self.left = left()
        self.right = right()
        self.onEqualize = onEqualize
    }

    var body: some View {
        HStack(spacing: 0) {
            left
            right
        }
    }
}

// MARK: - QuickTerminalPosition stub

enum QuickTerminalPosition: String {
    case top
    case bottom
    case left
    case right
    case center
}

// MARK: - QuickTerminalScreen stub

enum QuickTerminalScreen {
    case main
    case mouse
    case menuBar

    init?(fromGhosttyConfig string: String) {
        switch string {
        case "main": self = .main
        case "mouse": self = .mouse
        case "macos-menu-bar": self = .menuBar
        default: return nil
        }
    }
}

// MARK: - QuickTerminalSpaceBehavior stub

enum QuickTerminalSpaceBehavior {
    case remain
    case move

    init?(fromGhosttyConfig string: String) {
        switch string {
        case "move": self = .move
        case "remain": self = .remain
        default: return nil
        }
    }
}

// MARK: - QuickTerminalSize stub

struct QuickTerminalSize {
    let primary: Size?
    let secondary: Size?

    init(primary: Size? = nil, secondary: Size? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    init(from cStruct: ghostty_config_quick_terminal_size_s) {
        self.primary = Size(from: cStruct.primary)
        self.secondary = Size(from: cStruct.secondary)
    }

    enum Size {
        case percentage(Float)
        case pixels(UInt32)

        init?(from cStruct: ghostty_quick_terminal_size_s) {
            switch cStruct.tag {
            case GHOSTTY_QUICK_TERMINAL_SIZE_NONE: return nil
            case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
                self = .percentage(cStruct.value.percentage)
            case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
                self = .pixels(cStruct.value.pixels)
            default:
                return nil
            }
        }

        func toPixels(parentDimension: CGFloat) -> CGFloat {
            switch self {
            case .percentage(let value):
                return parentDimension * CGFloat(value) / 100.0
            case .pixels(let value):
                return CGFloat(value)
            }
        }
    }

    func calculate(position: QuickTerminalPosition, screenDimensions: CGSize) -> CGSize {
        let dims = CGSize(width: screenDimensions.width, height: screenDimensions.height)
        switch position {
        case .left, .right:
            return CGSize(
                width: primary?.toPixels(parentDimension: dims.width) ?? 400,
                height: secondary?.toPixels(parentDimension: dims.height) ?? dims.height)
        case .top, .bottom:
            return CGSize(
                width: secondary?.toPixels(parentDimension: dims.width) ?? dims.width,
                height: primary?.toPixels(parentDimension: dims.height) ?? 400)
        case .center:
            if dims.width >= dims.height {
                return CGSize(
                    width: primary?.toPixels(parentDimension: dims.width) ?? 800,
                    height: secondary?.toPixels(parentDimension: dims.height) ?? 400)
            } else {
                return CGSize(
                    width: secondary?.toPixels(parentDimension: dims.width) ?? 400,
                    height: primary?.toPixels(parentDimension: dims.height) ?? 800)
            }
        }
    }
}

// MARK: - TerminalRestoreError stub

enum TerminalRestoreError: Error {
    case delegateInvalid
}

// MARK: - Dock stub (for QuickTerminalPosition)

enum Dock {
    enum Orientation {
        case top, bottom, left, right
    }
    static let orientation: Orientation? = nil
}

// MARK: - CGSSpace stub (for FullscreenMode)

enum CGSSpace {
    struct SpaceType: OptionSet {
        let rawValue: UInt32
        static let fullscreen = SpaceType(rawValue: 1 << 1)
    }

    struct Space {
        let type: SpaceType
    }

    static func active() -> Space { Space(type: []) }
    static func list(for windowId: UInt32) -> [Space] { [] }
}

// MARK: - NSScreen hasTitleBar stub

extension NSScreen {
    var hasTitleBar: Bool { true }
}

// MARK: - NSWindow isTabBar stub

extension NSWindow {
    var isTabBar: Bool { false }
}
