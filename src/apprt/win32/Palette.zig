//! The command palette: a box over the window with a search field and a list
//! of commands. Typing narrows the list, Enter runs the chosen command.
//!
//! The commands are the ones from the `command-palette-entry` setting, plus
//! one for each terminal that moves focus to it.
const Palette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

const class_name = c.utf16Literal("GhosttyPalette");

/// Sent from the search field to the palette window for the keys it handles.
const move_message = c.WM_APP + 10; // wparam: how many rows to move, as a signed value
const run_message = c.WM_APP + 11;
const close_message = c.WM_APP + 12;

/// The search field's original window function. All palettes share one kind of
/// control, so one is enough.
var edit_original: isize = 0;

const Entry = struct {
    title: []const u8,
    description: []const u8,
    what: union(enum) {
        /// Run a command, such as the ones in the configuration.
        action: *const input.Binding.Action,
        /// Move focus to a terminal.
        jump: *Surface,
    },
};

window: *Window,
/// The terminal the palette was opened from. Commands run on it.
origin: *Surface,
hwnd: c.Handle,
edit: c.Handle,
list: c.Handle,
/// Everything the palette allocates lives here and goes away with it.
arena: std.heap.ArenaAllocator,
entries: []const Entry,
/// Indexes into `entries` of what the list shows right now.
shown: std.ArrayList(usize),
background: ?c.Handle = null,

pub fn registerClass(instance: ?c.Handle) !void {
    if (c.RegisterClassExW(&.{
        .wnd_proc = wndProc,
        .instance = instance,
        .cursor = c.LoadCursorW(null, c.IDC_ARROW),
        .class_name = class_name,
    }) == 0) return error.RegisterClassFailed;
}

/// Show the palette over a window.
pub fn open(window: *Window, origin: *Surface) !*Palette {
    const app = window.app;
    const alloc = app.core_app.alloc;

    const self = try alloc.create(Palette);
    errdefer alloc.destroy(self);
    self.* = .{
        .window = window,
        .origin = origin,
        .hwnd = undefined,
        .edit = undefined,
        .list = undefined,
        .arena = .init(alloc),
        .entries = &.{},
        .shown = .empty,
    };
    errdefer self.arena.deinit();
    self.entries = try self.collectEntries();

    var client: c.Rect = undefined;
    _ = c.GetClientRect(window.hwnd, &client);
    const scale = window.scaleFactor();
    const width: i32 = @min(@as(i32, @intFromFloat(@round(620 * scale))), client.right - 20);
    const height: i32 = @min(@as(i32, @intFromFloat(@round(360 * scale))), client.bottom - 20);
    const left = @divTrunc(client.right - width, 2);
    const top: i32 = @intFromFloat(@round(30 * scale));

    const instance = c.GetModuleHandleW(null);
    self.hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.utf16Literal(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_BORDER | c.WS_CLIPCHILDREN,
        left,
        top,
        width,
        height,
        window.hwnd,
        null,
        instance,
        self,
    ) orelse return error.WindowCreateFailed;
    errdefer _ = c.DestroyWindow(self.hwnd);

    const margin: i32 = @intFromFloat(@round(6 * scale));
    const field_height: i32 = @intFromFloat(@round(26 * scale));
    self.edit = c.CreateWindowExW(
        0,
        c.utf16Literal("EDIT"),
        c.utf16Literal(""),
        c.WS_CHILD | c.WS_VISIBLE | c.ES_AUTOHSCROLL,
        margin,
        margin,
        width - 2 * margin,
        field_height,
        self.hwnd,
        null,
        instance,
        null,
    ) orelse return error.WindowCreateFailed;
    self.list = c.CreateWindowExW(
        0,
        c.utf16Literal("LISTBOX"),
        c.utf16Literal(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_VSCROLL | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT,
        margin,
        2 * margin + field_height,
        width - 2 * margin,
        height - 3 * margin - field_height - 2,
        self.hwnd,
        null,
        instance,
        null,
    ) orelse return error.WindowCreateFailed;

    if (c.GetStockObject(c.DEFAULT_GUI_FONT)) |font| {
        _ = c.SendMessageW(self.edit, c.WM_SETFONT, @intFromPtr(font), 1);
        _ = c.SendMessageW(self.list, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    edit_original = c.SetWindowLongPtrW(self.edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));

    const config = &app.config;
    self.background = c.CreateSolidBrush(c.rgb(
        lighten(config.background.r),
        lighten(config.background.g),
        lighten(config.background.b),
    ));

    try self.refilter();
    _ = c.BringWindowToTop(self.hwnd);
    _ = c.SetFocus(self.edit);
    return self;
}

fn lighten(channel: u8) u8 {
    return @intCast(@min(@as(u16, channel) + 18, 255));
}

fn collectEntries(self: *Palette) ![]const Entry {
    const app = self.window.app;
    const alloc = self.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;

    for (app.config.@"command-palette-entry".value.items) |*command| {
        // These make no sense here or are not available on Windows.
        switch (command.action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => continue,
            else => {},
        }
        try entries.append(alloc, .{
            .title = command.title,
            .description = command.description,
            .what = .{ .action = &command.action },
        });
    }

    // One entry per terminal, to move focus there.
    for (app.core_app.surfaces.items) |surface| {
        const title = try std.fmt.allocPrint(alloc, "Focus: {s}", .{surface.title orelse "Terminal"});
        try entries.append(alloc, .{
            .title = title,
            .description = "",
            .what = .{ .jump = surface },
        });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.ascii.lessThanIgnoreCase(a.title, b.title);
        }
    }.lessThan);
    return entries.toOwnedSlice(alloc);
}

/// Show only the commands that match what is typed in the search field.
fn refilter(self: *Palette) !void {
    const alloc = self.arena.allocator();

    var wide_buffer: [256]u16 = undefined;
    const length: usize = @intCast(@max(c.GetWindowTextW(self.edit, &wide_buffer, wide_buffer.len), 0));
    var needle_buffer: [512]u8 = undefined;
    const needle_length = std.unicode.utf16LeToUtf8(&needle_buffer, wide_buffer[0..length]) catch 0;
    const needle = std.mem.trim(u8, needle_buffer[0..needle_length], " ");

    self.shown.clearRetainingCapacity();
    _ = c.SendMessageW(self.list, c.LB_RESETCONTENT, 0, 0);

    for (self.entries, 0..) |entry, index| {
        const matches = needle.len == 0 or
            std.ascii.findIgnoreCase(entry.title, needle) != null or
            std.ascii.findIgnoreCase(entry.description, needle) != null;
        if (!matches) continue;
        try self.shown.append(alloc, index);

        // The title, with the description after it when there is one.
        var text_buffer: [768]u8 = undefined;
        const text = if (entry.description.len > 0)
            std.fmt.bufPrint(&text_buffer, "{s}    {s}", .{ entry.title, entry.description }) catch entry.title
        else
            entry.title;
        var line: [512:0]u16 = undefined;
        const line_length = std.unicode.utf8ToUtf16Le(&line, text) catch 0;
        line[@min(line_length, line.len - 1)] = 0;
        _ = c.SendMessageW(self.list, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&line)));
    }
    if (self.shown.items.len > 0) _ = c.SendMessageW(self.list, c.LB_SETCURSEL, 0, 0);
}

fn moveSelection(self: *Palette, delta: isize) void {
    const count: isize = @intCast(self.shown.items.len);
    if (count == 0) return;
    const current: isize = @intCast(c.SendMessageW(self.list, c.LB_GETCURSEL, 0, 0));
    const next = std.math.clamp(current + delta, 0, count - 1);
    _ = c.SendMessageW(self.list, c.LB_SETCURSEL, @intCast(next), 0);
}

/// Close the palette and run what is chosen.
fn run(self: *Palette) void {
    const row = c.SendMessageW(self.list, c.LB_GETCURSEL, 0, 0);
    if (row < 0 or row >= self.shown.items.len) return;
    const entry = self.entries[self.shown.items[@intCast(row)]];

    // Closing frees the palette, so what is needed is taken out first.
    const window = self.window;
    const origin = self.origin;
    window.closePalette();

    switch (entry.what) {
        .action => |action| {
            _ = origin.core_surface.performBindingAction(action.*) catch |err| {
                log.warn("palette command failed err={}", .{err});
            };
        },
        .jump => |surface| window.focusSurface(surface),
    }
}

fn wndProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const create: *const c.CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(create.create_params)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Palette = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        c.WM_DESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (self.background) |brush| _ = c.DeleteObject(brush);
            const alloc = self.window.app.core_app.alloc;
            self.arena.deinit();
            alloc.destroy(self);
            return 0;
        },

        c.WM_COMMAND => {
            const notification: u16 = @truncate(wparam >> 16);
            const from: usize = @bitCast(lparam);
            if (notification == c.EN_CHANGE and from == @intFromPtr(self.edit)) {
                self.refilter() catch |err| log.warn("palette filter failed err={}", .{err});
            } else if (notification == c.LBN_DBLCLK and from == @intFromPtr(self.list)) {
                self.run();
            }
            return 0;
        },

        move_message => {
            self.moveSelection(@bitCast(wparam));
            return 0;
        },
        run_message => {
            self.run();
            return 0;
        },
        close_message => {
            self.window.closePalette();
            self.origin.focus();
            return 0;
        },

        // Without this the terminal would show through between the fields.
        c.WM_ERASEBKGND => {
            if (self.background) |brush| {
                var client: c.Rect = undefined;
                _ = c.GetClientRect(hwnd, &client);
                _ = c.FillRect(@ptrFromInt(wparam), &client, brush);
            }
            return 1;
        },
        // Paint the fields in the terminal's colors, a little lighter.
        c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => {
            const config = &self.window.app.config;
            const hdc: c.Handle = @ptrFromInt(wparam);
            _ = c.SetTextColor(hdc, c.rgb(config.foreground.r, config.foreground.g, config.foreground.b));
            _ = c.SetBkColor(hdc, c.rgb(lighten(config.background.r), lighten(config.background.g), lighten(config.background.b)));
            return if (self.background) |brush| @bitCast(@intFromPtr(brush)) else 0;
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// The search field passes its navigation keys to the palette and otherwise
/// behaves like any text field.
fn editProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const parent = c.GetParent(hwnd);
    switch (msg) {
        c.WM_KEYDOWN => if (parent) |palette| {
            switch (wparam) {
                c.VK_UP => return post(palette, move_message, @bitCast(@as(isize, -1))),
                c.VK_DOWN => return post(palette, move_message, @bitCast(@as(isize, 1))),
                c.VK_PRIOR => return post(palette, move_message, @bitCast(@as(isize, -8))),
                c.VK_NEXT => return post(palette, move_message, @bitCast(@as(isize, 8))),
                c.VK_RETURN => return post(palette, run_message, 0),
                c.VK_ESCAPE => return post(palette, close_message, 0),
                else => {},
            }
        },
        // The field beeps at Enter and Escape unless they are swallowed.
        c.WM_CHAR => if (wparam == 0x0D or wparam == 0x1B) return 0,
        // Clicking away from the palette closes it. Clicking inside, such as
        // on the list, does not.
        c.WM_KILLFOCUS => if (parent) |palette| {
            const next: usize = wparam;
            const inside = next != 0 and (next == @intFromPtr(palette) or
                c.IsChild(palette, @ptrFromInt(next)) != 0);
            if (!inside) _ = c.PostMessageW(palette, close_message, 0, 0);
        },
        else => {},
    }
    return c.CallWindowProcW(edit_original, hwnd, msg, wparam, lparam);
}

fn post(palette: c.Handle, message: u32, wparam: usize) c.LRESULT {
    _ = c.PostMessageW(palette, message, wparam, 0);
    return 0;
}
