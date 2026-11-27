//! Talks to the Windows shell: the progress bar on a window's taskbar button
//! and desktop notifications.
const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const c = @import("c.zig");
const handoff = @import("handoff.zig");

const log = std.log.scoped(.win32_shell);

const Guid = handoff.Guid;
const HRESULT = i32;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(
    class_id: *const Guid,
    outer: ?*anyopaque,
    context: u32,
    interface_id: *const Guid,
    object: *?*anyopaque,
) callconv(.winapi) HRESULT;
extern "shell32" fn Shell_NotifyIconW(message: u32, data: *NotifyIconData) callconv(.winapi) c_int;
extern "user32" fn LoadIconW(instance: ?c.Handle, name: usize) callconv(.winapi) ?c.Handle;

const COINIT_APARTMENTTHREADED = 0x2;
const CLSCTX_INPROC_SERVER = 0x1;

// Taskbar progress

const clsid_taskbar_list = Guid.parse("56FDF344-FD6D-11D0-958A-006097C9A090");
const iid_taskbar_list3 = Guid.parse("EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF");

const ProgressFlags = struct {
    const none: u32 = 0x0;
    const indeterminate: u32 = 0x1;
    const normal: u32 = 0x2;
    const err: u32 = 0x4;
    const paused: u32 = 0x8;
};

/// ITaskbarList3, which Windows hands us as a table of functions. Only the
/// two progress calls are used. The rest are listed to keep the order right.
const TaskbarList = extern struct {
    vtable: *const Vtable,

    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*TaskbarList) callconv(.winapi) u32,
        // ITaskbarList
        hr_init: *const fn (*TaskbarList) callconv(.winapi) HRESULT,
        add_tab: *const anyopaque,
        delete_tab: *const anyopaque,
        activate_tab: *const anyopaque,
        set_active_alt: *const anyopaque,
        // ITaskbarList2
        mark_fullscreen_window: *const anyopaque,
        // ITaskbarList3
        set_progress_value: *const fn (*TaskbarList, c.Handle, u64, u64) callconv(.winapi) HRESULT,
        set_progress_state: *const fn (*TaskbarList, c.Handle, u32) callconv(.winapi) HRESULT,
    };
};

var taskbar: ?*TaskbarList = null;
var taskbar_failed = false;

fn taskbarList() ?*TaskbarList {
    if (taskbar) |existing| return existing;
    if (taskbar_failed) return null;

    // Safe to repeat. It reports that COM was already set up on this thread.
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);

    var object: ?*anyopaque = null;
    if (CoCreateInstance(&clsid_taskbar_list, null, CLSCTX_INPROC_SERVER, &iid_taskbar_list3, &object) < 0) {
        log.warn("could not create the taskbar object", .{});
        taskbar_failed = true;
        return null;
    }
    const list: *TaskbarList = @ptrCast(@alignCast(object.?));
    if (list.vtable.hr_init(list) < 0) {
        log.warn("could not initialize the taskbar object", .{});
        _ = list.vtable.release(list);
        taskbar_failed = true;
        return null;
    }
    taskbar = list;
    return list;
}

/// Show a progress report on the window's taskbar button.
pub fn setProgress(hwnd: c.Handle, report: terminal.osc.Command.ProgressReport) void {
    const list = taskbarList() orelse return;

    const flags: u32 = switch (report.state) {
        .remove => ProgressFlags.none,
        .set => ProgressFlags.normal,
        .@"error" => ProgressFlags.err,
        .indeterminate => ProgressFlags.indeterminate,
        .pause => ProgressFlags.paused,
    };
    _ = list.vtable.set_progress_state(list, hwnd, flags);

    // Only some states carry a percentage. The bar needs a value to show it.
    if (report.progress) |percent| {
        if (flags == ProgressFlags.normal or flags == ProgressFlags.err or flags == ProgressFlags.paused) {
            _ = list.vtable.set_progress_value(list, hwnd, @min(percent, 100), 100);
        }
    }
}

// Desktop notifications

const NotifyIconData = extern struct {
    size: u32 = @sizeOf(NotifyIconData),
    hwnd: ?c.Handle,
    id: u32,
    flags: u32,
    callback_message: u32 = 0,
    icon: ?c.Handle,
    tip: [128]u16 = @splat(0),
    state: u32 = 0,
    state_mask: u32 = 0,
    info: [256]u16 = @splat(0),
    timeout_or_version: u32 = 0,
    info_title: [64]u16 = @splat(0),
    info_flags: u32 = 0,
    item: Guid = std.mem.zeroes(Guid),
    balloon_icon: ?c.Handle = null,
};

const NIM_ADD = 0;
const NIM_MODIFY = 1;
const NIM_DELETE = 2;
const NIF_ICON = 0x2;
const NIF_TIP = 0x4;
const NIF_INFO = 0x10;
const NIIF_INFO = 0x1;
const IDI_APPLICATION = 32512;

/// The notification area entry that carries notifications. It only exists
/// while a notification is showing.
const notify_icon_id = 1;

/// How long the notification area entry stays, which also bounds how long
/// the notification does.
pub const notification_lifetime_ms = 10_000;

/// Show a notification from a window. Returns true when Windows accepted it.
pub fn notify(hwnd: c.Handle, title: []const u8, body: []const u8) bool {
    var data: NotifyIconData = .{
        .hwnd = hwnd,
        .id = notify_icon_id,
        .flags = NIF_ICON | NIF_TIP,
        .icon = LoadIconW(null, IDI_APPLICATION),
    };
    copyUtf8(&data.tip, "Ghostty");

    // An entry from an earlier notification is replaced rather than stacked.
    _ = Shell_NotifyIconW(NIM_DELETE, &data);
    if (Shell_NotifyIconW(NIM_ADD, &data) == 0) return false;

    data.flags = NIF_INFO;
    copyUtf8(&data.info_title, title);
    copyUtf8(&data.info, body);
    data.info_flags = NIIF_INFO;
    return Shell_NotifyIconW(NIM_MODIFY, &data) != 0;
}

/// Remove the notification area entry.
pub fn removeNotifyIcon(hwnd: c.Handle) void {
    var data: NotifyIconData = .{ .hwnd = hwnd, .id = notify_icon_id, .flags = 0, .icon = null };
    _ = Shell_NotifyIconW(NIM_DELETE, &data);
}

/// Copy text into a fixed UTF-16 buffer, cutting it short if needed and
/// always leaving the terminating zero.
fn copyUtf8(buffer: []u16, text: []const u8) void {
    @memset(buffer, 0);
    var index: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |codepoint| {
        var units: [2]u16 = undefined;
        const needed: usize = if (codepoint >= 0x10000) 2 else 1;
        if (index + needed >= buffer.len) break;
        if (needed == 2) {
            const value = codepoint - 0x10000;
            units[0] = @intCast(0xD800 + (value >> 10));
            units[1] = @intCast(0xDC00 + (value & 0x3FF));
        } else {
            units[0] = @intCast(codepoint);
        }
        @memcpy(buffer[index .. index + needed], units[0..needed]);
        index += needed;
    }
}

test "copyUtf8 truncates and terminates" {
    var small: [4]u16 = undefined;
    copyUtf8(&small, "abcdef");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 0 }, &small);

    var emoji: [3]u16 = undefined;
    // A character outside the basic plane takes two units, and does not fit
    // after the first letter in a buffer this size.
    copyUtf8(&emoji, "a\u{1F600}");
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0, 0 }, &emoji);
}

test "NotifyIconData matches the layout Windows expects" {
    try std.testing.expectEqual(@as(usize, 976), @sizeOf(NotifyIconData));
}
