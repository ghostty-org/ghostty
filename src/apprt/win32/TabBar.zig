/// Win32 TabBar — Windows Terminal-style tab bar integrated into the titlebar.
/// Renders rounded tabs, close buttons, a "+" new-tab button, and window
/// control buttons (minimize, maximize, close). Always visible as the custom
/// titlebar, even with a single tab.
const TabBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Window = @import("Window.zig");
const App = @import("App.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_tabbar);

const HWND = c.HWND;
const HDC = c.HDC;
const UINT = u32;
const WPARAM = c.WPARAM;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;

// ---------------------------------------------------------------
// Layout constants
// ---------------------------------------------------------------

/// Height of the tab bar in pixels.
pub const HEIGHT: i32 = 40;

/// Radius for rounded top corners on tabs.
const TAB_CORNER_RADIUS: i32 = 8;

/// Close button hit area on each tab.
const CLOSE_BTN_SIZE: i32 = 20;

/// Minimum tab width.
const MIN_TAB_WIDTH: i32 = 80;

/// Maximum tab width.
const MAX_TAB_WIDTH: i32 = 200;

/// Width of the "+" new-tab button.
const NEW_TAB_BTN_WIDTH: i32 = 36;

/// Total width of the three window control buttons (46px each).
const WINDOW_CONTROLS_WIDTH: i32 = 138;

/// Width of each individual window control button.
const WINDOW_CONTROL_BTN_WIDTH: i32 = 46;

/// Left padding inside a tab before text.
const TAB_PADDING_LEFT: i32 = 12;

/// Top margin above each tab (space between tab top and bar top).
const TAB_TOP_MARGIN: i32 = 8;

// ---------------------------------------------------------------
// Colors (dark theme)
// ---------------------------------------------------------------

const COLOR_TITLEBAR_BG = c.RGB(32, 32, 32);
const COLOR_TAB_HOVER = c.RGB(45, 45, 45);
const COLOR_TEXT_ACTIVE = c.RGB(255, 255, 255);
const COLOR_TEXT_INACTIVE = c.RGB(170, 170, 170);
const COLOR_CLOSE_HOVER_BG = c.RGB(200, 50, 50);
const COLOR_WINDOW_CLOSE_HOVER = c.RGB(196, 43, 28);
const COLOR_WINDOW_BTN_HOVER = c.RGB(55, 55, 55);
const COLOR_ICON = c.RGB(255, 255, 255);

// ---------------------------------------------------------------
// Hit-test zones (returned by hitTest)
// ---------------------------------------------------------------

pub const HitZone = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    minimize,
    maximize,
    close,
    caption,
};

// ---------------------------------------------------------------
// Fields
// ---------------------------------------------------------------

/// Child window handle.
hwnd: HWND,

/// Parent window.
window: *Window,

/// Number of tabs (cached for painting).
tab_count: usize = 0,

/// Active tab index (cached for painting).
active_idx: usize = 0,

/// Current hover zone.
hover_zone: HitZone = .none,

// ---------------------------------------------------------------
// Public API
// ---------------------------------------------------------------

pub fn create(window: *Window) !*TabBar {
    const alloc = window.app.core_app.alloc;
    const tab_bar = try alloc.create(TabBar);
    errdefer alloc.destroy(tab_bar);

    tab_bar.* = .{
        .hwnd = undefined,
        .window = window,
    };

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabBar");

    var parent_rect: c.RECT = undefined;
    if (c.GetClientRect(window.hwnd, &parent_rect) == 0) {
        parent_rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 0 };
    }

    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        0,
        0,
        parent_rect.right - parent_rect.left,
        HEIGHT,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    );

    if (hwnd == null) {
        log.err("Failed to create tab bar window", .{});
        return error.CreateWindowFailed;
    }

    tab_bar.hwnd = hwnd.?;
    _ = c.SetWindowLongPtrW(tab_bar.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(tab_bar)));

    log.info("Created tab bar", .{});
    return tab_bar;
}

pub fn deinit(self: *TabBar) void {
    _ = c.DestroyWindow(self.hwnd);
    const alloc = self.window.app.core_app.alloc;
    alloc.destroy(self);
}

/// Update the tab bar's state and repaint.
pub fn update(self: *TabBar, tab_count: usize, active_idx: usize) void {
    self.tab_count = tab_count;
    self.active_idx = active_idx;

    // Always visible — acts as the titlebar.
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);

    // Resize to fill parent width.
    var parent_rect: c.RECT = undefined;
    if (c.GetClientRect(self.window.hwnd, &parent_rect) != 0) {
        _ = c.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            parent_rect.right - parent_rect.left,
            HEIGHT,
            c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        );
    }

    _ = c.InvalidateRect(self.hwnd, null, 0);
}

/// The tab bar is always visible (it IS the titlebar).
pub fn isVisible(_: *const TabBar) bool {
    return true;
}

/// Hit test at the given point (in tab bar client coordinates).
pub fn hitTest(self: *const TabBar, x: i32, y: i32) HitZone {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) return .caption;
    const bar_width = rect.right - rect.left;

    // Window control buttons (right-aligned).
    const ctrl_left = bar_width - WINDOW_CONTROLS_WIDTH;
    if (x >= ctrl_left) {
        const btn_idx = @divTrunc(x - ctrl_left, WINDOW_CONTROL_BTN_WIDTH);
        return switch (btn_idx) {
            0 => .minimize,
            1 => .maximize,
            else => .close,
        };
    }

    // Tab area.
    const tw = self.tabWidth();
    if (self.tab_count > 0 and tw > 0) {
        const tabs_end: i32 = @as(i32, @intCast(self.tab_count)) * tw;

        // "+" new-tab button (right after tabs).
        if (x >= tabs_end and x < tabs_end + NEW_TAB_BTN_WIDTH) {
            return .new_tab;
        }

        // Individual tabs.
        if (x < tabs_end and y >= TAB_TOP_MARGIN) {
            const idx_i = @divTrunc(x, tw);
            if (idx_i >= 0) {
                const idx: usize = @intCast(idx_i);
                if (idx < self.tab_count) {
                    // Close button on tab.
                    const tab_right: i32 = @as(i32, @intCast(idx + 1)) * tw;
                    if (x >= tab_right - CLOSE_BTN_SIZE - 4 and x < tab_right - 4) {
                        // Only show close on active or hovered tabs.
                        const is_active = idx == self.active_idx;
                        const is_hover = switch (self.hover_zone) {
                            .tab => |hi| hi == idx,
                            .tab_close => |hi| hi == idx,
                            else => false,
                        };
                        if (is_active or is_hover) {
                            return .{ .tab_close = idx };
                        }
                    }
                    return .{ .tab = idx };
                }
            }
        }
    }

    // Empty space — caption for dragging.
    return .caption;
}

/// Map a hit zone to a WM_NCHITTEST return value.
pub fn hitTestToNCHIT(zone: HitZone) ?u32 {
    return switch (zone) {
        .caption => c.HTCAPTION,
        .minimize => c.HTMINBUTTON,
        .maximize => c.HTMAXBUTTON,
        .close => c.HTCLOSE,
        .none => null,
        .tab, .tab_close, .new_tab => null, // HTCLIENT — we handle these
    };
}

// ---------------------------------------------------------------
// Window Procedure
// ---------------------------------------------------------------

pub fn windowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    const tab_bar: ?*TabBar = if (ptr != 0)
        @ptrFromInt(@as(usize, @bitCast(ptr)))
    else
        null;

    switch (msg) {
        c.WM_PAINT => {
            if (tab_bar) |tb| {
                var ps: c.PAINTSTRUCT = undefined;
                const hdc = c.BeginPaint(hwnd, &ps);
                if (hdc) |dc| {
                    tb.paint(dc);
                }
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },

        c.WM_ERASEBKGND => {
            return 1;
        },

        c.WM_LBUTTONDOWN => {
            if (tab_bar) |tb| {
                const x = c.GET_X_LPARAM(lparam);
                const y = c.GET_Y_LPARAM(lparam);
                const zone = tb.hitTest(x, y);

                switch (zone) {
                    .new_tab => {
                        _ = c.PostMessageW(tb.window.hwnd, Window.WM_GHOSTTY_NEW_TAB, 0, 0);
                    },
                    .tab_close => |idx| {
                        _ = c.PostMessageW(tb.window.hwnd, Window.WM_GHOSTTY_CLOSE_TAB, idx, 0);
                    },
                    .tab => |idx| {
                        _ = c.PostMessageW(tb.window.hwnd, Window.WM_GHOSTTY_SELECT_TAB, idx, 0);
                    },
                    .minimize => {
                        _ = c.ShowWindow(tb.window.hwnd, c.SW_MINIMIZE);
                    },
                    .maximize => {
                        if (c.IsZoomed(tb.window.hwnd) != 0) {
                            _ = c.ShowWindow(tb.window.hwnd, c.SW_RESTORE);
                        } else {
                            _ = c.ShowWindow(tb.window.hwnd, c.SW_MAXIMIZE);
                        }
                    },
                    .close => {
                        _ = c.PostMessageW(tb.window.hwnd, c.WM_CLOSE, 0, 0);
                    },
                    .caption => {
                        // Let the parent handle caption drag.
                        // Forward as WM_NCLBUTTONDOWN + HTCAPTION.
                        _ = c.ReleaseCapture();
                        _ = c.PostMessageW(tb.window.hwnd, WM_NCLBUTTONDOWN, c.HTCAPTION, lparam);
                    },
                    .none => {},
                }
            }
            return 0;
        },

        c.WM_LBUTTONDBLCLK => {
            if (tab_bar) |tb| {
                const x = c.GET_X_LPARAM(lparam);
                const y = c.GET_Y_LPARAM(lparam);
                const zone = tb.hitTest(x, y);
                if (zone == .caption) {
                    // Double-click on empty area toggles maximize.
                    if (c.IsZoomed(tb.window.hwnd) != 0) {
                        _ = c.ShowWindow(tb.window.hwnd, c.SW_RESTORE);
                    } else {
                        _ = c.ShowWindow(tb.window.hwnd, c.SW_MAXIMIZE);
                    }
                }
            }
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (tab_bar) |tb| {
                const x = c.GET_X_LPARAM(lparam);
                const y = c.GET_Y_LPARAM(lparam);
                const new_zone = tb.hitTest(x, y);

                if (!hitZoneEql(new_zone, tb.hover_zone)) {
                    tb.hover_zone = new_zone;
                    _ = c.InvalidateRect(hwnd, null, 0);
                }

                // Request WM_MOUSELEAVE.
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
            if (tab_bar) |tb| {
                if (tb.hover_zone != .none) {
                    tb.hover_zone = .none;
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
            }
            return 0;
        },

        c.WM_DESTROY => {
            if (tab_bar) |_| {
                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------
// Painting
// ---------------------------------------------------------------

fn paint(self: *TabBar, hdc: HDC) void {
    var client_rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &client_rect) == 0) return;

    // 1. Fill entire bar with titlebar background.
    const bg_brush = c.CreateSolidBrush(COLOR_TITLEBAR_BG);
    defer _ = c.DeleteObject(@ptrCast(bg_brush));
    _ = c.FillRect(hdc, &client_rect, bg_brush);

    const old_bk = c.SetBkMode(hdc, c.TRANSPARENT);
    defer _ = c.SetBkMode(hdc, old_bk);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    if (self.tab_count > 0) {
        const tw = self.tabWidth();

        // 2. Draw each tab.
        for (0..self.tab_count) |i| {
            const x: i32 = @as(i32, @intCast(i)) * tw;
            const is_active = i == self.active_idx;
            const is_hover = switch (self.hover_zone) {
                .tab => |hi| hi == i,
                .tab_close => |hi| hi == i,
                else => false,
            };

            // Tab background (rounded top).
            if (is_active) {
                self.drawRoundedTab(hdc, x, tw, self.activeTabColor());
            } else if (is_hover) {
                self.drawRoundedTab(hdc, x, tw, COLOR_TAB_HOVER);
            }
            // Inactive + not hovered: no background (transparent = titlebar bg).

            // Tab text.
            const text_color: c.COLORREF = if (is_active) COLOR_TEXT_ACTIVE else COLOR_TEXT_INACTIVE;
            _ = c.SetTextColor(hdc, text_color);

            var title_buf: [64]u16 = undefined;
            const title_len = self.getTabTitle(i, &title_buf);
            var text_rect = c.RECT{
                .left = x + TAB_PADDING_LEFT,
                .top = TAB_TOP_MARGIN,
                .right = x + tw - CLOSE_BTN_SIZE - 8,
                .bottom = HEIGHT,
            };
            _ = c.DrawTextW(
                hdc,
                &title_buf,
                @intCast(title_len),
                &text_rect,
                c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
            );

            // Close button ("×") on active or hovered tabs.
            if (is_active or is_hover) {
                const close_hovered = switch (self.hover_zone) {
                    .tab_close => |hi| hi == i,
                    else => false,
                };

                const close_x = x + tw - CLOSE_BTN_SIZE - 4;
                const close_cy = TAB_TOP_MARGIN + @divTrunc(HEIGHT - TAB_TOP_MARGIN, 2);

                if (close_hovered) {
                    // Red circle background.
                    const close_bg = c.CreateSolidBrush(COLOR_CLOSE_HOVER_BG);
                    var close_bg_rect = c.RECT{
                        .left = close_x,
                        .top = close_cy - 10,
                        .right = close_x + CLOSE_BTN_SIZE,
                        .bottom = close_cy + 10,
                    };
                    _ = c.FillRect(hdc, &close_bg_rect, close_bg);
                    _ = c.DeleteObject(@ptrCast(close_bg));
                    _ = c.SetTextColor(hdc, COLOR_TEXT_ACTIVE);
                } else {
                    _ = c.SetTextColor(hdc, text_color);
                }

                // Draw "×" character.
                const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = TAB_TOP_MARGIN,
                    .right = close_x + CLOSE_BTN_SIZE,
                    .bottom = HEIGHT,
                };
                _ = c.DrawTextW(hdc, x_char, 1, &close_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
            }
        }

        // 3. "+" new-tab button.
        const plus_x: i32 = @as(i32, @intCast(self.tab_count)) * tw;
        const plus_hovered = self.hover_zone == .new_tab;
        if (plus_hovered) {
            const hover_brush = c.CreateSolidBrush(COLOR_TAB_HOVER);
            var hover_rect = c.RECT{
                .left = plus_x,
                .top = TAB_TOP_MARGIN,
                .right = plus_x + NEW_TAB_BTN_WIDTH,
                .bottom = HEIGHT,
            };
            _ = c.FillRect(hdc, &hover_rect, hover_brush);
            _ = c.DeleteObject(@ptrCast(hover_brush));
        }
        _ = c.SetTextColor(hdc, COLOR_TEXT_INACTIVE);
        const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
        var plus_rect = c.RECT{
            .left = plus_x,
            .top = TAB_TOP_MARGIN,
            .right = plus_x + NEW_TAB_BTN_WIDTH,
            .bottom = HEIGHT,
        };
        _ = c.DrawTextW(hdc, plus_char, 1, &plus_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
    }

    // 4. Window control buttons (right-aligned).
    const bar_width = client_rect.right - client_rect.left;
    self.drawWindowControls(hdc, bar_width);
}

/// Draw a tab with only the top corners rounded.
fn drawRoundedTab(self: *const TabBar, hdc: HDC, x: i32, tab_w: i32, color: c.COLORREF) void {
    _ = self;
    // Create a rounded-rect region that extends below the bar so the
    // bottom corners' rounding is clipped by the bar boundary.
    const radius = TAB_CORNER_RADIUS * 2;
    const rgn = c.CreateRoundRectRgn(
        x,
        TAB_TOP_MARGIN,
        x + tab_w + 1,
        HEIGHT + TAB_CORNER_RADIUS + 1, // extend past bottom to clip bottom rounding
        radius,
        radius,
    );
    if (rgn) |r| {
        const brush = c.CreateSolidBrush(color);
        _ = c.FillRgn(hdc, r, brush);
        _ = c.DeleteObject(@ptrCast(brush));
        _ = c.DeleteObject(@ptrCast(r));
    }
}

/// Draw the minimize, maximize, and close window control buttons.
fn drawWindowControls(self: *const TabBar, hdc: HDC, bar_width: i32) void {
    const ctrl_left = bar_width - WINDOW_CONTROLS_WIDTH;

    // Pen for drawing icons.
    const icon_pen = c.CreatePen(c.PS_SOLID, 1, COLOR_ICON);
    defer _ = c.DeleteObject(@ptrCast(icon_pen));
    const old_pen = c.SelectObject(hdc, @ptrCast(icon_pen));
    defer _ = c.SelectObject(hdc, old_pen);

    // For each of the three buttons: minimize, maximize, close.
    inline for (0..3) |btn_i| {
        const btn_left = ctrl_left + @as(i32, @intCast(btn_i)) * WINDOW_CONTROL_BTN_WIDTH;
        const btn_right = btn_left + WINDOW_CONTROL_BTN_WIDTH;
        const is_hovered = switch (self.hover_zone) {
            .minimize => btn_i == 0,
            .maximize => btn_i == 1,
            .close => btn_i == 2,
            else => false,
        };

        // Hover background.
        if (is_hovered) {
            const hover_color = if (btn_i == 2) COLOR_WINDOW_CLOSE_HOVER else COLOR_WINDOW_BTN_HOVER;
            const hover_brush = c.CreateSolidBrush(hover_color);
            var btn_rect = c.RECT{
                .left = btn_left,
                .top = 0,
                .right = btn_right,
                .bottom = HEIGHT,
            };
            _ = c.FillRect(hdc, &btn_rect, hover_brush);
            _ = c.DeleteObject(@ptrCast(hover_brush));
        }

        // Icon center.
        const cx = btn_left + @divTrunc(WINDOW_CONTROL_BTN_WIDTH, 2);
        const cy = @divTrunc(HEIGHT, 2);

        switch (btn_i) {
            0 => {
                // Minimize: horizontal line (─)
                _ = c.MoveToEx(hdc, cx - 5, cy, null);
                _ = c.LineTo(hdc, cx + 6, cy);
            },
            1 => {
                // Maximize: rectangle (□) or restore icon
                if (c.IsZoomed(self.window.hwnd) != 0) {
                    // Restore: two overlapping rectangles
                    // Back rectangle (offset up-right)
                    _ = c.MoveToEx(hdc, cx - 3, cy - 5, null);
                    _ = c.LineTo(hdc, cx + 5, cy - 5);
                    _ = c.LineTo(hdc, cx + 5, cy + 3);
                    // Connect to front
                    _ = c.MoveToEx(hdc, cx + 5, cy - 2, null);
                    _ = c.LineTo(hdc, cx + 2, cy - 2);
                    // Front rectangle
                    _ = c.MoveToEx(hdc, cx - 5, cy - 2, null);
                    _ = c.LineTo(hdc, cx + 3, cy - 2);
                    _ = c.LineTo(hdc, cx + 3, cy + 6);
                    _ = c.LineTo(hdc, cx - 5, cy + 6);
                    _ = c.LineTo(hdc, cx - 5, cy - 2);
                } else {
                    // Maximize: single rectangle
                    _ = c.MoveToEx(hdc, cx - 5, cy - 4, null);
                    _ = c.LineTo(hdc, cx + 5, cy - 4);
                    _ = c.LineTo(hdc, cx + 5, cy + 5);
                    _ = c.LineTo(hdc, cx - 5, cy + 5);
                    _ = c.LineTo(hdc, cx - 5, cy - 4);
                }
            },
            2 => {
                // Close: X shape
                _ = c.MoveToEx(hdc, cx - 5, cy - 5, null);
                _ = c.LineTo(hdc, cx + 6, cy + 6);
                _ = c.MoveToEx(hdc, cx + 5, cy - 5, null);
                _ = c.LineTo(hdc, cx - 6, cy + 6);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Get the active tab color from the theme's background color.
fn activeTabColor(self: *const TabBar) c.COLORREF {
    const bg = self.window.app.config.background;
    return c.RGB(bg.r, bg.g, bg.b);
}

/// Compute tab width based on available space (excluding controls).
fn tabWidth(self: *const TabBar) i32 {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) return MAX_TAB_WIDTH;
    const available = rect.right - rect.left - WINDOW_CONTROLS_WIDTH - NEW_TAB_BTN_WIDTH;
    if (self.tab_count == 0) return MAX_TAB_WIDTH;
    const per_tab = @divTrunc(available, @as(i32, @intCast(self.tab_count)));
    return @max(MIN_TAB_WIDTH, @min(MAX_TAB_WIDTH, per_tab));
}

/// Get the title for a tab, writing UTF-16 into the buffer.
fn getTabTitle(self: *const TabBar, tab_idx: usize, buf: []u16) usize {
    if (tab_idx < self.window.tabs.items.len) {
        const tab = &self.window.tabs.items[tab_idx];
        const surface = tab.activeSurface();
        if (surface.core_surface) |cs| {
            _ = cs;
            if (surface.getTitle()) |title| {
                const len = std.unicode.utf8ToUtf16Le(buf, title) catch 0;
                if (len > 0) return len;
            }
        }
    }

    // Fallback: "Tab N".
    var ascii_buf: [16]u8 = undefined;
    const ascii = std.fmt.bufPrint(&ascii_buf, "Tab {d}", .{tab_idx + 1}) catch "Tab";
    const len = std.unicode.utf8ToUtf16Le(buf, ascii) catch 0;
    return len;
}

fn hitZoneEql(a: HitZone, b: HitZone) bool {
    return switch (a) {
        .none => b == .none,
        .tab => |ai| switch (b) {
            .tab => |bi| ai == bi,
            else => false,
        },
        .tab_close => |ai| switch (b) {
            .tab_close => |bi| ai == bi,
            else => false,
        },
        .new_tab => b == .new_tab,
        .minimize => b == .minimize,
        .maximize => b == .maximize,
        .close => b == .close,
        .caption => b == .caption,
    };
}

// WM_NCLBUTTONDOWN constant
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
