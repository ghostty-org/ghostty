/// Win32 SearchBar — a search overlay that docks to the top of a Surface.
/// Contains an edit control for typing search queries, a match count label,
/// and navigation/close functionality.
const SearchBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_searchbar);

const HWND = c.HWND;
const HDC = c.HDC;
const UINT = u32;
const WPARAM = c.WPARAM;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;

// ---------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------

/// Height of the search bar in pixels.
pub const HEIGHT: i32 = 30;

/// Padding from the right edge of the surface.
const RIGHT_MARGIN: i32 = 8;

/// Width of the search bar panel.
const BAR_WIDTH: i32 = 360;

/// Width of the edit control.
const EDIT_WIDTH: i32 = 200;

/// Width of nav buttons (up/down arrows).
const NAV_BTN_WIDTH: i32 = 24;

/// Width of close button.
const CLOSE_BTN_WIDTH: i32 = 24;

/// Padding between elements.
const PADDING: i32 = 4;

/// Edit control child ID (for WM_COMMAND).
const EDIT_ID: u16 = 100;

// ---------------------------------------------------------------
// Colors
// ---------------------------------------------------------------

const COLOR_BG = c.RGB(45, 45, 45);
const COLOR_BORDER = c.RGB(80, 80, 80);
const COLOR_TEXT = c.RGB(255, 255, 255);
const COLOR_TEXT_DIM = c.RGB(170, 170, 170);
const COLOR_BTN_HOVER = c.RGB(65, 65, 65);

// ---------------------------------------------------------------
// Hit zones
// ---------------------------------------------------------------

const HitZone = enum {
    none,
    prev_btn,
    next_btn,
    close_btn,
};

// ---------------------------------------------------------------
// Fields
// ---------------------------------------------------------------

/// The search bar window (container).
hwnd: HWND,

/// The edit control for search text input.
edit_hwnd: HWND,

/// The parent surface.
surface: *Surface,

/// Total number of matches (null = unknown/no search).
total: ?usize = null,

/// Currently selected match index, 1-based (null = none).
selected: ?usize = null,

/// Whether the bar is currently visible.
is_visible: bool = false,

/// Current hover zone for button highlighting.
hover_zone: HitZone = .none,

// ---------------------------------------------------------------
// Public API
// ---------------------------------------------------------------

pub fn create(surface: *Surface) !*SearchBar {
    const alloc = surface.app.core_app.alloc;
    const bar = try alloc.create(SearchBar);
    errdefer alloc.destroy(bar);

    bar.* = .{
        .hwnd = undefined,
        .edit_hwnd = undefined,
        .surface = surface,
    };

    // Compute initial position relative to the Window client area.
    var surface_rect: c.RECT = undefined;
    if (c.GetWindowRect(surface.hwnd, &surface_rect) == 0) {
        surface_rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    }
    var pt = c.POINT{ .x = surface_rect.left, .y = surface_rect.top };
    _ = c.ScreenToClient(surface.window.hwnd, &pt);

    var surface_client: c.RECT = undefined;
    if (c.GetClientRect(surface.hwnd, &surface_client) == 0) {
        surface_client = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    }
    const surface_width = surface_client.right - surface_client.left;
    const bar_x = pt.x + @max(0, surface_width - BAR_WIDTH - RIGHT_MARGIN);

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchBar");

    // Create the search bar container as a child of the top-level Window,
    // so it sits above the renderer (OpenGL/D3D11) in the Z-order.
    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        @max(0, bar_x),
        pt.y,
        BAR_WIDTH,
        HEIGHT,
        surface.window.hwnd,
        null,
        surface.app.hinstance,
        null,
    );

    if (hwnd == null) {
        log.err("Failed to create search bar window", .{});
        return error.CreateWindowFailed;
    }

    bar.hwnd = hwnd.?;
    _ = c.SetWindowLongPtrW(bar.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(bar)));

    // Create the edit control inside the search bar.
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const edit_hwnd = c.CreateWindowExW(
        0,
        edit_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.WS_VISIBLE | c.ES_AUTOHSCROLL | c.ES_LEFT,
        PADDING,
        4,
        EDIT_WIDTH,
        HEIGHT - 8,
        bar.hwnd,
        @ptrFromInt(@as(usize, EDIT_ID)),
        surface.app.hinstance,
        null,
    );

    if (edit_hwnd == null) {
        log.err("Failed to create edit control", .{});
        _ = c.DestroyWindow(bar.hwnd);
        return error.CreateWindowFailed;
    }

    bar.edit_hwnd = edit_hwnd.?;

    log.info("Created search bar", .{});
    return bar;
}

pub fn deinit(self: *SearchBar) void {
    _ = c.DestroyWindow(self.hwnd);
    const alloc = self.surface.app.core_app.alloc;
    alloc.destroy(self);
}

/// Show the search bar with an optional initial needle.
pub fn show(self: *SearchBar, needle: [:0]const u8) void {
    self.is_visible = true;
    self.total = null;
    self.selected = null;

    // Reposition to the right of the surface.
    self.reposition();

    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);

    // Set needle text if provided.
    if (needle.len > 0) {
        var wide_buf: [512]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, needle) catch 0;
        if (wide_len < wide_buf.len) {
            wide_buf[wide_len] = 0;
            _ = c.SendMessageW(self.edit_hwnd, c.WM_SETTEXT, 0, @bitCast(@intFromPtr(&wide_buf)));
            // Select all text.
            _ = c.SendMessageW(self.edit_hwnd, c.EM_SETSEL, 0, @bitCast(@as(isize, -1)));
        }
    }

    // Focus the edit control.
    _ = c.SetFocus(self.edit_hwnd);
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

/// Hide the search bar and clear state.
pub fn hide(self: *SearchBar) void {
    self.is_visible = false;
    self.total = null;
    self.selected = null;
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);

    // Return focus to the parent surface.
    _ = c.SetFocus(self.surface.hwnd);
}

/// Update the total match count.
pub fn updateTotal(self: *SearchBar, total_val: ?usize) void {
    self.total = total_val;
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

/// Update the selected match index (1-based).
pub fn updateSelected(self: *SearchBar, selected_val: ?usize) void {
    self.selected = selected_val;
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

/// Reposition the search bar to the top-right of the surface,
/// in Window client coordinates (since the search bar is a child of Window).
pub fn reposition(self: *SearchBar) void {
    // Get the surface's screen position and convert to Window client coords.
    var surface_rect: c.RECT = undefined;
    if (c.GetWindowRect(self.surface.hwnd, &surface_rect) == 0) return;

    var pt = c.POINT{ .x = surface_rect.left, .y = surface_rect.top };
    _ = c.ScreenToClient(self.surface.window.hwnd, &pt);

    var surface_client: c.RECT = undefined;
    if (c.GetClientRect(self.surface.hwnd, &surface_client) == 0) return;

    const surface_width = surface_client.right - surface_client.left;
    const bar_x = pt.x + @max(0, surface_width - BAR_WIDTH - RIGHT_MARGIN);

    _ = c.SetWindowPos(
        self.hwnd,
        null, // HWND_TOP
        bar_x,
        pt.y,
        BAR_WIDTH,
        HEIGHT,
        c.SWP_NOACTIVATE,
    );
}

// ---------------------------------------------------------------
// Window procedure
// ---------------------------------------------------------------

pub fn windowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    const bar: ?*SearchBar = if (ptr != 0)
        @ptrFromInt(@as(usize, @bitCast(ptr)))
    else
        null;

    switch (msg) {
        c.WM_PAINT => {
            if (bar) |b| {
                var ps: c.PAINTSTRUCT = undefined;
                const hdc = c.BeginPaint(hwnd, &ps);
                if (hdc) |dc| {
                    b.paint(dc);
                }
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        c.WM_ERASEBKGND => {
            return 1;
        },

        c.WM_COMMAND => {
            if (bar) |b| {
                const notify_code = @as(u16, @truncate((wparam >> 16) & 0xFFFF));
                const ctrl_id = @as(u16, @truncate(wparam & 0xFFFF));
                if (ctrl_id == EDIT_ID and notify_code == c.EN_CHANGE) {
                    b.onEditChanged();
                }
            }
            return 0;
        },

        c.WM_CTLCOLOREDIT => {
            // Style the edit control colors.
            const hdc_edit: c.HDC = @ptrFromInt(@as(usize, @bitCast(wparam)));
            _ = c.SetTextColor(hdc_edit, COLOR_TEXT);
            _ = c.SetBkColor(hdc_edit, COLOR_BG);
            // Return a dark brush for the background.
            return @bitCast(@intFromPtr(getOrCreateBgBrush()));
        },

        c.WM_LBUTTONDOWN => {
            if (bar) |b| {
                const x = c.GET_X_LPARAM(lparam);
                const y = c.GET_Y_LPARAM(lparam);
                const zone = b.hitTest(x, y);
                switch (zone) {
                    .close_btn => b.closeSearch(),
                    .next_btn => b.navigateNext(),
                    .prev_btn => b.navigatePrev(),
                    .none => {},
                }
            }
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (bar) |b| {
                const x = c.GET_X_LPARAM(lparam);
                const y = c.GET_Y_LPARAM(lparam);
                const new_zone = b.hitTest(x, y);
                if (new_zone != b.hover_zone) {
                    b.hover_zone = new_zone;
                    _ = c.InvalidateRect(hwnd, null, 0);
                }

                var tme = c.TRACKMOUSEEVENT{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = c.TrackMouseEvent(&tme);
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            if (bar) |b| {
                if (b.hover_zone != .none) {
                    b.hover_zone = .none;
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
            }
            return 0;
        },

        c.WM_DESTROY => {
            if (bar) |_| {
                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Subclass proc for the edit control to capture Enter and Escape.
pub fn editSubclassProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    // Get the SearchBar pointer from the parent window.
    const parent = c.GetParent(hwnd);
    if (parent == null) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    const ptr = c.GetWindowLongPtrW(parent.?, c.GWLP_USERDATA);
    const bar: ?*SearchBar = if (ptr != 0)
        @ptrFromInt(@as(usize, @bitCast(ptr)))
    else
        null;

    if (bar) |b| {
        switch (msg) {
            c.WM_KEYDOWN => {
                const vk: u8 = @truncate(wparam & 0xFF);
                switch (vk) {
                    c.VK_RETURN => {
                        // Shift+Enter = previous, Enter = next
                        if (c.GetKeyState(c.VK_SHIFT) < 0) {
                            b.navigatePrev();
                        } else {
                            b.navigateNext();
                        }
                        return 0;
                    },
                    c.VK_ESCAPE => {
                        b.closeSearch();
                        return 0;
                    },
                    else => {},
                }
            },
            c.WM_CHAR => {
                const ch: u16 = @truncate(wparam & 0xFFFF);
                // Suppress the beep for Enter key
                if (ch == '\r') return 0;
            },
            else => {},
        }
    }

    // Call the original EDIT window procedure.
    return c.CallWindowProcW(getEditOrigProc(), hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------
// Painting
// ---------------------------------------------------------------

fn paint(self: *SearchBar, hdc: HDC) void {
    var client_rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client_rect) == 0) return;

    // Fill background.
    const bg_brush = c.CreateSolidBrush(COLOR_BG);
    defer _ = c.DeleteObject(@ptrCast(bg_brush));
    _ = c.FillRect(hdc, &client_rect, bg_brush);

    // Draw border.
    const border_brush = c.CreateSolidBrush(COLOR_BORDER);
    defer _ = c.DeleteObject(@ptrCast(border_brush));
    var border_rect = client_rect;
    _ = c.FrameRect(hdc, &border_rect, border_brush);

    const old_bk = c.SetBkMode(hdc, c.TRANSPARENT);
    defer _ = c.SetBkMode(hdc, old_bk);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    // Draw match count label after the edit control.
    const label_x = PADDING + EDIT_WIDTH + PADDING;
    self.drawMatchLabel(hdc, label_x);

    // Draw navigation buttons.
    const nav_x = BAR_WIDTH - CLOSE_BTN_WIDTH - NAV_BTN_WIDTH * 2 - PADDING;
    self.drawNavButton(hdc, nav_x, .prev_btn);
    self.drawNavButton(hdc, nav_x + NAV_BTN_WIDTH, .next_btn);

    // Draw close button.
    const close_x = BAR_WIDTH - CLOSE_BTN_WIDTH - PADDING;
    self.drawCloseButton(hdc, close_x);
}

fn drawMatchLabel(self: *SearchBar, hdc: HDC, x: i32) void {
    var buf: [32]u8 = undefined;
    const label = if (self.total) |t| blk: {
        if (self.selected) |s| {
            break :blk std.fmt.bufPrint(&buf, "{d}/{d}", .{ s, t }) catch "?/?";
        } else {
            break :blk std.fmt.bufPrint(&buf, "{d}", .{t}) catch "?";
        }
    } else "";

    if (label.len == 0) return;

    var wide_buf: [64]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, label) catch 0;
    if (wide_len == 0) return;

    _ = c.SetTextColor(hdc, COLOR_TEXT_DIM);
    var label_rect = c.RECT{
        .left = x,
        .top = 0,
        .right = x + 80,
        .bottom = HEIGHT,
    };
    _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &label_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
}

fn drawNavButton(self: *SearchBar, hdc: HDC, x: i32, which: HitZone) void {
    const is_hover = self.hover_zone == which;
    if (is_hover) {
        const hover_brush = c.CreateSolidBrush(COLOR_BTN_HOVER);
        var btn_rect = c.RECT{
            .left = x,
            .top = 2,
            .right = x + NAV_BTN_WIDTH,
            .bottom = HEIGHT - 2,
        };
        _ = c.FillRect(hdc, &btn_rect, hover_brush);
        _ = c.DeleteObject(@ptrCast(hover_brush));
    }

    // Draw arrow character.
    const arrow: [*]const u16 = if (which == .prev_btn)
        std.unicode.utf8ToUtf16LeStringLiteral("\u{25B2}") // Up triangle
    else
        std.unicode.utf8ToUtf16LeStringLiteral("\u{25BC}"); // Down triangle

    _ = c.SetTextColor(hdc, COLOR_TEXT);
    var arrow_rect = c.RECT{
        .left = x,
        .top = 0,
        .right = x + NAV_BTN_WIDTH,
        .bottom = HEIGHT,
    };
    _ = c.DrawTextW(hdc, arrow, 1, &arrow_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
}

fn drawCloseButton(self: *SearchBar, hdc: HDC, x: i32) void {
    const is_hover = self.hover_zone == .close_btn;
    if (is_hover) {
        const hover_brush = c.CreateSolidBrush(COLOR_BTN_HOVER);
        var btn_rect = c.RECT{
            .left = x,
            .top = 2,
            .right = x + CLOSE_BTN_WIDTH,
            .bottom = HEIGHT - 2,
        };
        _ = c.FillRect(hdc, &btn_rect, hover_brush);
        _ = c.DeleteObject(@ptrCast(hover_brush));
    }

    _ = c.SetTextColor(hdc, COLOR_TEXT);
    const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign
    var close_rect = c.RECT{
        .left = x,
        .top = 0,
        .right = x + CLOSE_BTN_WIDTH,
        .bottom = HEIGHT,
    };
    _ = c.DrawTextW(hdc, x_char, 1, &close_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
}

// ---------------------------------------------------------------
// Hit test
// ---------------------------------------------------------------

fn hitTest(self: *const SearchBar, x: i32, y: i32) HitZone {
    _ = y;
    _ = self;
    const nav_x = BAR_WIDTH - CLOSE_BTN_WIDTH - NAV_BTN_WIDTH * 2 - PADDING;
    const close_x = BAR_WIDTH - CLOSE_BTN_WIDTH - PADDING;

    if (x >= close_x and x < close_x + CLOSE_BTN_WIDTH) return .close_btn;
    if (x >= nav_x and x < nav_x + NAV_BTN_WIDTH) return .prev_btn;
    if (x >= nav_x + NAV_BTN_WIDTH and x < nav_x + NAV_BTN_WIDTH * 2) return .next_btn;
    return .none;
}

// ---------------------------------------------------------------
// Actions
// ---------------------------------------------------------------

fn onEditChanged(self: *SearchBar) void {
    // Get the current text from the edit control.
    var wide_buf: [512]u16 = undefined;
    const len = c.GetWindowTextW(self.edit_hwnd, &wide_buf, wide_buf.len);
    if (len <= 0) {
        // Empty text — clear search.
        if (self.surface.core_surface) |cs| {
            _ = cs.performBindingAction(.{ .search = "" }) catch return;
        }
        return;
    }

    const wide_slice = wide_buf[0..@intCast(len)];

    // Convert to UTF-8.
    var utf8_buf: [512]u8 = undefined;
    const alloc = self.surface.app.core_app.alloc;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide_slice) catch return;
    defer alloc.free(utf8);

    if (utf8.len >= utf8_buf.len) return;
    @memcpy(utf8_buf[0..utf8.len], utf8);
    utf8_buf[utf8.len] = 0;
    const utf8z: [:0]const u8 = utf8_buf[0..utf8.len :0];

    if (self.surface.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .search = utf8z }) catch return;
    }
}

fn navigateNext(self: *SearchBar) void {
    if (self.surface.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .navigate_search = .next }) catch return;
    }
}

fn navigatePrev(self: *SearchBar) void {
    if (self.surface.core_surface) |cs| {
        _ = cs.performBindingAction(.{ .navigate_search = .previous }) catch return;
    }
}

fn closeSearch(self: *SearchBar) void {
    if (self.surface.core_surface) |cs| {
        _ = cs.performBindingAction(.end_search) catch return;
    }
}

// ---------------------------------------------------------------
// Static helpers
// ---------------------------------------------------------------

/// Store the original EDIT window procedure for subclassing.
var edit_orig_proc: ?c.WNDPROC = null;

pub fn getEditOrigProc() c.WNDPROC {
    return edit_orig_proc orelse &c.DefWindowProcW;
}

pub fn setEditOrigProc(proc: c.WNDPROC) void {
    edit_orig_proc = proc;
}

/// Cached dark background brush (static).
var bg_brush_cached: c.HBRUSH = null;

fn getOrCreateBgBrush() c.HBRUSH {
    if (bg_brush_cached == null) {
        bg_brush_cached = c.CreateSolidBrush(COLOR_BG);
    }
    return bg_brush_cached;
}

