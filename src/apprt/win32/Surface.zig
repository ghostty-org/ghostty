/// One terminal window. It owns the native window, receives its messages and
/// forwards them to the core surface, and paints the frames the renderer
/// produces.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const renderer = @import("../../renderer.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const clipboard = @import("clipboard.zig");
const Window = @import("Window.zig");
const Inspector = @import("Inspector.zig");
const c = @import("c.zig");
const key = @import("key.zig");

const log = std.log.scoped(.win32);

const class_name = c.utf16Literal("GhosttySurface");

/// Posted to ourselves to close the window outside of whatever core call
/// asked for it, so the core surface is never torn down underneath itself.
const close_message = c.WM_APP + 1;

/// Posted to destroy this terminal's window once the message being handled
/// has finished.
pub const destroy_message = c.WM_APP + 6;

app: *App,

/// The window this terminal is shown in. Its native window is a child of
/// that one.
window: *Window,

/// Where this terminal sits in its tab's split layout.
node: ?*Window.Node = null,

hwnd: c.Handle,
core_surface: CoreSurface,

/// False until the core surface is initialized. Windows delivers messages
/// during window creation, and those must not reach the core yet.
ready: bool,

title: ?[:0]u8 = null,

/// True while composition text, from a dead key or an input method, is
/// being shown at the cursor.
preedit_active: bool = false,

/// The inspector window, while it is open.
inspector_window: ?*Inspector = null,

/// The search box shown over the top right corner while searching, and what
/// the search found so far.
search_edit: ?c.Handle = null,
search_rect: c.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
search_total: ?usize = null,
search_selected: ?usize = null,

/// Where the visible rows sit in the scrollback. The scrollbar is drawn
/// from this, and only for a moment after it changes.
scrollbar: ?terminal.Scrollbar = null,
scrollbar_visible_until: u64 = 0,
cursor_pos: apprt.CursorPos = .{ .x = 0, .y = 0 },

/// The mouse cursor to show over the terminal, which the core chooses.
cursor: ?c.Handle = null,
mouse_hidden: bool = false,

/// The most recent frame from the renderer, already converted to the
/// bottom-up BGRA layout GDI expects. Kept so a repaint with no new frame
/// still has something to show.
pixels: []u8 = &.{},
pixels_width: u32 = 0,
pixels_height: u32 = 0,

pub fn registerClass(instance: ?c.Handle) !void {
    if (c.RegisterClassExW(&.{
        .style = c.CS_OWNDC,
        .wnd_proc = wndProc,
        .instance = instance,
        .cursor = c.LoadCursorW(null, c.IDC_ARROW),
        .class_name = class_name,
    }) == 0) return error.RegisterClassFailed;
}

/// Create a terminal as a child window filling the window's content area.
/// The caller places it in the window's layout.
pub fn create(window: *Window, context: apprt.surface.NewSurfaceContext) !*Surface {
    const app = window.app;
    const alloc = app.core_app.alloc;

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    self.* = .{
        .app = app,
        .window = window,
        .hwnd = undefined,
        .core_surface = undefined,
        .ready = false,
    };

    // The core reads our size and scale while it initializes, so the
    // window has to exist first.
    const rect = window.newSurfaceRect();
    self.hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.utf16Literal(""),
        c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN | c.WS_VISIBLE,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        window.hwnd,
        null,
        c.GetModuleHandleW(null),
        self,
    ) orelse return error.WindowCreateFailed;
    errdefer _ = c.DestroyWindow(self.hwnd);

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // A new terminal starts in the working directory of the one that had
    // focus, when the config asks for that and the shell reports it.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    errdefer self.core_surface.deinit();

    try self.core_surface.renderer.displayRealized();

    self.ready = true;
    return self;
}

pub fn deinit(self: *Surface) void {
    _ = self;
}

/// Show, hide or toggle the inspector.
pub fn controlInspector(self: *Surface, mode: apprt.action.Inspector) void {
    const showing = self.inspector_window != null;
    const want = switch (mode) {
        .toggle => !showing,
        .show => true,
        .hide => false,
    };
    if (want == showing) return;

    if (want) {
        self.inspector_window = Inspector.open(self) catch |err| {
            log.warn("could not open the inspector err={}", .{err});
            return;
        };
    } else if (self.inspector_window) |window| {
        window.close(false);
    }
}

/// The terminal changed in a way the inspector shows.
pub fn redrawInspector(self: *Surface) void {
    if (self.inspector_window) |window| window.invalidate();
}

/// Give this terminal the keyboard.
pub fn focus(self: *Surface) void {
    _ = c.SetFocus(self.hwnd);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *Surface) *App {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    _ = process_active;
    _ = c.PostMessageW(self.hwnd, close_message, 0, 0);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    const dpi: f32 = @floatFromInt(c.GetDpiForWindow(self.hwnd));
    const scale = dpi / 96.0;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    var rect: c.Rect = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) return error.WindowQueryFailed;
    return .{
        .width = @intCast(@max(rect.right - rect.left, 0)),
        .height = @intCast(@max(rect.bottom - rect.top, 0)),
    };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    // Windows has one clipboard. There is no selection or primary one.
    return clipboard_type == .standard;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard_type != .standard) return .unsupported;
    const alloc = self.app.core_app.alloc;

    switch (state) {
        .paste, .osc_52_read => {
            const text = clipboard.readText(alloc) catch |err| switch (err) {
                error.NoContent => return .unavailable,
                else => return err,
            };
            defer alloc.free(text);
            try self.completeRequest(state, &.{.{ .mime = clipboard.text_mime, .data = text }}, &.{});
            return .started;
        },

        // A program asks what kinds of content are on the clipboard.
        .list => {
            var buffer: [terminal.kitty.clipboard.max_listing_mimes][]const u8 = undefined;
            try self.completeRequest(state, &.{}, clipboard.availableMimes(&buffer));
            return .started;
        },

        // A program asks for content of the kinds it names.
        .kitty_read => |kitty| {
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();

            var contents: [terminal.kitty.clipboard.max_read_mimes]terminal.clipboard.Content = undefined;
            var count: usize = 0;
            for (kitty.mimes) |mime| {
                if (count >= contents.len) break;
                const data = (try clipboard.readMime(arena.allocator(), mime)) orelse continue;
                contents[count] = .{ .mime = mime, .data = data };
                count += 1;
            }

            var buffer: [terminal.kitty.clipboard.max_listing_mimes][]const u8 = undefined;
            const available: []const []const u8 = if (kitty.list) clipboard.availableMimes(&buffer) else &.{};
            try self.completeRequest(state, contents[0..count], available);
            return .started;
        },

        // A program has finished handing us content to put on the clipboard.
        .kitty_write => {
            try self.completeRequest(state, &.{}, &.{});
            return .started;
        },

        .osc_52_write => return .unsupported,
    }
}

/// Hand the answer to a clipboard request to the core. The core refuses
/// pastes that could run commands, and requests from programs that have not
/// been allowed, until the user has said yes.
fn completeRequest(
    self: *Surface,
    state: apprt.ClipboardRequest,
    contents: []const terminal.clipboard.Content,
    available: []const []const u8,
) !void {
    self.core_surface.completeClipboardRequest(state, .{
        .contents = contents,
        .available = available,
    }) catch |err| switch (err) {
        error.UnsafePaste => {
            if (!self.confirm(c.utf16Literal("The text being pasted contains line breaks, which can run commands as soon as it is pasted. Paste it anyway?"))) return;
            try self.core_surface.completeClipboardRequest(state, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            });
        },

        error.UnauthorizedPaste => {
            if (!self.confirm(c.utf16Literal("A program running in this terminal wants to use the clipboard. Allow it?"))) {
                // Nobody will answer the request now, so let go of it.
                switch (state) {
                    .kitty_read => |kitty| kitty.destroy(),
                    .kitty_write => |kitty| kitty.destroy(),
                    else => {},
                }
                return;
            }
            try self.core_surface.completeClipboardRequest(state, .{
                .contents = contents,
                .available = available,
                .confirmed = true,
            });
        },

        else => return err,
    };
}

/// Ask a yes or no question. The answer defaults to no.
fn confirm(self: *Surface, message: [*:0]const u16) bool {
    return c.MessageBoxW(
        self.hwnd,
        message,
        c.utf16Literal("Ghostty"),
        c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2,
    ) == c.IDYES;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm_first: bool,
) !void {
    if (clipboard_type != .standard) return;
    if (confirm_first and !self.confirm(c.utf16Literal("A program running in this terminal wants to change the clipboard. Allow it?"))) return;

    var items: [16]clipboard.Item = undefined;
    var count: usize = 0;
    for (contents) |content| {
        if (count >= items.len) break;
        items[count] = .{ .mime = content.mime, .data = content.data };
        count += 1;
    }
    clipboard.write(self.app.core_app.alloc, self.hwnd, items[0..count]) catch |err| switch (err) {
        // Nothing of a kind that can be stored.
        error.NoContent => {},
        else => return err,
    };
}
pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}

pub fn setCursorShape(self: *Surface, shape: @import("../../terminal/mouse.zig").Shape) void {
    const id: usize = switch (shape) {
        .default => c.IDC_ARROW,
        .text, .vertical_text => c.IDC_IBEAM,
        .pointer, .grab, .grabbing, .alias, .copy => c.IDC_HAND,
        .help, .context_menu => c.IDC_HELP,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .cell, .crosshair => c.IDC_CROSS,
        .move, .all_scroll => c.IDC_SIZEALL,
        .no_drop, .not_allowed => c.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => c.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => c.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => c.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => c.IDC_SIZENWSE,
        .zoom_in, .zoom_out => c.IDC_ARROW,
    };
    self.cursor = c.LoadCursorW(null, id);
}

pub fn setMouseHidden(self: *Surface, hidden: bool) void {
    self.mouse_hidden = hidden;
}

pub fn ringBell(self: *Surface) void {
    _ = self;
    _ = c.MessageBeep(0);
}

// Search

/// Sent by the search box to its terminal window, which does the work.
const search_next_message = c.WM_APP + 3;
const search_previous_message = c.WM_APP + 4;
const search_end_message = c.WM_APP + 5;

/// The search box's original window function, which ours hands everything
/// else to. All search boxes are the same kind of control, so one is enough.
var search_edit_original: isize = 0;

/// Show the search box, and put the cursor in it.
pub fn startSearch(self: *Surface, needle: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;

    if (self.search_edit == null) {
        const edit = c.CreateWindowExW(
            0,
            c.utf16Literal("EDIT"),
            c.utf16Literal(""),
            c.WS_CHILD | c.WS_VISIBLE | c.WS_BORDER | c.ES_AUTOHSCROLL | c.WS_CLIPSIBLINGS,
            0,
            0,
            10,
            10,
            self.hwnd,
            null,
            c.GetModuleHandleW(null),
            null,
        ) orelse return error.WindowCreateFailed;
        if (c.GetStockObject(c.DEFAULT_GUI_FONT)) |font| {
            _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(font), 1);
        }
        search_edit_original = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&searchEditProc)));
        self.search_edit = edit;
        self.search_total = null;
        self.search_selected = null;
    }
    const edit = self.search_edit.?;

    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, needle);
    defer alloc.free(wide);
    _ = c.SetWindowTextW(edit, wide);

    self.layoutSearch();
    _ = c.SetFocus(edit);
    // Select what is there, so typing replaces the old search.
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    self.invalidate();
}

pub fn endSearch(self: *Surface) void {
    const edit = self.search_edit orelse return;
    self.search_edit = null;
    self.search_total = null;
    self.search_selected = null;
    _ = c.DestroyWindow(edit);
    _ = c.SetFocus(self.hwnd);
    self.invalidate();
}

pub fn setSearchTotal(self: *Surface, total: ?usize) void {
    self.search_total = total;
    self.invalidate();
}

pub fn setSearchSelected(self: *Surface, selected: ?usize) void {
    self.search_selected = selected;
    self.invalidate();
}

/// Put the search box in the top right corner.
fn layoutSearch(self: *Surface) void {
    const edit = self.search_edit orelse return;
    var client: c.Rect = undefined;
    if (c.GetClientRect(self.hwnd, &client) == 0) return;
    const scale = (self.getContentScale() catch return).x;

    const width: i32 = @intFromFloat(@round(240 * scale));
    const height: i32 = @intFromFloat(@round(24 * scale));
    const margin: i32 = @intFromFloat(@round(10 * scale));
    self.search_rect = .{
        .left = @max(client.right - width - margin, 0),
        .top = margin,
        .right = @max(client.right - margin, width),
        .bottom = margin + height,
    };
    _ = c.SetWindowPos(
        edit,
        null,
        self.search_rect.left,
        self.search_rect.top,
        width,
        height,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// The text in the search box changed, so search for it.
fn searchChanged(self: *Surface) !void {
    const edit = self.search_edit orelse return;
    const alloc = self.app.core_app.alloc;

    const length: usize = @intCast(@max(c.GetWindowTextLengthW(edit), 0));
    const wide = try alloc.alloc(u16, length + 1);
    defer alloc.free(wide);
    const copied: usize = @intCast(@max(c.GetWindowTextW(edit, wide.ptr, @intCast(wide.len)), 0));

    const text = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..copied]);
    defer alloc.free(text);
    _ = try self.core_surface.performBindingAction(.{ .search = text });
}

/// Draw "3 / 12" beside the search box.
fn drawSearchCount(self: *Surface, hdc: c.Handle) void {
    if (self.search_edit == null) return;
    const total = self.search_total orelse return;
    const scale = (self.getContentScale() catch return).x;

    var buffer: [48]u8 = undefined;
    const text = if (self.search_selected) |selected|
        std.fmt.bufPrint(&buffer, "{d} / {d}", .{ selected + 1, total }) catch return
    else
        std.fmt.bufPrint(&buffer, "{d} found", .{total}) catch return;

    var wide: [48]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return;

    const config = &self.app.config;
    var box: c.Rect = .{
        .left = self.search_rect.left - @as(i32, @intFromFloat(@round(96 * scale))),
        .top = self.search_rect.top,
        .right = self.search_rect.left - @as(i32, @intFromFloat(@round(6 * scale))),
        .bottom = self.search_rect.bottom,
    };
    if (c.CreateSolidBrush(c.rgb(config.background.r, config.background.g, config.background.b))) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &box, brush);
    }
    const old_font = if (c.GetStockObject(c.DEFAULT_GUI_FONT)) |font| c.SelectObject(hdc, font) else null;
    defer if (old_font) |old| {
        _ = c.SelectObject(hdc, old);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, c.rgb(config.foreground.r, config.foreground.g, config.foreground.b));
    _ = c.DrawTextW(hdc, &wide, @intCast(length), &box, c.DT_RIGHT | c.DT_VCENTER | c.DT_SINGLELINE);
}

/// Enter and Escape in the search box go to the terminal window. Everything
/// else is ordinary text editing.
fn searchEditProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_KEYDOWN => {
            if (c.GetParent(hwnd)) |parent| {
                if (wparam == c.VK_RETURN) {
                    // Shift+Enter goes back to the previous match.
                    const shift = c.GetKeyState(c.VK_SHIFT) < 0;
                    _ = c.PostMessageW(parent, if (shift) search_previous_message else search_next_message, 0, 0);
                    return 0;
                }
                if (wparam == c.VK_ESCAPE) {
                    _ = c.PostMessageW(parent, search_end_message, 0, 0);
                    return 0;
                }
            }
        },
        // The control beeps at Enter and Escape unless they are swallowed.
        c.WM_CHAR => if (wparam == 0x0D or wparam == 0x1B) return 0,
        else => {},
    }
    return c.CallWindowProcW(search_edit_original, hwnd, msg, wparam, lparam);
}

/// The scrollbar fades out this long after the last change to it.
const scrollbar_visible_ms = 1200;
const scrollbar_timer_id = 1;

pub fn setScrollbar(self: *Surface, value: terminal.Scrollbar) void {
    // Nothing to scroll means nothing to show.
    self.scrollbar = if (value.total > value.len) value else null;
    if (self.scrollbar == null) {
        self.invalidate();
        return;
    }

    self.scrollbar_visible_until = c.GetTickCount64() + scrollbar_visible_ms;
    // Repaint once the time is up so the bar disappears.
    _ = c.SetTimer(self.hwnd, scrollbar_timer_id, scrollbar_visible_ms + 100, null);
    self.invalidate();
}

/// Draw the scrollbar over the right edge, if it should be showing.
fn drawScrollbar(self: *Surface, hdc: c.Handle) void {
    if (self.app.config.scrollbar == .never) return;
    const bar = self.scrollbar orelse return;
    if (c.GetTickCount64() > self.scrollbar_visible_until) return;

    var client: c.Rect = undefined;
    if (c.GetClientRect(self.hwnd, &client) == 0) return;
    const height: f32 = @floatFromInt(client.bottom - client.top);
    const total: f32 = @floatFromInt(bar.total);
    const scale = (self.getContentScale() catch return).x;

    const width: i32 = @intFromFloat(@round(6 * scale));
    const margin: i32 = @intFromFloat(@round(2 * scale));
    const min_thumb: f32 = 24 * scale;
    const thumb_height = @max(height * @as(f32, @floatFromInt(bar.len)) / total, min_thumb);
    const travel = @max(height - thumb_height, 0);
    const scrollable: f32 = @floatFromInt(bar.total - bar.len);
    const top: i32 = @intFromFloat(travel * @as(f32, @floatFromInt(@min(bar.offset, bar.total - bar.len))) / scrollable);

    const config = &self.app.config;
    const thumb: c.Rect = .{
        .left = client.right - width - margin,
        .top = top,
        .right = client.right - margin,
        .bottom = top + @as(i32, @intFromFloat(thumb_height)),
    };
    // A solid color between the background and text, since there is no
    // transparency to draw with here.
    const color = c.rgb(
        mixChannel(config.background.r, config.foreground.r),
        mixChannel(config.background.g, config.foreground.g),
        mixChannel(config.background.b, config.foreground.b),
    );
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &thumb, brush);
}

fn mixChannel(background: u8, foreground: u8) u8 {
    const b: f32 = @floatFromInt(background);
    const f: f32 = @floatFromInt(foreground);
    return @intFromFloat(@round(b + (f - b) * 0.4));
}

pub fn invalidate(self: *Surface) void {
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;

    const copy = try alloc.dupeSentinel(u8, title, 0);
    if (self.title) |old| alloc.free(old);
    self.title = copy;

    self.window.titleChanged(self);
}

fn wndProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const create_struct: *const c.CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(
            hwnd,
            c.GWLP_USERDATA,
            @bitCast(@intFromPtr(create_struct.create_params)),
        );
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Surface = @ptrFromInt(@as(usize, @bitCast(ptr)));

    return self.handleMessage(msg, wparam, lparam) catch |err| {
        log.warn("error handling window message msg=0x{x} err={}", .{ msg, err });
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    };
}

fn handleMessage(
    self: *Surface,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !c.LRESULT {

    switch (msg) {
        c.WM_DESTROY => {
            self.destroy();
            return 0;
        },
        close_message => {
            self.window.closeSurface(self);
            return 0;
        },
        destroy_message => {
            _ = c.DestroyWindow(self.hwnd);
            return 0;
        },
        else => {},
    }
    if (!self.ready) return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        search_next_message => {
            _ = try self.core_surface.performBindingAction(.{ .navigate_search = .next });
            return 0;
        },
        search_previous_message => {
            _ = try self.core_surface.performBindingAction(.{ .navigate_search = .previous });
            return 0;
        },
        search_end_message => {
            _ = try self.core_surface.performBindingAction(.end_search);
            return 0;
        },

        c.WM_COMMAND => {
            const notification: u16 = @truncate(wparam >> 16);
            const from: usize = @bitCast(lparam);
            if (notification == c.EN_CHANGE and self.search_edit != null and from == @intFromPtr(self.search_edit.?)) {
                try self.searchChanged();
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wparam == scrollbar_timer_id) {
                _ = c.KillTimer(self.hwnd, scrollbar_timer_id);
                self.invalidate();
            }
            return 0;
        },

        c.WM_PAINT => {
            try self.paint();
            return 0;
        },

        c.WM_PRINTCLIENT => {
            try self.paintTo(@ptrFromInt(wparam));
            return 0;
        },

        c.WM_SIZE => {
            const size = self.getSize() catch return 0;
            if (size.width == 0 or size.height == 0) return 0;
            try self.core_surface.sizeCallback(size);
            self.layoutSearch();
            return 0;
        },

        c.WM_SETFOCUS => {
            self.window.surfaceFocused(self);
            try self.core_surface.focusCallback(true);
            self.updateImePosition();
            return 0;
        },

        // We draw the composition text ourselves at the cursor, so the
        // input method's own composition window stays hidden. Its candidate
        // list is still shown.
        c.WM_IME_SETCONTEXT => {
            return c.DefWindowProcW(self.hwnd, msg, wparam, lparam & ~c.ISC_SHOWUICOMPOSITIONWINDOW);
        },
        c.WM_IME_STARTCOMPOSITION => {
            self.updateImePosition();
            return 0;
        },
        c.WM_IME_COMPOSITION => {
            try self.imeComposition(lparam);
            return 0;
        },
        c.WM_IME_ENDCOMPOSITION => {
            try self.setPreedit(null);
            return 0;
        },
        c.WM_KILLFOCUS => {
            try self.core_surface.focusCallback(false);
            return 0;
        },

        c.WM_SETCURSOR => {
            const hit_test: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (hit_test != 1) return c.DefWindowProcW(self.hwnd, msg, wparam, lparam); // HTCLIENT
            _ = c.SetCursor(if (self.mouse_hidden) null else self.cursor orelse c.LoadCursorW(null, c.IDC_IBEAM));
            return 1;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            const repeat = (lparam >> 30) & 1 == 1;
            try self.keyEvent(if (repeat) .repeat else .press, wparam, lparam);
            return self.systemKeyResult(msg, wparam, lparam);
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => {
            try self.keyEvent(.release, wparam, lparam);
            return self.systemKeyResult(msg, wparam, lparam);
        },

        c.WM_MOUSEMOVE => {
            self.cursor_pos = .{
                .x = @floatFromInt(c.loword(lparam)),
                .y = @floatFromInt(c.hiword(lparam)),
            };
            try self.core_surface.cursorPosCallback(self.cursor_pos, currentMods());
            return 0;
        },
        c.WM_LBUTTONDOWN => return try self.mouseButton(lparam, .press, .left),
        c.WM_LBUTTONUP => return try self.mouseButton(lparam, .release, .left),
        c.WM_RBUTTONDOWN => return try self.mouseButton(lparam, .press, .right),
        c.WM_RBUTTONUP => return try self.mouseButton(lparam, .release, .right),
        c.WM_MBUTTONDOWN => return try self.mouseButton(lparam, .press, .middle),
        c.WM_MBUTTONUP => return try self.mouseButton(lparam, .release, .middle),

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            // A wheel notch is 120 units. Positive means up or right.
            const notches: f64 = @as(f64, @floatFromInt(c.hiword(@bitCast(wparam)))) / 120.0;
            const x: f64 = if (msg == c.WM_MOUSEHWHEEL) notches else 0;
            const y: f64 = if (msg == c.WM_MOUSEWHEEL) notches else 0;
            try self.core_surface.scrollCallback(x, y, .{});
            return 0;
        },

        else => return c.DefWindowProcW(self.hwnd, msg, wparam, lparam),
    }
}

/// Keys pressed with Alt arrive as system messages. Windows needs to see
/// Alt+F4 and Alt+Space to close the window and open its menu, but
/// everything else belongs to the terminal.
fn systemKeyResult(self: *Surface, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {
    if (msg != c.WM_SYSKEYDOWN and msg != c.WM_SYSKEYUP) return 0;
    if (wparam == c.VK_F4 or wparam == c.VK_SPACE) return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
    return 0;
}

fn mouseButton(
    self: *Surface,
    lparam: isize,
    state: input.MouseButtonState,
    button: input.MouseButton,
) !c.LRESULT {
    // The core decides where a click landed from the last pointer position
    // it was given, so give it this click's position first. A pointer move
    // normally arrives before a click, but not always.
    self.cursor_pos = .{
        .x = @floatFromInt(c.loword(lparam)),
        .y = @floatFromInt(c.hiword(lparam)),
    };
    switch (state) {
        .press => _ = c.SetCapture(self.hwnd),
        .release => _ = c.ReleaseCapture(),
    }
    _ = try self.core_surface.mouseButtonCallback(state, button, currentMods());
    return 0;
}

fn keyEvent(self: *Surface, action: input.Action, vk: usize, lparam: isize) !void {
    // An input method is handling this key. What it produces arrives later
    // as IME messages.
    if (vk == c.VK_PROCESSKEY) return;

    const lparam_bits: usize = @bitCast(lparam);
    const extended = (lparam_bits >> 24) & 1 == 1;
    const scan_code: u32 = @truncate((lparam_bits >> 16) & 0xFF);

    var mods = currentMods();
    var text: KeyText = .none;
    if (action != .release) {
        if (!mods.ctrl and !mods.alt or isAltGr()) {
            // Plain typing goes through Windows' own translation, which is
            // the only way to get dead keys like ´ followed by e giving é.
            const composed = self.composeText(vk, lparam);
            if (composed.dead) {
                try self.setPreedit(composed.text.slice());
                return;
            }
            text = composed.text;
            text.unshifted = KeyText.unshiftedCodepoint(@intCast(vk), scan_code);
            if (isAltGr()) {
                mods.ctrl = false;
                mods.alt = false;
            }
        } else {
            text = KeyText.translate(@intCast(vk), scan_code, &mods);
        }
    }

    // Text that arrives ends any composition in progress.
    if (text.len > 0) try self.setPreedit(null);

    _ = try self.core_surface.keyCallback(.{
        .action = action,
        .key = key.fromVirtualKey(@intCast(vk), extended, scan_code),
        .mods = mods,
        .consumed_mods = .{ .shift = text.len > 0 and mods.shift },
        .utf8 = text.slice(),
        .unshifted_codepoint = text.unshifted,
    });
}

/// What the keyboard layout makes of a key press, including dead keys.
/// A dead key such as ´ produces no character by itself. It waits for the
/// next key and combines with it.
const Composed = struct {
    text: KeyText,
    dead: bool,
};

/// Run a key press through Windows' translation and read back the
/// characters it produced.
fn composeText(self: *Surface, vk: usize, lparam: isize) Composed {
    const down: c.Msg = .{
        .hwnd = self.hwnd,
        .message = c.WM_KEYDOWN,
        .wparam = vk,
        .lparam = lparam,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
        .private = 0,
    };
    // This posts WM_CHAR or WM_DEADCHAR messages for the key, and keeps the
    // layout's dead key state up to date.
    _ = c.TranslateMessage(&down);

    var units: [8]u16 = undefined;
    var count: usize = 0;
    var dead = false;
    var message: c.Msg = undefined;
    while (c.PeekMessageW(&message, self.hwnd, c.WM_CHAR, c.WM_SYSDEADCHAR, c.PM_REMOVE) != 0) {
        const unit: u16 = @truncate(message.wparam);
        switch (message.message) {
            c.WM_CHAR, c.WM_SYSCHAR => {
                if (dead) {
                    dead = false;
                    count = 0;
                }
                if (count < units.len) {
                    units[count] = unit;
                    count += 1;
                }
            },
            c.WM_DEADCHAR, c.WM_SYSDEADCHAR => {
                dead = true;
                units[0] = unit;
                count = 1;
            },
            else => {},
        }
    }

    var result: KeyText = .none;
    if (count == 0) return .{ .text = result, .dead = false };

    // Control characters such as Enter and Escape are described by the key
    // itself, not by text. A dead key's accent is always real text.
    if (!dead and (units[0] < 0x20 or units[0] == 0x7F)) return .{ .text = result, .dead = false };

    result.len = std.unicode.utf16LeToUtf8(&result.buf, units[0..count]) catch 0;
    return .{ .text = result, .dead = dead and result.len > 0 };
}

/// Show or clear the in-progress composition text at the cursor.
fn setPreedit(self: *Surface, text: ?[]const u8) !void {
    const active = if (text) |t| t.len > 0 else false;
    if (!active and !self.preedit_active) return;

    self.preedit_active = active;
    try self.core_surface.preeditCallback(if (active) text else null);
    self.updateImePosition();
}

/// Tell the input method where the cursor is so its candidate list appears
/// next to it.
fn updateImePosition(self: *Surface) void {
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    // The core reports the point in scaled units. Asking for a scale of one
    // gives device pixels, which is what the window wants.
    const point = self.core_surface.imePointScaled(.{ .x = 1, .y = 1 });
    const x: i32 = @intFromFloat(point.x);
    const bottom: i32 = @intFromFloat(point.y);
    const top: i32 = @intFromFloat(point.y - point.height);

    _ = c.ImmSetCompositionWindow(himc, &.{ .style = c.CFS_POINT, .current_pos = .{ .x = x, .y = top } });
    _ = c.ImmSetCandidateWindow(himc, &.{ .index = 0, .style = c.CFS_CANDIDATEPOS, .current_pos = .{ .x = x, .y = bottom } });
}

/// The input method changed its composition. Show what is being composed,
/// and send what was finished as typed text.
fn imeComposition(self: *Surface, lparam: isize) !void {
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
    const alloc = self.app.core_app.alloc;

    if (flags & c.GCS_RESULTSTR != 0) {
        if (try imeString(alloc, himc, c.GCS_RESULTSTR)) |committed| {
            defer alloc.free(committed);
            try self.setPreedit(null);
            _ = try self.core_surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .utf8 = committed,
            });
        }
    }

    if (flags & c.GCS_COMPSTR != 0) {
        const composing = try imeString(alloc, himc, c.GCS_COMPSTR);
        defer if (composing) |text| alloc.free(text);
        try self.setPreedit(composing);
    }

    self.updateImePosition();
}

fn imeString(alloc: Allocator, himc: c.Handle, which: u32) !?[]u8 {
    const bytes = c.ImmGetCompositionStringW(himc, which, null, 0);
    if (bytes <= 0) return null;

    const wide = try alloc.alloc(u16, @as(usize, @intCast(bytes)) / 2);
    defer alloc.free(wide);
    _ = c.ImmGetCompositionStringW(himc, which, wide.ptr, @intCast(bytes));
    return try std.unicode.utf16LeToUtf8Alloc(alloc, wide);
}

/// AltGr is how many layouts type characters like @ and €. Windows
/// reports it as Ctrl and Alt held together.
fn isAltGr() bool {
    return isDown(c.VK_RMENU) and isDown(c.VK_LCONTROL);
}

/// The state of the modifier keys right now.
fn currentMods() input.Mods {
    return .{
        .shift = isDown(c.VK_SHIFT),
        .ctrl = isDown(c.VK_CONTROL),
        .alt = isDown(c.VK_MENU),
        .super = isDown(c.VK_LWIN) or isDown(c.VK_RWIN),
        .caps_lock = c.GetKeyState(c.VK_CAPITAL) & 1 == 1,
        .num_lock = c.GetKeyState(c.VK_NUMLOCK) & 1 == 1,
    };
}

fn isDown(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

/// The text a key press produces under the current keyboard layout.
const KeyText = struct {
    buf: [8]u8 = undefined,
    len: usize = 0,

    /// What the key produces with no modifiers held, which the core uses
    /// to match keybindings independent of the layout's shifted symbols.
    unshifted: u21 = 0,

    const none: KeyText = .{};

    fn slice(self: *const KeyText) []const u8 {
        return self.buf[0..self.len];
    }

    /// Ctrl and Alt are left out of the translation so that Ctrl+C yields
    /// "c" rather than a control character. The exception is AltGr, which
    /// Windows reports as Ctrl+Alt and which produces real characters on
    /// many layouts. In that case the modifiers are consumed and cleared.
    fn translate(vk: u32, scan_code: u32, mods: *input.Mods) KeyText {
        var state: [256]u8 = undefined;
        if (c.GetKeyboardState(&state) == 0) return .none;

        const alt_gr = isDown(c.VK_RMENU) and isDown(c.VK_LCONTROL);
        if (alt_gr) {
            mods.ctrl = false;
            mods.alt = false;
        } else {
            for ([_]usize{ c.VK_CONTROL, 0xA2, 0xA3, c.VK_MENU, 0xA4, 0xA5 }) |i| state[i] = 0;
        }

        var result: KeyText = .none;
        result.fill(vk, scan_code, &state);

        result.unshifted = unshiftedCodepoint(vk, scan_code);
        return result;
    }

    /// The character a key makes with no modifiers held and caps lock off.
    fn unshiftedCodepoint(vk: u32, scan_code: u32) u21 {
        var state: [256]u8 = undefined;
        if (c.GetKeyboardState(&state) == 0) return 0;
        for ([_]usize{ c.VK_SHIFT, 0xA0, 0xA1, c.VK_CAPITAL, c.VK_CONTROL, 0xA2, 0xA3, c.VK_MENU, 0xA4, 0xA5 }) |i| state[i] = 0;

        var plain: KeyText = .none;
        plain.fill(vk, scan_code, &state);
        if (plain.len == 0) return 0;
        return std.unicode.utf8Decode(plain.slice()) catch 0;
    }

    fn fill(self: *KeyText, vk: u32, scan_code: u32, state: *const [256]u8) void {
        var wide: [4]u16 = undefined;
        // Flag 4 keeps the call from disturbing the keyboard's dead key
        // state. Dead key composition is not supported yet.
        const count = c.ToUnicodeEx(
            vk,
            scan_code,
            state,
            &wide,
            wide.len,
            4,
            c.GetKeyboardLayout(0),
        );
        if (count <= 0) return;

        // Control characters such as Enter and Escape are described by the
        // key itself, not by text.
        if (wide[0] < 0x20 or wide[0] == 0x7F) return;

        self.len = std.unicode.utf16LeToUtf8(&self.buf, wide[0..@intCast(count)]) catch 0;
    }
};

fn paint(self: *Surface) !void {
    var ps: c.PaintStruct = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    try self.paintTo(hdc);
}

/// Draw the newest frame into a device context. Used for normal painting
/// and for WM_PRINTCLIENT, which screenshot tools send to capture a window.
fn paintTo(self: *Surface, hdc: c.Handle) !void {
    try self.takeLatestFrame();
    if (self.pixels_width == 0) return;

    const info: c.BitmapInfoHeader = .{
        .width = @intCast(self.pixels_width),
        .height = @intCast(self.pixels_height),
    };
    _ = c.SetDIBitsToDevice(
        hdc,
        0,
        0,
        self.pixels_width,
        self.pixels_height,
        0,
        0,
        0,
        self.pixels_height,
        self.pixels.ptr,
        &info,
        c.DIB_RGB_COLORS,
    );
    self.drawScrollbar(hdc);
    self.drawSearchCount(hdc);
}

/// Replace our stored pixels with the renderer's newest frame, if any.
fn takeLatestFrame(self: *Surface) !void {
    const frame = self.core_surface.renderer.takeFrame() orelse return;
    switch (frame) {
        .memory => |memory| {
            defer memory.deinit();
            try self.storePixels(memory);
        },
        // Windows never produces these, but the type is shared.
        .dmabuf => |dmabuf| dmabuf.deinit(),
    }
}

fn storePixels(self: *Surface, memory: renderer.Renderer.ExportedFrame.Memory) !void {
    const alloc = self.app.core_app.alloc;
    const len = memory.pixels.len;
    if (self.pixels.len != len) {
        alloc.free(self.pixels);
        self.pixels = &.{};
        self.pixels = try alloc.alloc(u8, len);
    }

    // The renderer produces RGBA and GDI wants BGRA, so swap red and blue.
    // Rows are already bottom-up, which is what a positive-height DIB uses.
    var i: usize = 0;
    while (i + 3 < len) : (i += 4) {
        self.pixels[i] = memory.pixels[i + 2];
        self.pixels[i + 1] = memory.pixels[i + 1];
        self.pixels[i + 2] = memory.pixels[i];
        self.pixels[i + 3] = memory.pixels[i + 3];
    }
    self.pixels_width = memory.width;
    self.pixels_height = memory.height;
}

/// The window is gone. Release the core surface and everything we own.
fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    // The terminal stops its own inspector as it goes, so the window only
    // has to close.
    if (self.inspector_window) |inspector| inspector.close(true);

    if (self.ready) {
        self.ready = false;
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
    }

    if (self.title) |title| alloc.free(title);
    alloc.free(self.pixels);
    alloc.destroy(self);
}