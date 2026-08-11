import AppKit
import SwiftUI

/// Manages "broadcast input" groups: sets of terminal surfaces that all receive the
/// same keyboard input, similar to iTerm2's broadcast input and tmux's synchronized
/// panes.
///
/// Surfaces are toggled in and out of groups with cmd+shift+click, or join a
/// specific numbered group with the `join_broadcast_group` keybinding action
/// (cmd+ctrl+<digit> by default). Multiple groups can exist at
/// once and each group is assigned a distinct border color so members are
/// visually identifiable. At most `maxGroups` groups can exist, one per palette
/// color.
///
/// Membership rules for a cmd+shift+click on a surface:
///   - If the surface is already in a group, it is removed from that group.
///   - Otherwise, if the currently focused surface is in a group, the clicked
///     surface joins that group.
///   - Otherwise, a new group is created containing the clicked surface,
///     unless all group numbers are already in use.
///
/// Members are held weakly so closed surfaces fall out of their group naturally.
@MainActor
class BroadcastGroups {
    static let shared = BroadcastGroups()

    /// Border colors assigned to groups. A group's number is its index into
    /// this palette.
    static let palette: [Color] = [
        .orange, .cyan, .green, .purple, .yellow,
        .pink, .red, .blue, .brown, .gray,
    ]

    /// The maximum number of groups that can exist at once. Each group owns
    /// one palette color, so this is bounded by the palette size.
    static let maxGroups = palette.count

    private struct Group {
        /// The number of this group, which doubles as its palette index.
        /// Always less than `maxGroups`.
        let number: Int

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
            // Take the lowest unused group number. If every number is in
            // use we refuse: there can be at most maxGroups groups.
            let used = Set(groups.map { $0.number })
            guard let number = (0..<Self.maxGroups).first(where: { !used.contains($0) }) else {
                return
            }
            groups.append(Group(number: number, members: []))
            targetIdx = groups.count - 1
        }

        add(surfaceView, toGroupAt: targetIdx)
    }

    /// Add the given surface to the group with the given number (0-based),
    /// creating the group if it doesn't exist yet. A surface already in a
    /// different group is moved; a surface already in that exact group is
    /// removed from it instead (toggle). Returns false if the number is
    /// outside 0..<maxGroups.
    @discardableResult
    func join(_ surfaceView: Ghostty.SurfaceView, group number: Int) -> Bool {
        guard (0..<Self.maxGroups).contains(number) else { return false }
        prune()

        // Leave the current group, if any. If it was the requested group
        // then this is a toggle off and we're done.
        if let idx = groupIndex(of: surfaceView) {
            let current = groups[idx].number
            groups[idx].members.removeAll { $0.value === surfaceView }
            surfaceView.broadcastGroupColor = nil
            if groups[idx].members.isEmpty {
                groups.remove(at: idx)
            }
            if current == number { return true }
        }

        // Join the requested group, creating it if needed.
        let targetIdx: Int
        if let idx = groups.firstIndex(where: { $0.number == number }) {
            targetIdx = idx
        } else {
            groups.append(Group(number: number, members: []))
            targetIdx = groups.count - 1
        }

        add(surfaceView, toGroupAt: targetIdx)
        return true
    }

    private func add(_ surfaceView: Ghostty.SurfaceView, toGroupAt idx: Int) {
        groups[idx].members.append(Weak(surfaceView))
        surfaceView.broadcastGroupColor = Self.palette[groups[idx].number]
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
