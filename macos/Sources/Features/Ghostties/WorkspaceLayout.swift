import AppKit
import Foundation
import SwiftUI

/// Three-state sidebar visibility model.
///
/// - `pinned`: Sidebar open, terminal pushed right (floating card).
/// - `closed`: Sidebar hidden, terminal fills window flush.
/// - `overlay`: Sidebar floats on top of full-width terminal (hover-to-reveal).
enum SidebarMode: Int, Codable {
    case pinned
    case closed
    case overlay
}

/// Shared layout constants for the workspace sidebar.
enum WorkspaceLayout {
    /// Width of the sidebar panel.
    static let sidebarWidth: CGFloat = 220

    /// Width of the task-first sidebar panel (Concept F).
    /// Wider than `sidebarWidth` to accommodate the hero row's two-line typography.
    /// v0 feature toggle — selected via the `ghostties.sidebarViewMode` @AppStorage flag.
    static let taskSidebarWidth: CGFloat = 280

    /// Height reserved at top for window traffic light controls.
    static let titlebarSpacerHeight: CGFloat = 28

    /// Offset between traffic-light centerline and our toolbar row (toggle, +, title).
    /// Zero = exact alignment with traffic lights (Dia Browser style, confirmed correct).
    static let breathingRoomBelowChrome: CGFloat = 0

    /// Returns the Auto Layout `topAnchor + constant` that places an element's centerY
    /// on the unified toolbar row — co-planar with the traffic lights.
    /// Returns nil before the window is on-screen or if the button isn't available.
    /// Call from NSView.layout() or window-delegate hooks, not from init.
    static func titlebarRowTopAnchorConstant(in view: NSView) -> CGFloat? {
        // In fullscreen, there is no titlebar row — content extends edge-to-edge.
        // Return 0 so toolbar buttons park at the top edge (they will be hidden
        // by the fullscreen chrome).
        if view.window?.styleMask.contains(.fullScreen) == true {
            return 0
        }
        guard let win = view.window,
              let close = win.standardWindowButton(.closeButton),
              close.window === win else { return nil }
        let closeInView = close.convert(close.bounds, to: view)
        // closeInView.midY is in AppKit unflipped coords (larger = visually higher).
        // "Below" traffic lights = smaller Y in unflipped coords.
        let rowY_unflipped = closeInView.midY - breathingRoomBelowChrome
        // topAnchor + N = N pts below visual top; visual top = bounds.height (unflipped).
        return view.bounds.height - rowY_unflipped
    }

    /// Height of the session-name title bar inside the terminal card.
    static let terminalTitleBarHeight: CGFloat = 28

    /// Corner radius on the floating terminal panel (all four corners).
    static let terminalCornerRadius: CGFloat = 12

    /// Shadow color applied to canvas shadow hosts (terminal + browser cards).
    static let canvasShadowColor: CGColor = NSColor.black.cgColor

    /// Shadow blur radius applied to canvas shadow hosts.
    static let canvasShadowRadius: CGFloat = 8

    /// Shadow offset applied to canvas shadow hosts (slight downward cast).
    static let canvasShadowOffset: CGSize = CGSize(width: 0, height: -2)

    /// Shadow opacity applied to canvas shadow hosts when the card is visible.
    static let canvasShadowOpacity: Float = 0.15

    /// Inset around the terminal panel when sidebar is visible (floating card effect).
    /// The design uses 8pt on all four sides (top, bottom, left, right).
    static let terminalInset: CGFloat = 8

    /// Width of the invisible hover trigger strip at the left edge (closed mode).
    static let overlayTriggerWidth: CGFloat = 10

    /// Minimum width for the browser panel when visible.
    static let browserMinWidth: CGFloat = 320

    /// Default split ratio for terminal vs browser (terminal gets this fraction).
    static let browserSplitRatio: CGFloat = 0.5

    /// Background for expanded project group container (dark mode).
    static let expandedContainerDark = Color(white: 0.16)

    /// Background for expanded project group container (light mode).
    static let expandedContainerLight = Color.white

    /// Background for active session row (dark mode): 6% white.
    static let activeRowDark = Color.white.opacity(0.06)

    /// Background for active session row (light mode): 4% black.
    static let activeRowLight = Color.black.opacity(0.04)

    /// Chrome background (light mode). Covers the left sidebar column and the
    /// gutter padding around the terminal card. The outer of the two Ghostties
    /// design-system layers — warm pink-cream, independent of terminal theme.
    static let chromeBackgroundLight = NSColor(red: 0xF0 / 255.0, green: 0xE9 / 255.0, blue: 0xE6 / 255.0, alpha: 1)

    /// Chrome background (dark mode). See `chromeBackgroundLight`.
    static let chromeBackgroundDark = NSColor(white: 0.14, alpha: 1)

    /// Canvas background (light mode). Covers the terminal card background
    /// (internal header strip + card rim around the GPU-rendered terminal).
    /// Slightly lighter and cooler than chrome — the inner of the two
    /// Ghostties design-system layers. Also independent of terminal theme;
    /// the terminal content area itself is painted by GhosttyKit.
    static let canvasBackgroundLight = NSColor(red: 0xFA / 255.0, green: 0xF7 / 255.0, blue: 0xF3 / 255.0, alpha: 1)

    /// Canvas background (dark mode). Slightly lighter than chrome dark, still
    /// warm. See `canvasBackgroundLight`.
    static let canvasBackgroundDark = NSColor(white: 0.18, alpha: 1)

    /// Terracotta/warm rust accent for the "waiting" indicator state. #c97350
    static let waitingTerracotta = Color(red: 0.788, green: 0.451, blue: 0.314)

    /// NSColor variant of `waitingTerracotta` for AppKit layers (e.g. button tints).
    static let waitingTerracottaNS = NSColor(red: 0.788, green: 0.451, blue: 0.314, alpha: 1)

    /// Minimum width for the terminal panel when browser is visible.
    static let terminalMinWidth: CGFloat = 300

    /// Purple accent for the "needs attention" indicator state. #A855F7
    static let needsAttentionPurple = Color(red: 0.659, green: 0.333, blue: 0.969)

    // MARK: - Activity / Section Foregrounds

    /// Foreground color for a project's ghost icon when the project has recent
    /// activity (within 24h) but no live active session. Reads as "alive but not
    /// running" — full-strength label, same weight as a body label.
    static let activityNormalForeground = Color.primary

    /// Foreground color for a project's ghost icon when the project is idle
    /// (no live active session and nothing within the past 24h). Reads as "in
    /// the long tail" — quietest tier above pure invisible.
    static let activityMutedForeground = Color(.tertiaryLabelColor)

    /// Foreground for the small section-header labels in the sidebar
    /// ("Pinned", "Active Now", "Recent", "All Projects"). Muted by design so
    /// the project rows themselves stay the dominant visual.
    static let sectionHeaderForeground = Color(.tertiaryLabelColor)

    /// Foreground for the smaller in-row session group headers ("Active",
    /// "Recent", "Idle") inside an expanded project. One tier quieter than the
    /// top-level section headers since they're nested.
    static let sessionGroupHeaderForeground = Color(.tertiaryLabelColor)

    // MARK: - Sidebar Icon Column

    /// Width of the icon column shared by section headers (pin/bolt/clock/grid)
    /// and project rows (ghost icon). Both icons live in a fixed-width frame
    /// with `.center` alignment so their x-centers align vertically when
    /// scanning the list. The label/name text begins after this column plus
    /// `sidebarIconLabelSpacing`, so section LABEL text and project NAME text
    /// also left-align.
    static let sidebarIconColumnWidth: CGFloat = 16

    /// Horizontal gap between the icon column and the text label/name in a
    /// sidebar row or section header.
    static let sidebarIconLabelSpacing: CGFloat = 10

    /// Leading padding applied to the outermost HStack of both section headers
    /// and project rows. Combined with `sidebarIconColumnWidth` this yields the
    /// common x-position for icons and labels.
    static let sidebarRowLeadingPadding: CGFloat = 8
}

// MARK: - Animation Tokens (D18)

extension Animation {
    /// 180ms cubic-bezier(0.2, 0.7, 0.2, 1) — inline panel reveals
    /// (composer, triage card, graveyard expansion).
    /// Use as the `value:` animation on the enclosing container,
    /// or pair with `AnyTransition` for asymmetric entry/exit.
    static var sidebarPush: Animation {
        .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.18)
    }

    /// 140ms ease-in — inline panel collapses.
    /// Matches the removal side of every asymmetric push transition in D18.
    static var sidebarCollapse: Animation {
        .easeIn(duration: 0.14)
    }

    /// Spatial-stability row migration (D18 grammar).
    /// Same curve as `sidebarPush` — used on `withAnimation` wrappers
    /// when a task migrates between lanes.
    static var sidebarRowMigration: Animation {
        .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.18)
    }

    /// Reduced-motion fallback — opacity crossfade at 200ms (D19).
    /// Replace any spatial animation with this when
    /// `@Environment(\.accessibilityReduceMotion)` is true.
    static var sidebarReducedMotion: Animation {
        .easeInOut(duration: 0.2)
    }
}

// MARK: - Workspace Notifications

extension Notification.Name {
    /// Posted by TerminalController when the user presses Cmd+Shift+].
    /// The notification object is the originating NSWindow.
    static let workspaceSelectNextProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectNextProject")

    /// Posted by TerminalController when the user presses Cmd+Shift+[.
    /// The notification object is the originating NSWindow.
    static let workspaceSelectPreviousProject = Notification.Name("com.seansmithdesign.ghostties.workspace.selectPreviousProject")

    /// Posted by WorkspaceStore just before a project is removed.
    /// userInfo contains "projectId" (UUID). Coordinators observe this to close
    /// running sessions before the store deletes the project's records.
    static let workspaceProjectWillBeRemoved = Notification.Name("com.seansmithdesign.ghostties.workspace.projectWillBeRemoved")

    /// Posted by TerminalController when the user presses Cmd+Shift+T.
    /// The notification object is the originating NSWindow.
    static let workspaceNewSession = Notification.Name("com.seansmithdesign.ghostties.workspace.newSession")

    /// Posted by MenuBarDropdownView when the user clicks a session row.
    /// userInfo contains "sessionId" (UUID). SessionCoordinators observe this
    /// to focus the tapped session and bring its window to the front.
    static let menuBarFocusSession = Notification.Name("com.seansmithdesign.ghostties.menuBar.focusSession")

    /// Posted when the user toggles the sidebar view mode (project-first ↔ task-first).
    /// WorkspaceViewContainer instances observe this to swap the hosted SwiftUI view
    /// and update the sidebar width. v0 feature toggle.
    static let workspaceSidebarViewModeChanged = Notification.Name("com.seansmithdesign.ghostties.workspace.sidebarViewModeChanged")

    /// Posted by `TerminalController.showProjectsView` / `showSessionsView` after
    /// writing the new tab value to UserDefaults. `@AppStorage` handles the SwiftUI
    /// side automatically; this notification is available for AppKit observers.
    static let workspaceSidebarTabChanged = Notification.Name("com.seansmithdesign.ghostties.workspace.sidebarTabChanged")

    /// Posted by `AppDelegate`'s ⌘⇧N local-event monitor and by any code path
    /// that wants to open the new-task composer. `NewTaskComposerStore.shared`
    /// observes this to call `open(workspaceStore:)`.
    ///
    /// The notification object is the originating `NSWindow` (may be nil when
    /// the monitor fires with no key window).
    static let openNewTaskComposer = Notification.Name("com.seansmithdesign.ghostties.workspace.openNewTaskComposer")

    /// Posted by AppDelegate when the `Return` menu item fires (U11).
    /// The notification object is the focused task's id `String`.
    /// `TaskRowView` instances that own the focused task observe this and call
    /// `RowClickRouter.shared.handleRowClick` through their existing SwiftUI
    /// environment, preserving correct window-scoped coordinator references.
    static let ghosttiesActivateFocusedTaskRow = Notification.Name("com.seansmithdesign.ghostties.activateFocusedTaskRow")
}
