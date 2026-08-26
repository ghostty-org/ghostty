//! Global shortcuts backed by the vicinae-hotkey Wayland protocol.
const Hotkeys = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const vicinae = wayland.client.vicinae;

const Config = @import("../../../../config.zig").Config;
const Binding = @import("../../../../input.zig").Binding;
const key = @import("../../key.zig");
const GlobalShortcuts = @import("../../class/global_shortcuts.zig").GlobalShortcuts;

const log = std.log.scoped(.winproto_wayland_hotkeys);

alloc: Allocator,
app_id: [:0]const u8,
entries: std.ArrayList(Entry) = .empty,

const Entry = struct {
    /// Null once the binding was denied or revoked.
    hotkey: ?*vicinae.HotkeyV1,
    trigger: Binding.Trigger,
    action: Binding.Action,
    shortcuts: *GlobalShortcuts,

    fn deinit(self: *Entry) void {
        if (self.hotkey) |hotkey| hotkey.destroy();
    }

    fn bind(
        self: *Entry,
        manager: *vicinae.HotkeyManagerV1,
        app_id: [:0]const u8,
    ) !void {
        // The only time this will return an error is when
        // `trigger.key` is `catch_all`, which is guarded
        // in the public `bind` function
        const keysym = key.keysymFromTrigger(self.trigger) orelse unreachable;

        var desc_buf: [256]u8 = undefined;
        const desc = std.fmt.bufPrintZ(&desc_buf, "{f}", .{self.action}) catch "";

        const hotkey = try manager.bind(
            keysym,
            .{
                .shift = self.trigger.mods.shift,
                .ctrl = self.trigger.mods.ctrl,
                .alt = self.trigger.mods.alt,
                .super = self.trigger.mods.super,
            },
            null,
            app_id.ptr,
            desc.ptr,
        );
        errdefer hotkey.destroy();
        hotkey.setListener(*Entry, hotkeyListener, self);
        self.hotkey = hotkey;
    }

    fn fail(self: *Entry, message: [*:0]const u8, revoked: bool) void {
        self.hotkey.?.destroy();
        self.hotkey = null;

        self.shortcuts.emitBindFailed(&.{
            .trigger = self.trigger,
            .action = self.action,
            .message = message,
            .revoked = revoked,
        });
    }
};

pub fn init(alloc: Allocator, app_id: [:0]const u8) Allocator.Error!Hotkeys {
    return .{
        .alloc = alloc,
        .app_id = try alloc.dupeZ(u8, app_id),
    };
}

/// Must leave the entries in a valid empty state: clear may still be
/// called after deinit during application teardown.
pub fn deinit(self: *Hotkeys) void {
    for (self.entries.items) |*entry| entry.deinit();
    self.entries.clearAndFree(self.alloc);
    self.alloc.free(self.app_id);
}

pub fn clear(self: *Hotkeys) void {
    for (self.entries.items) |*entry| entry.deinit();
    self.entries.clearRetainingCapacity();
}

pub fn bind(
    self: *Hotkeys,
    manager: *vicinae.HotkeyManagerV1,
    shortcuts: *GlobalShortcuts,
    config: *const Config,
) void {
    self.clear();

    var it = config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const leaf: Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |leaf| leaf.generic(),
        };
        if (!leaf.flags.global) continue;
        // Catch all global keybinds don't really make sense
        if (entry.key_ptr.key == .catch_all) continue;

        // Only single-action global keybinds are supported, as in the
        // portal implementation.
        const actions = leaf.actionsSlice();
        if (actions.len != 1) continue;

        self.entries.append(self.alloc, .{
            .hotkey = null,
            .trigger = entry.key_ptr.*,
            .action = actions[0],
            .shortcuts = shortcuts,
        }) catch {};
    }

    for (self.entries.items) |*entry| {
        entry.bind(manager, self.app_id) catch |err| {
            log.warn("failed to request hotkey trigger={f} err={}", .{
                entry.trigger,
                err,
            });
        };
    }
}

fn hotkeyListener(
    _: *vicinae.HotkeyV1,
    event: vicinae.HotkeyV1.Event,
    entry: *Entry,
) void {
    switch (event) {
        .bound => log.debug("hotkey bound action={f}", .{entry.action}),

        .denied => |v| {
            log.warn("hotkey denied action={f} reason={} message={s}", .{
                entry.action,
                v.reason,
                v.message,
            });
            entry.fail(v.message, false);
        },

        .revoked => |v| {
            log.warn("hotkey revoked action={f} reason={} message={s}", .{
                entry.action,
                v.reason,
                v.message,
            });
            entry.fail(v.message, true);
        },

        .pressed => entry.shortcuts.emitTrigger(&entry.action),
        .released => {},
    }
}
