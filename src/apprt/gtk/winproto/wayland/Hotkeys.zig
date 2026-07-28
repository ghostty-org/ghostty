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

/// Entries must have stable addresses: the hotkey listeners point to them.
arena: std.heap.ArenaAllocator,
entries: std.ArrayList(*Entry) = .empty,

const Entry = struct {
    /// Null once the binding was denied or revoked.
    hotkey: ?*vicinae.HotkeyV1,
    trigger: Binding.Trigger,
    action: Binding.Action,
    shortcuts: *GlobalShortcuts,

    fn fail(entry: *Entry, message: [*:0]const u8, revoked: bool) void {
        entry.hotkey.?.destroy();
        entry.hotkey = null;

        entry.shortcuts.emitBindFailed(&.{
            .trigger = entry.trigger,
            .action = entry.action,
            .message = message,
            .revoked = revoked,
        });
    }
};

pub fn init(alloc: Allocator, app_id: [:0]const u8) Allocator.Error!Hotkeys {
    return .{
        .alloc = alloc,
        .app_id = try alloc.dupeZ(u8, app_id),
        .arena = .init(alloc),
    };
}

/// Must leave the entries in a valid empty state: clear may still be
/// called after deinit during application teardown.
pub fn deinit(self: *Hotkeys) void {
    self.clear();
    self.arena.deinit();
    self.arena = .init(self.alloc);
    self.alloc.free(self.app_id);
}

pub fn clear(self: *Hotkeys) void {
    for (self.entries.items) |entry| {
        if (entry.hotkey) |hotkey| hotkey.destroy();
    }
    _ = self.arena.reset(.retain_capacity);
    self.entries = .empty;
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

        // Only single-action global keybinds are supported, as in the
        // portal implementation.
        const actions = leaf.actionsSlice();
        if (actions.len != 1) continue;

        self.bindOne(manager, shortcuts, entry.key_ptr.*, actions[0]) catch |err| {
            log.warn("failed to request hotkey trigger={f} err={}", .{
                entry.key_ptr.*,
                err,
            });
        };
    }
}

fn bindOne(
    self: *Hotkeys,
    manager: *vicinae.HotkeyManagerV1,
    shortcuts: *GlobalShortcuts,
    trigger: Binding.Trigger,
    action: Binding.Action,
) !void {
    const keysym = key.keysymFromTrigger(trigger) orelse return error.NoKeysym;

    var desc_buf: [256]u8 = undefined;
    const description = std.fmt.bufPrintZ(&desc_buf, "{f}", .{action}) catch "";

    const alloc = self.arena.allocator();
    const entry = try alloc.create(Entry);

    const hotkey = try manager.bind(
        keysym,
        .{
            .shift = trigger.mods.shift,
            .ctrl = trigger.mods.ctrl,
            .alt = trigger.mods.alt,
            .super = trigger.mods.super,
        },
        null,
        self.app_id.ptr,
        description.ptr,
    );
    errdefer hotkey.destroy();

    entry.* = .{
        .hotkey = hotkey,
        .trigger = trigger,
        .action = action,
        .shortcuts = shortcuts,
    };
    hotkey.setListener(*Entry, hotkeyListener, entry);
    try self.entries.append(alloc, entry);
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
