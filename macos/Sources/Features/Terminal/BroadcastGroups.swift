import AppKit
import SwiftUI

/// Manages "broadcast input" groups: sets of terminal surfaces that all receive the
/// same keyboard input, similar to iTerm2's broadcast input and tmux's synchronized
/// panes.
///
/// Surfaces are toggled in and out of groups with shift+click. Multiple groups can
/// exist at once and each group is assigned a distinct border color so members are
/// visually identifiable.
///
/// Membership rules for a shift+click on a surface:
///   - If the surface is already in a group, it is removed from that group.
///   - Otherwise, if the currently focused surface is in a group, the clicked
///     surface joins that group.
///   - Otherwise, a new group is created containing the clicked surface.
///
/// Members are held weakly so closed surfaces fall out of their group naturally.
@MainActor
class BroadcastGroups {
    static let shared = BroadcastGroups()

    /// Border colors assigned to groups. Groups beyond the palette size cycle.
    static let palette: [Color] = [.orange, .cyan, .green, .purple, .yellow, .pink]

    private struct Group {
        let colorIndex: Int
        var members: [Weak<Ghostty.SurfaceView>]

        var liveMembers: [Ghostty.SurfaceView] {
            members.compactMap { $0.value }
        }
    }

    private var groups: [Group] = []

    private init() {}

    /// Toggle the group membership of the given surface. See the class docs for
    /// the membership rules.
    func toggle(_ surfaceView: Ghostty.SurfaceView) {
        prune()

        // Already in a group: remove it.
        if let idx = groupIndex(of: surfaceView) {
            groups[idx].members.removeAll { $0.value === surfaceView }
            surfaceView.broadcastGroupColor = nil
            if groups[idx].members.isEmpty {
                groups.remove(at: idx)
            }
            return
        }

        // Join the focused surface's group if it has one, else start a new group.
        let targetIdx: Int
        if let focused = Self.focusedSurface,
           let focusedIdx = groupIndex(of: focused) {
            targetIdx = focusedIdx
        } else {
            var colorIndex = 0
            let used = Set(groups.map { $0.colorIndex })
            while used.contains(colorIndex) { colorIndex += 1 }
            groups.append(Group(colorIndex: colorIndex, members: []))
            targetIdx = groups.count - 1
        }

        groups[targetIdx].members.append(Weak(surfaceView))
        surfaceView.broadcastGroupColor =
            Self.palette[groups[targetIdx].colorIndex % Self.palette.count]
    }

    /// Returns all other live members of the given surface's group. Empty if the
    /// surface is not in a group or is the only member. Members not attached to
    /// a window (e.g. closed surfaces kept alive by the undo manager) are
    /// excluded so input never reaches an invisible terminal.
    func others(for surfaceView: Ghostty.SurfaceView) -> [Ghostty.SurfaceView] {
        guard let idx = groupIndex(of: surfaceView) else { return [] }
        return groups[idx].liveMembers.filter { $0 !== surfaceView && $0.window != nil }
    }

    private func groupIndex(of surfaceView: Ghostty.SurfaceView) -> Int? {
        groups.firstIndex { group in
            group.members.contains { $0.value === surfaceView }
        }
    }

    /// Drop deallocated members and dissolve empty groups.
    private func prune() {
        for idx in groups.indices {
            groups[idx].members.removeAll { $0.value == nil }
        }
        groups.removeAll { $0.members.isEmpty }
    }

    /// The surface that currently has keyboard focus, if any.
    private static var focusedSurface: Ghostty.SurfaceView? {
        (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
    }
}
