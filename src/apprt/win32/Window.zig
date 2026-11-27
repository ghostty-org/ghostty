//! A top-level window. It holds a row of tabs, and each tab holds a tree of
//! split terminal surfaces. Surfaces are child windows laid out inside it.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Palette = @import("Palette.zig");
const c = @import("c.zig");
const shell = @import("shell.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.win32);

const class_name = c.utf16Literal("GhosttyWindow");

/// Logical sizes, scaled by the display's DPI before use.
const tab_bar_height = 34;
const tab_max_width = 220;
const divider_width = 4;
const min_split_ratio: f32 = 0.1;

const no_rect: c.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

pub const Orientation = enum { side_by_side, stacked };

/// One cell of a tab's layout: either a terminal or a split of two cells.
pub const Node = struct {
    parent: ?*Node = null,
    kind: Kind,
    rect: c.Rect = no_rect,

    pub const Kind = union(enum) {
        leaf: *Surface,
        split: Split,
    };

    pub const Split = struct {
        orientation: Orientation,
        ratio: f32 = 0.5,
        first: *Node,
        second: *Node,
        divider: c.Rect = no_rect,
    };
};

pub const Tab = struct {
    root: *Node,
    /// The terminal that has, or last had, keyboard focus in this tab.
    active: *Surface,
    title: ?[:0]u8 = null,
    /// When set, this terminal fills the whole tab and the others are hidden.
    zoomed: ?*Surface = null,
};

app: *App,
hwnd: c.Handle,

/// True for the drop-down terminal, which is a window of its own kind.
quick: bool = false,
tabs: std.ArrayList(*Tab) = .empty,
active_tab: usize = 0,

/// The smallest client area the core allows, in pixels. Zero means none.
min_client: c.Point = .{ .x = 0, .y = 0 },

/// The window's style and position from before it went fullscreen.
fullscreen: ?struct { style: i32, placement: c.WindowPlacement } = null,

/// The split whose divider is being dragged with the mouse.
dragging: ?*Node = null,

/// The command palette, while it is open.
palette: ?*Palette = null,

/// True while the grid of tab pictures is showing, and which tab is chosen.
overview: bool = false,
overview_selected: usize = 0,

/// Set while the mouse button is held on a tab, which becomes a drag once
/// the pointer has moved far enough.
tab_drag: ?struct { start_x: i32, moved: bool } = null,

font: ?c.Handle = null,

pub fn registerClass(instance: ?c.Handle) !void {
    if (c.RegisterClassExW(&.{
        .wnd_proc = wndProc,
        .instance = instance,
        .cursor = c.LoadCursorW(null, c.IDC_ARROW),
        .class_name = class_name,
    }) == 0) return error.RegisterClassFailed;
}

pub fn create(app: *App) !*Window {
    return createWindow(app, false);
}

/// The drop-down terminal. It has no frame or taskbar button, floats above
/// other windows and sits against one edge of the screen.
pub fn createQuick(app: *App) !*Window {
    return createWindow(app, true);
}

fn createWindow(app: *App, quick: bool) !*Window {
    const alloc = app.core_app.alloc;

    const self = try alloc.create(Window);
    self.* = .{ .app = app, .hwnd = undefined, .quick = quick };

    const hwnd = c.CreateWindowExW(
        if (quick) c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST else 0,
        class_name,
        c.utf16Literal("Ghostty"),
        if (quick) c.WS_POPUP | c.WS_CLIPCHILDREN else c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        1000,
        640,
        null,
        null,
        c.GetModuleHandleW(null),
        self,
    ) orelse {
        alloc.destroy(self);
        return error.WindowCreateFailed;
    };
    // Destroying the window frees `self` through WM_DESTROY.
    errdefer _ = c.DestroyWindow(hwnd);

    if (quick) {
        app.quick = self;
        self.placeQuick();
    } else {
        app.normal_windows += 1;
        self.applyTheme();
        self.applyPosition();
    }
    self.applyTranslucency();
    _ = try self.newTab();

    if (quick) {
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.SetForegroundWindow(self.hwnd);
        if (self.activeTab()) |tab| _ = c.SetFocus(tab.active.hwnd);
        return self;
    }
    _ = c.ShowWindow(self.hwnd, if (app.config.maximize) c.SW_MAXIMIZE else c.SW_SHOW);
    if (app.config.fullscreen != .false) self.toggleFullscreen();
    return self;
}

/// Put the drop-down terminal against its edge of the screen the pointer is
/// on, at the size the config asks for.
fn placeQuick(self: *Window) void {
    var cursor: c.Point = undefined;
    _ = c.GetCursorPos(&cursor);
    const monitor = c.MonitorFromPoint(cursor, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MonitorInfo = .{};
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;
    const work = info.work;

    const config = &self.app.config;
    const area_width: i32 = work.right - work.left;
    const area_height: i32 = work.bottom - work.top;
    const position = config.@"quick-terminal-position";
    const size = config.@"quick-terminal-size".calculate(position, .{
        .width = @intCast(area_width),
        .height = @intCast(area_height),
    });
    const width: i32 = @min(@as(i32, @intCast(size.width)), area_width);
    const height: i32 = @min(@as(i32, @intCast(size.height)), area_height);

    const centered_x = work.left + @divTrunc(area_width - width, 2);
    const centered_y = work.top + @divTrunc(area_height - height, 2);
    const x: i32, const y: i32 = switch (position) {
        .top => .{ centered_x, work.top },
        .bottom => .{ centered_x, work.bottom - height },
        .left => .{ work.left, centered_y },
        .right => .{ work.right - width, centered_y },
        .center => .{ centered_x, centered_y },
    };
    _ = c.SetWindowPos(self.hwnd, @ptrFromInt(c.HWND_TOPMOST), x, y, width, height, c.SWP_NOACTIVATE);
}

/// Show the drop-down terminal if it is hidden, and hide it if it shows.
pub fn toggleQuick(self: *Window) void {
    if (c.IsWindowVisible(self.hwnd) != 0) {
        _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        return;
    }
    self.placeQuick();
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(self.hwnd);
    if (self.activeTab()) |tab| _ = c.SetFocus(tab.active.hwnd);
}

/// Make the title bar fit the terminal's colors. A dark terminal gets a dark
/// title bar, and Windows 11 can paint the bar in the terminal's own colors
/// so the two read as one surface. Older Windows ignores the colors.
fn applyTheme(self: *Window) void {
    const config = &self.app.config;
    const background = config.background;
    const foreground = config.foreground;

    const luminance = (0.2126 * @as(f32, @floatFromInt(background.r)) +
        0.7152 * @as(f32, @floatFromInt(background.g)) +
        0.0722 * @as(f32, @floatFromInt(background.b))) / 255.0;
    const dark: u32 = switch (config.@"window-theme") {
        .light => 0,
        .dark => 1,
        .auto, .system, .ghostty => @intFromBool(luminance < 0.5),
    };
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(u32));

    // Only the themes that follow the terminal recolor the bar. Light, dark
    // and the system's own choice keep Windows' colors.
    switch (config.@"window-theme") {
        .auto, .ghostty => {
            const caption = c.rgb(background.r, background.g, background.b);
            const text = c.rgb(foreground.r, foreground.g, foreground.b);
            _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_CAPTION_COLOR, &caption, @sizeOf(u32));
            _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_BORDER_COLOR, &caption, @sizeOf(u32));
            _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_TEXT_COLOR, &text, @sizeOf(u32));
        },
        .system, .light, .dark => {},
    }
}

/// Apply `background-opacity` and `background-blur`.
///
/// Windows fades the whole window, so the text becomes see-through along
/// with the background. Per-pixel transparency would need every terminal
/// surface to be a layered window of its own. At the default opacity of 1
/// the window is left alone.
fn applyTranslucency(self: *Window) void {
    const config = &self.app.config;
    const opacity = std.math.clamp(config.@"background-opacity", 0.0, 1.0);
    if (opacity >= 1.0) return;

    const style = c.GetWindowLongW(self.hwnd, c.GWL_EXSTYLE);
    _ = c.SetWindowLongW(self.hwnd, c.GWL_EXSTYLE, style | c.WS_EX_LAYERED);
    // A fully transparent window could not be found or clicked.
    const alpha: u8 = @intFromFloat(@round(@max(opacity, 0.1) * 255.0));
    _ = c.SetLayeredWindowAttributes(self.hwnd, 0, alpha, c.LWA_ALPHA);

    // Blur is the frosted effect behind the window. The macOS glass
    // variants have no Windows equivalent and use the plain blur.
    const state: u32 = switch (config.@"background-blur") {
        .false => return,
        .true, .@"macos-glass-regular", .@"macos-glass-clear" => c.ACCENT_ENABLE_BLURBEHIND,
        .radius => c.ACCENT_ENABLE_ACRYLICBLURBEHIND,
    };
    var policy: c.AccentPolicy = .{
        .state = state,
        .flags = 0,
        // Acrylic needs a tint (ABGR) or it draws nothing; fully
        // transparent black keeps the terminal's own colors.
        .gradient_color = 0x01000000,
        .animation_id = 0,
    };
    var data: c.WindowCompositionAttributeData = .{
        .attribute = c.WCA_ACCENT_POLICY,
        .data = &policy,
        .size = @sizeOf(c.AccentPolicy),
    };
    if (c.SetWindowCompositionAttribute(self.hwnd, &data) == 0) {
        log.warn("could not enable background blur", .{});
    }
}

/// Move the window to the configured position, if there is one.
fn applyPosition(self: *Window) void {
    const config = &self.app.config;
    const x = config.@"window-position-x" orelse return;
    const y = config.@"window-position-y" orelse return;
    _ = c.SetWindowPos(self.hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

// Tab overview

/// Show or hide a grid of pictures of all the tabs. Clicking one switches to
/// it. The terminals are hidden while the grid is up.
pub fn toggleTabOverview(self: *Window) void {
    if (self.overview) {
        self.closeOverview(null);
        return;
    }
    if (self.tabs.items.len == 0) return;

    self.overview = true;
    self.overview_selected = self.active_tab;
    for (self.tabs.items) |tab| self.setSurfacesShown(tab, false);
    // Keys arrive at the window itself, since no terminal is showing.
    _ = c.SetFocus(self.hwnd);
    self.invalidate();
}

/// Leave the overview, optionally switching to a tab.
fn closeOverview(self: *Window, choose: ?usize) void {
    self.overview = false;
    if (choose) |index| {
        // The tab shown before the overview is the one hidden by switching.
        if (index < self.tabs.items.len) self.active_tab = index;
    }
    self.activateCurrentTab();
}

/// Show or hide the native windows of a tab's terminals without telling the
/// terminals, which keep running.
fn setSurfacesShown(self: *Window, tab: *Tab, shown: bool) void {
    var leaves: std.ArrayList(*Surface) = .empty;
    defer leaves.deinit(self.app.core_app.alloc);
    collectLeaves(self.app.core_app.alloc, tab.root, &leaves) catch return;
    for (leaves.items) |surface| {
        _ = c.ShowWindow(surface.hwnd, if (shown) c.SW_SHOW else c.SW_HIDE);
    }
}

/// The smallest whole number whose square is at least n.
fn ceilSqrt(n: usize) usize {
    var k: usize = 1;
    while (k * k < n) k += 1;
    return k;
}

const OverviewTile = struct {
    /// The cell in the grid, which includes the title below the picture.
    cell: c.Rect,
    /// Where the picture of the tab goes.
    picture: c.Rect,
};

/// Where tab number `index` sits in the grid.
fn overviewTile(self: *const Window, index: usize, client: c.Rect) OverviewTile {
    const count = self.tabs.items.len;
    const columns: usize = ceilSqrt(count);
    const rows: usize = (count + columns - 1) / columns;

    const margin = self.scaled(28);
    const label = self.scaled(26);
    const width = client.right - client.left;
    const height = client.bottom - client.top;

    const cell_w = @divTrunc(width - margin * @as(i32, @intCast(columns + 1)), @as(i32, @intCast(columns)));
    const cell_h = @divTrunc(height - margin * @as(i32, @intCast(rows + 1)), @as(i32, @intCast(rows)));
    const column: i32 = @intCast(index % columns);
    const row: i32 = @intCast(index / columns);
    const cell: c.Rect = .{
        .left = margin + column * (cell_w + margin),
        .top = margin + row * (cell_h + margin),
        .right = margin + column * (cell_w + margin) + cell_w,
        .bottom = margin + row * (cell_h + margin) + cell_h,
    };

    // The picture keeps the shape of the window's content area.
    const content = self.contentRect();
    const content_w: f32 = @floatFromInt(@max(content.right - content.left, 1));
    const content_h: f32 = @floatFromInt(@max(content.bottom - content.top, 1));
    const room_h: f32 = @floatFromInt(@max(cell_h - label, 1));
    const room_w: f32 = @floatFromInt(@max(cell_w, 1));
    const scale_to_fit = @min(room_w / content_w, room_h / content_h);
    const picture_w: i32 = @intFromFloat(content_w * scale_to_fit);
    const picture_h: i32 = @intFromFloat(content_h * scale_to_fit);
    const picture_left = cell.left + @divTrunc(cell_w - picture_w, 2);
    return .{
        .cell = cell,
        .picture = .{
            .left = picture_left,
            .top = cell.top,
            .right = picture_left + picture_w,
            .bottom = cell.top + picture_h,
        },
    };
}

fn overviewHit(self: *const Window, x: i32, y: i32) ?usize {
    var client: c.Rect = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    for (0..self.tabs.items.len) |i| {
        const tile = self.overviewTile(i, client);
        if (x >= tile.cell.left and x < tile.cell.right and y >= tile.cell.top and y < tile.cell.bottom) return i;
    }
    return null;
}

/// Keys while the overview is showing. Returns true if the key was used.
fn overviewKey(self: *Window, vk: usize) bool {
    const count = self.tabs.items.len;
    switch (vk) {
        c.VK_ESCAPE => self.closeOverview(null),
        c.VK_RETURN => self.closeOverview(self.overview_selected),
        c.VK_LEFT, c.VK_UP => {
            self.overview_selected = (self.overview_selected + count - 1) % count;
            self.invalidate();
        },
        c.VK_RIGHT, c.VK_DOWN => {
            self.overview_selected = (self.overview_selected + 1) % count;
            self.invalidate();
        },
        else => return false,
    }
    return true;
}

fn paintOverview(self: *Window, hdc: c.Handle, client: c.Rect) void {
    const config = &self.app.config;
    fillRect(hdc, client, mix(config.background, .{ .r = 0, .g = 0, .b = 0 }, 0.35));

    self.ensureFont(hdc);
    const old_font = if (self.font) |font| c.SelectObject(hdc, font) else null;
    defer if (old_font) |old| {
        _ = c.SelectObject(hdc, old);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetStretchBltMode(hdc, c.HALFTONE);

    const alloc = self.app.core_app.alloc;
    for (self.tabs.items, 0..) |tab, i| {
        const tile = self.overviewTile(i, client);
        const selected = i == self.overview_selected;

        // A frame around the chosen tab.
        const frame = self.scaled(4);
        const frame_color = if (selected) c.rgb(0x4C, 0xA3, 0xFF) else mix(config.background, config.foreground, 0.2);
        fillRect(hdc, .{
            .left = tile.picture.left - frame,
            .top = tile.picture.top - frame,
            .right = tile.picture.right + frame,
            .bottom = tile.picture.bottom + frame,
        }, frame_color);
        fillRect(hdc, tile.picture, c.rgb(config.background.r, config.background.g, config.background.b));

        // Each terminal of the tab, drawn small where it sits in the window.
        // A tab that was last laid out before the tab bar appeared has a
        // different size, so each tab is measured against its own layout.
        const base = tab.root.rect;
        const picture_w: f32 = @floatFromInt(tile.picture.right - tile.picture.left);
        const factor = picture_w / @as(f32, @floatFromInt(@max(base.right - base.left, 1)));
        var leaves: std.ArrayList(*Surface) = .empty;
        defer leaves.deinit(alloc);
        collectLeaves(alloc, tab.root, &leaves) catch continue;
        for (leaves.items) |surface| {
            if (surface.pixels_width == 0) continue;
            const node = surface.node orelse continue;
            const info: c.BitmapInfoHeader = .{
                .width = @intCast(surface.pixels_width),
                .height = @intCast(surface.pixels_height),
            };
            const left = tile.picture.left + @as(i32, @intFromFloat(@as(f32, @floatFromInt(node.rect.left - base.left)) * factor));
            const top = tile.picture.top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(node.rect.top - base.top)) * factor));
            const width: i32 = @intFromFloat(@as(f32, @floatFromInt(node.rect.right - node.rect.left)) * factor);
            const height: i32 = @intFromFloat(@as(f32, @floatFromInt(node.rect.bottom - node.rect.top)) * factor);
            if (width < 1 or height < 1) continue;
            _ = c.StretchDIBits(
                hdc,
                left,
                top,
                width,
                height,
                0,
                0,
                @intCast(surface.pixels_width),
                @intCast(surface.pixels_height),
                surface.pixels.ptr,
                &info,
                c.DIB_RGB_COLORS,
                c.SRCCOPY,
            );
        }

        // The title under the picture.
        _ = c.SetTextColor(hdc, c.rgb(config.foreground.r, config.foreground.g, config.foreground.b));
        var label: c.Rect = .{
            .left = tile.cell.left,
            .top = tile.picture.bottom + self.scaled(8),
            .right = tile.cell.right,
            .bottom = tile.cell.bottom,
        };
        if (std.unicode.utf8ToUtf16LeAlloc(alloc, self.tabTitle(tab))) |wide| {
            defer alloc.free(wide);
            _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &label, c.DT_CENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
        } else |_| {}
    }
}

/// Make sure the font used for titles exists.
fn ensureFont(self: *Window, hdc: c.Handle) void {
    _ = hdc;
    if (self.font != null) return;
    self.font = c.CreateFontW(
        -self.scaled(13),
        0,
        0,
        0,
        c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        0,
        0,
        c.CLEARTYPE_QUALITY,
        0,
        c.utf16Literal("Segoe UI"),
    );
}

// Command palette

/// Open the command palette, or close it if it is already open.
pub fn toggleCommandPalette(self: *Window, origin: *Surface) void {
    if (self.palette != null) {
        self.closePalette();
        origin.focus();
        return;
    }
    self.palette = Palette.open(self, origin) catch |err| {
        log.warn("could not open the command palette err={}", .{err});
        return;
    };
}

/// Close the command palette. Its window frees it as it is destroyed.
pub fn closePalette(self: *Window) void {
    const palette = self.palette orelse return;
    self.palette = null;
    _ = c.DestroyWindow(palette.hwnd);
}

/// Show a terminal, which may be in another tab, and give it focus.
pub fn focusSurface(self: *Window, surface: *Surface) void {
    // The terminal may belong to a different window.
    if (surface.window != self) {
        surface.window.focusSurface(surface);
        _ = c.BringWindowToTop(surface.window.hwnd);
        return;
    }
    const index = self.tabIndexOf(surface) orelse return;
    self.tabs.items[index].active = surface;
    self.selectTab(index);
    _ = c.SetFocus(surface.hwnd);
}

pub fn scaleFactor(self: *const Window) f32 {
    return self.scale();
}
// Tabs

pub fn newTab(self: *Window) !*Tab {
    const alloc = self.app.core_app.alloc;

    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    const node = try alloc.create(Node);
    errdefer alloc.destroy(node);

    const surface = try Surface.create(self, if (self.tabs.items.len == 0) .window else .tab);
    errdefer _ = c.DestroyWindow(surface.hwnd);

    node.* = .{ .kind = .{ .leaf = surface } };
    surface.node = node;
    tab.* = .{ .root = node, .active = surface };

    const index = if (self.tabs.items.len == 0) 0 else self.active_tab + 1;
    try self.tabs.insert(alloc, index, tab);
    self.selectTab(index);
    return tab;
}

pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;

    if (self.active_tab != index and self.active_tab < self.tabs.items.len) {
        self.setTabVisible(self.tabs.items[self.active_tab], false);
    }
    self.active_tab = index;
    self.activateCurrentTab();
}

/// Show the current tab and give it focus. The previous tab, if it still
/// exists, must already be hidden.
fn activateCurrentTab(self: *Window) void {
    const tab = self.tabs.items[self.active_tab];
    self.setTabVisible(tab, true);
    self.layout();
    _ = c.SetFocus(tab.active.hwnd);
    self.updateTitle();
}

fn setTabVisible(self: *Window, tab: *Tab, visible: bool) void {
    var leaves: std.ArrayList(*Surface) = .empty;
    defer leaves.deinit(self.app.core_app.alloc);
    collectLeaves(self.app.core_app.alloc, tab.root, &leaves) catch return;

    for (leaves.items) |surface| {
        _ = c.ShowWindow(surface.hwnd, if (visible) c.SW_SHOW else c.SW_HIDE);
        if (surface.ready) {
            surface.core_surface.occlusionCallback(visible) catch |err| {
                log.warn("error updating surface visibility err={}", .{err});
            };
        }
    }
}

pub fn gotoTab(self: *Window, which: apprt.action.GotoTab) void {
    const count = self.tabs.items.len;
    if (count == 0) return;

    const target: usize = switch (which) {
        .previous => (self.active_tab + count - 1) % count,
        .next => (self.active_tab + 1) % count,
        .last => count - 1,
        _ => blk: {
            const number: i64 = @intFromEnum(which);
            if (number <= 0) return;
            break :blk @min(@as(usize, @intCast(number)) - 1, count - 1);
        },
    };
    self.selectTab(target);
}

pub fn moveTab(self: *Window, amount: isize) void {
    const count: isize = @intCast(self.tabs.items.len);
    if (count < 2) return;

    const from: isize = @intCast(self.active_tab);
    const to: usize = @intCast(@mod(from + amount, count));
    const tab = self.tabs.orderedRemove(self.active_tab);
    self.tabs.insertAssumeCapacity(to, tab);
    self.active_tab = to;
    self.invalidate();
}

pub fn closeTabsOf(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const index = self.tabIndexOf(surface) orelse return;
    switch (mode) {
        .this => self.closeTabAt(index),
        .other => {
            var i = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (i != index) self.closeTabAt(i);
            }
        },
        .right => {
            var i = self.tabs.items.len;
            while (i > index + 1) {
                i -= 1;
                self.closeTabAt(i);
            }
        },
    }
}

pub fn setTabTitle(self: *Window, surface: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const index = self.tabIndexOf(surface) orelse return;
    const tab = self.tabs.items[index];

    const copy = try alloc.dupeSentinel(u8, title, 0);
    if (tab.title) |old| alloc.free(old);
    tab.title = copy;
    self.invalidate();
}

fn closeTabAt(self: *Window, index: usize) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.tabs.orderedRemove(index);

    // Detach the surfaces first. Destroying a window runs its teardown
    // synchronously, and that must not find a half-removed tab.
    var leaves: std.ArrayList(*Surface) = .empty;
    defer leaves.deinit(alloc);
    collectLeaves(alloc, tab.root, &leaves) catch {};
    for (leaves.items) |surface| surface.node = null;
    freeNodes(alloc, tab.root);
    if (tab.title) |title| alloc.free(title);
    alloc.destroy(tab);

    if (self.tabs.items.len == 0) {
        for (leaves.items) |surface| retire(surface);
        self.destroyLater();
        return;
    }

    const was_active = index == self.active_tab;
    if (index < self.active_tab) {
        self.active_tab -= 1;
    } else if (was_active) {
        self.active_tab = @min(index, self.tabs.items.len - 1);
    }

    for (leaves.items) |surface| retire(surface);

    if (was_active) {
        self.activateCurrentTab();
    } else {
        self.layout();
    }
}

fn tabIndexOf(self: *Window, surface: *Surface) ?usize {
    var node = surface.node orelse return null;
    while (node.parent) |parent| node = parent;
    for (self.tabs.items, 0..) |tab, i| {
        if (tab.root == node) return i;
    }
    return null;
}

// Splits

pub fn newSplit(self: *Window, target: *Surface, direction: apprt.action.SplitDirection) !void {
    const alloc = self.app.core_app.alloc;
    const index = self.tabIndexOf(target) orelse return;
    const tab = self.tabs.items[index];
    const target_node = target.node orelse return;

    const split_node = try alloc.create(Node);
    errdefer alloc.destroy(split_node);
    const new_node = try alloc.create(Node);
    errdefer alloc.destroy(new_node);

    const surface = try Surface.create(self, .split);
    errdefer _ = c.DestroyWindow(surface.hwnd);
    surface.node = new_node;
    new_node.* = .{ .kind = .{ .leaf = surface } };

    // "Right" and "down" put the new terminal second. "Left" and "up"
    // put it first.
    const new_first = direction == .left or direction == .up;
    split_node.* = .{
        .parent = target_node.parent,
        .kind = .{ .split = .{
            .orientation = switch (direction) {
                .left, .right => .side_by_side,
                .up, .down => .stacked,
            },
            .first = if (new_first) new_node else target_node,
            .second = if (new_first) target_node else new_node,
        } },
    };

    if (target_node.parent) |parent| {
        const split = &parent.kind.split;
        if (split.first == target_node) split.first = split_node else split.second = split_node;
    } else {
        tab.root = split_node;
    }
    target_node.parent = split_node;
    new_node.parent = split_node;

    tab.zoomed = null;
    tab.active = surface;
    if (index == self.active_tab) {
        self.setTabVisible(tab, true);
        self.layout();
        _ = c.SetFocus(surface.hwnd);
    }
}

pub fn gotoSplit(self: *Window, from: *Surface, which: apprt.action.GotoSplit) void {
    const index = self.tabIndexOf(from) orelse return;
    const tab = self.tabs.items[index];
    const alloc = self.app.core_app.alloc;

    var leaves: std.ArrayList(*Surface) = .empty;
    defer leaves.deinit(alloc);
    collectLeaves(alloc, tab.root, &leaves) catch return;
    if (leaves.items.len < 2) return;

    const from_index = std.mem.indexOfScalar(*Surface, leaves.items, from) orelse return;
    const target: *Surface = switch (which) {
        .previous => leaves.items[(from_index + leaves.items.len - 1) % leaves.items.len],
        .next => leaves.items[(from_index + 1) % leaves.items.len],
        .up, .left, .down, .right => self.neighbor(leaves.items, from, which) orelse return,
    };
    _ = c.SetFocus(target.hwnd);
}

/// The terminal next to `from` in a direction, judged by where they sit on
/// screen. Ties go to the one that overlaps `from` the most.
fn neighbor(self: *Window, leaves: []const *Surface, from: *Surface, which: apprt.action.GotoSplit) ?*Surface {
    _ = self;
    const from_rect = (from.node orelse return null).rect;
    var best: ?*Surface = null;
    var best_gap: i32 = std.math.maxInt(i32);
    var best_overlap: i32 = -1;

    for (leaves) |other| {
        if (other == from) continue;
        const rect = (other.node orelse continue).rect;

        const gap: i32, const overlap: i32 = switch (which) {
            .left => .{ from_rect.left - rect.right, overlapOf(from_rect.top, from_rect.bottom, rect.top, rect.bottom) },
            .right => .{ rect.left - from_rect.right, overlapOf(from_rect.top, from_rect.bottom, rect.top, rect.bottom) },
            .up => .{ from_rect.top - rect.bottom, overlapOf(from_rect.left, from_rect.right, rect.left, rect.right) },
            .down => .{ rect.top - from_rect.bottom, overlapOf(from_rect.left, from_rect.right, rect.left, rect.right) },
            else => return null,
        };
        if (gap < 0 or overlap <= 0) continue;
        if (gap < best_gap or (gap == best_gap and overlap > best_overlap)) {
            best = other;
            best_gap = gap;
            best_overlap = overlap;
        }
    }
    return best;
}

fn overlapOf(a_start: i32, a_end: i32, b_start: i32, b_end: i32) i32 {
    return @min(a_end, b_end) - @max(a_start, b_start);
}

pub fn resizeSplit(self: *Window, surface: *Surface, amount: u16, direction: apprt.action.ResizeSplit.Direction) void {
    const wanted: Orientation = switch (direction) {
        .left, .right => .side_by_side,
        .up, .down => .stacked,
    };

    // The nearest enclosing split that divides in the requested direction.
    var node = surface.node orelse return;
    while (node.parent) |parent| : (node = parent) {
        if (parent.kind.split.orientation != wanted) continue;

        const split = &parent.kind.split;
        const rect = parent.rect;
        const total: f32 = @floatFromInt(switch (wanted) {
            .side_by_side => rect.right - rect.left,
            .stacked => rect.bottom - rect.top,
        });
        if (total <= 0) return;

        const delta = @as(f32, @floatFromInt(amount)) / total;
        const grows = direction == .right or direction == .down;
        split.ratio = std.math.clamp(split.ratio + if (grows) delta else -delta, min_split_ratio, 1 - min_split_ratio);
        self.layout();
        return;
    }
}

pub fn equalizeSplits(self: *Window, surface: *Surface) void {
    const index = self.tabIndexOf(surface) orelse return;
    setRatios(self.tabs.items[index].root, 0.5);
    self.layout();
}

fn setRatios(node: *Node, ratio: f32) void {
    switch (node.kind) {
        .leaf => {},
        .split => |*split| {
            split.ratio = ratio;
            setRatios(split.first, ratio);
            setRatios(split.second, ratio);
        },
    }
}

pub fn toggleSplitZoom(self: *Window, surface: *Surface) void {
    const index = self.tabIndexOf(surface) orelse return;
    const tab = self.tabs.items[index];
    // A tab with one terminal has nothing to zoom.
    if (tab.root.kind == .leaf) return;

    tab.zoomed = if (tab.zoomed == null) surface else null;
    if (index == self.active_tab) {
        self.layout();
        _ = c.SetFocus(surface.hwnd);
    }
}

/// Posted to a window to destroy it once the message being handled is done.
const destroy_window_message = c.WM_APP + 7;

/// Take a terminal out of use and destroy its window a moment later. A close
/// often starts inside the terminal's own key handling, and the terminal
/// still touches its own memory as that handler returns.
fn retire(surface: *Surface) void {
    _ = c.ShowWindow(surface.hwnd, c.SW_HIDE);
    _ = c.PostMessageW(surface.hwnd, Surface.destroy_message, 0, 0);
}

/// Destroy this window after the message being handled is done.
fn destroyLater(self: *Window) void {
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    _ = c.PostMessageW(self.hwnd, destroy_window_message, 0, 0);
}
/// Close one terminal. Closing the last terminal of a tab closes the tab,
/// and closing the last tab closes the window.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const index = self.tabIndexOf(surface) orelse {
        retire(surface);
        return;
    };
    const node = surface.node.?;

    const parent = node.parent orelse {
        self.closeTabAt(index);
        return;
    };

    const tab = self.tabs.items[index];
    const sibling = if (parent.kind.split.first == node) parent.kind.split.second else parent.kind.split.first;
    self.replaceNode(tab, parent, sibling);

    if (tab.zoomed == surface) tab.zoomed = null;
    if (tab.active == surface) tab.active = firstLeaf(sibling);
    surface.node = null;
    alloc.destroy(node);
    alloc.destroy(parent);

    retire(surface);

    if (index == self.active_tab) {
        self.layout();
        _ = c.SetFocus(tab.active.hwnd);
    }
}

pub fn closeWindow(self: *Window) void {
    self.destroyLater();
}

/// Put `new` where `old` was in the tree.
fn replaceNode(self: *Window, tab: *Tab, old: *Node, new: *Node) void {
    _ = self;
    new.parent = old.parent;
    if (old.parent) |parent| {
        const split = &parent.kind.split;
        if (split.first == old) split.first = new else split.second = new;
    } else {
        tab.root = new;
    }
}

fn firstLeaf(node: *Node) *Surface {
    return switch (node.kind) {
        .leaf => |surface| surface,
        .split => |split| firstLeaf(split.first),
    };
}

fn collectLeaves(alloc: Allocator, node: *Node, list: *std.ArrayList(*Surface)) !void {
    switch (node.kind) {
        .leaf => |surface| try list.append(alloc, surface),
        .split => |split| {
            try collectLeaves(alloc, split.first, list);
            try collectLeaves(alloc, split.second, list);
        },
    }
}

fn freeNodes(alloc: Allocator, node: *Node) void {
    switch (node.kind) {
        .leaf => {},
        .split => |split| {
            freeNodes(alloc, split.first);
            freeNodes(alloc, split.second);
        },
    }
    alloc.destroy(node);
}

// Surface callbacks

pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const index = self.tabIndexOf(surface) orelse return;
    self.tabs.items[index].active = surface;
    self.updateTitle();
}

pub fn titleChanged(self: *Window, surface: *Surface) void {
    _ = surface;
    self.updateTitle();
    self.invalidate();
}

fn updateTitle(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    const alloc = self.app.core_app.alloc;
    const title = self.tabTitle(self.tabs.items[self.active_tab]);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return;
    defer alloc.free(wide);
    _ = c.SetWindowTextW(self.hwnd, wide);
}

fn tabTitle(self: *Window, tab: *Tab) []const u8 {
    _ = self;
    if (tab.title) |title| return title;
    return tab.active.title orelse "Ghostty";
}

// Window state

pub fn setInitialSize(self: *Window, width: u32, height: u32) void {
    // Only a lone terminal has a size that is the whole window's content.
    // The first terminal asks for its size while it is being created, before
    // its tab exists, so an empty window counts as well.
    if (self.tabs.items.len > 1) return;
    if (self.tabs.items.len == 1 and self.tabs.items[0].root.kind != .leaf) return;

    var rect: c.Rect = .{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height + @as(u32, @intCast(self.tabBarHeight()))) };
    const style: u32 = @bitCast(c.GetWindowLongW(self.hwnd, c.GWL_STYLE));
    _ = c.AdjustWindowRectExForDpi(&rect, style, 0, 0, c.GetDpiForWindow(self.hwnd));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// Show progress from a program, such as a download, on the taskbar button.
pub fn setProgress(self: *Window, report: terminal.osc.Command.ProgressReport) void {
    log.debug("taskbar progress state={t} progress={?}", .{ report.state, report.progress });
    shell.setProgress(self.hwnd, report);
}

const notify_timer_id = 2;

/// Show a desktop notification. Its entry in the notification area is taken
/// away again after a while.
pub fn notify(self: *Window, title: []const u8, body: []const u8) void {
    if (!shell.notify(self.hwnd, title, body)) {
        log.warn("Windows did not accept the notification", .{});
        return;
    }
    log.debug("showed a notification", .{});
    _ = c.SetTimer(self.hwnd, notify_timer_id, shell.notification_lifetime_ms, null);
}

pub fn setMinimumSize(self: *Window, width: u32, height: u32) void {
    self.min_client = .{ .x = @intCast(width), .y = @intCast(height) };
}

pub fn toggleMaximize(self: *Window) void {
    _ = c.ShowWindow(self.hwnd, if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

/// Fullscreen is a borderless window covering the monitor it is on.
pub fn toggleFullscreen(self: *Window) void {
    if (self.fullscreen) |saved| {
        self.fullscreen = null;
        _ = c.SetWindowLongW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
        );
        return;
    }

    var placement: c.WindowPlacement = .{};
    if (c.GetWindowPlacement(self.hwnd, &placement) == 0) return;
    const monitor = c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MonitorInfo = .{};
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;

    const style = c.GetWindowLongW(self.hwnd, c.GWL_STYLE);
    self.fullscreen = .{ .style = style, .placement = placement };
    _ = c.SetWindowLongW(self.hwnd, c.GWL_STYLE, style & ~@as(i32, c.WS_OVERLAPPEDWINDOW));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        info.monitor.left,
        info.monitor.top,
        info.monitor.right - info.monitor.left,
        info.monitor.bottom - info.monitor.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

pub fn toggleDecorations(self: *Window) void {
    const style = c.GetWindowLongW(self.hwnd, c.GWL_STYLE);
    _ = c.SetWindowLongW(self.hwnd, c.GWL_STYLE, style ^ (c.WS_CAPTION | c.WS_THICKFRAME));
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

// Layout

fn scale(self: *const Window) f32 {
    return @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd))) / 96.0;
}

fn scaled(self: *const Window, logical: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * self.scale()));
}

fn tabBarHeight(self: *const Window) i32 {
    const show = switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
    return if (show) self.scaled(tab_bar_height) else 0;
}

fn contentRect(self: *const Window) c.Rect {
    var rect: c.Rect = undefined;
    _ = c.GetClientRect(self.hwnd, &rect);
    rect.top += self.tabBarHeight();
    return rect;
}

/// The content area a new terminal should start with, before layout runs.
pub fn newSurfaceRect(self: *const Window) c.Rect {
    var rect = self.contentRect();
    if (rect.right - rect.left < 1) rect.right = rect.left + 1;
    if (rect.bottom - rect.top < 1) rect.bottom = rect.top + 1;
    return rect;
}

pub fn layout(self: *Window) void {
    if (self.active_tab >= self.tabs.items.len) return;
    // The overview keeps the terminals hidden.
    if (self.overview) {
        self.invalidate();
        return;
    }
    const alloc = self.app.core_app.alloc;
    const tab = self.tabs.items[self.active_tab];
    const rect = self.contentRect();

    if (tab.zoomed) |zoomed| {
        var leaves: std.ArrayList(*Surface) = .empty;
        defer leaves.deinit(alloc);
        collectLeaves(alloc, tab.root, &leaves) catch return;
        for (leaves.items) |surface| {
            if (surface == zoomed) {
                self.place(surface, rect);
                _ = c.ShowWindow(surface.hwnd, c.SW_SHOW);
            } else {
                _ = c.ShowWindow(surface.hwnd, c.SW_HIDE);
            }
        }
    } else {
        self.layoutNode(tab.root, rect);
    }
    self.invalidate();
}

fn layoutNode(self: *Window, node: *Node, rect: c.Rect) void {
    node.rect = rect;
    switch (node.kind) {
        .leaf => |surface| {
            _ = c.ShowWindow(surface.hwnd, c.SW_SHOW);
            self.place(surface, rect);
        },
        .split => |*split| {
            const gap = self.scaled(divider_width);
            switch (split.orientation) {
                .side_by_side => {
                    const first_width = splitSize(rect.right - rect.left, gap, split.ratio);
                    const first: c.Rect = .{ .left = rect.left, .top = rect.top, .right = rect.left + first_width, .bottom = rect.bottom };
                    split.divider = .{ .left = first.right, .top = rect.top, .right = first.right + gap, .bottom = rect.bottom };
                    self.layoutNode(split.first, first);
                    self.layoutNode(split.second, .{ .left = split.divider.right, .top = rect.top, .right = rect.right, .bottom = rect.bottom });
                },
                .stacked => {
                    const first_height = splitSize(rect.bottom - rect.top, gap, split.ratio);
                    const first: c.Rect = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + first_height };
                    split.divider = .{ .left = rect.left, .top = first.bottom, .right = rect.right, .bottom = first.bottom + gap };
                    self.layoutNode(split.first, first);
                    self.layoutNode(split.second, .{ .left = rect.left, .top = split.divider.bottom, .right = rect.right, .bottom = rect.bottom });
                },
            }
        },
    }
}

/// The size of the first half of a split, leaving `gap` for the divider.
fn splitSize(total: i32, gap: i32, ratio: f32) i32 {
    const available = @max(total - gap, 0);
    return @intFromFloat(@as(f32, @floatFromInt(available)) * ratio);
}

fn place(self: *Window, surface: *Surface, rect: c.Rect) void {
    _ = self;
    _ = c.SetWindowPos(
        surface.hwnd,
        null,
        rect.left,
        rect.top,
        @max(rect.right - rect.left, 1),
        @max(rect.bottom - rect.top, 1),
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn invalidate(self: *Window) void {
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

// Painting

const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
};

fn tabWidth(self: *const Window, client_width: i32) i32 {
    const plus = self.tabBarHeight();
    const count: i32 = @intCast(@max(self.tabs.items.len, 1));
    return @min(self.scaled(tab_max_width), @divTrunc(@max(client_width - plus, 1), count));
}

fn closeButtonRect(self: *const Window, tab_rect: c.Rect) c.Rect {
    const size = @divTrunc(self.tabBarHeight() * 6, 10);
    const margin = @divTrunc(self.tabBarHeight() - size, 2);
    return .{
        .left = tab_rect.right - margin - size,
        .top = tab_rect.top + margin,
        .right = tab_rect.right - margin,
        .bottom = tab_rect.top + margin + size,
    };
}

fn hitTest(self: *const Window, x: i32, y: i32) Hit {
    const bar = self.tabBarHeight();
    if (bar == 0 or y < 0 or y >= bar) return .none;

    var client: c.Rect = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const width = self.tabWidth(client.right);

    for (0..self.tabs.items.len) |i| {
        const left: i32 = @as(i32, @intCast(i)) * width;
        const tab_rect: c.Rect = .{ .left = left, .top = 0, .right = left + width, .bottom = bar };
        if (x < tab_rect.left or x >= tab_rect.right) continue;

        const close = self.closeButtonRect(tab_rect);
        if (x >= close.left and x < close.right and y >= close.top and y < close.bottom) return .{ .close = i };
        return .{ .tab = i };
    }

    const plus_left: i32 = @as(i32, @intCast(self.tabs.items.len)) * width;
    if (x >= plus_left and x < plus_left + bar) return .new_tab;
    return .none;
}

fn blend(from: u8, to: u8, amount: f32) u8 {
    const f: f32 = @floatFromInt(from);
    const t: f32 = @floatFromInt(to);
    return @intFromFloat(@round(f + (t - f) * amount));
}

fn mix(from: anytype, to: anytype, amount: f32) u32 {
    return c.rgb(blend(from.r, to.r, amount), blend(from.g, to.g, amount), blend(from.b, to.b, amount));
}

fn paint(self: *Window) void {
    var ps: c.PaintStruct = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    const config = &self.app.config;
    const background = config.background;
    const foreground = config.foreground;

    var client: c.Rect = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    if (self.overview) {
        self.paintOverview(hdc, client);
        return;
    }

    // Whatever the terminals don't cover is divider color.
    const divider_color = if (config.@"split-divider-color") |color|
        c.rgb(color.r, color.g, color.b)
    else
        mix(background, foreground, 0.25);
    fillRect(hdc, client, divider_color);

    const bar = self.tabBarHeight();
    if (bar == 0) return;

    const width = self.tabWidth(client.right);
    const bar_color = mix(background, .{ .r = 0, .g = 0, .b = 0 }, 0.25);
    fillRect(hdc, .{ .left = 0, .top = 0, .right = client.right, .bottom = bar }, bar_color);

    if (self.font == null) {
        self.font = c.CreateFontW(
            -self.scaled(13),
            0,
            0,
            0,
            c.FW_NORMAL,
            0,
            0,
            0,
            c.DEFAULT_CHARSET,
            0,
            0,
            c.CLEARTYPE_QUALITY,
            0,
            c.utf16Literal("Segoe UI"),
        );
    }
    const old_font = if (self.font) |font| c.SelectObject(hdc, font) else null;
    defer if (old_font) |old| {
        _ = c.SelectObject(hdc, old);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    const alloc = self.app.core_app.alloc;
    for (self.tabs.items, 0..) |tab, i| {
        const left: i32 = @as(i32, @intCast(i)) * width;
        const tab_rect: c.Rect = .{ .left = left, .top = 0, .right = left + width, .bottom = bar };
        const active = i == self.active_tab;

        // The active tab matches the terminal so it reads as attached to it.
        if (active) fillRect(hdc, tab_rect, c.rgb(background.r, background.g, background.b));
        _ = c.SetTextColor(hdc, if (active) c.rgb(foreground.r, foreground.g, foreground.b) else mix(background, foreground, 0.6));

        const pad = self.scaled(10);
        const close = self.closeButtonRect(tab_rect);
        var text_rect: c.Rect = .{ .left = tab_rect.left + pad, .top = 0, .right = close.left - self.scaled(4), .bottom = bar };
        if (std.unicode.utf8ToUtf16LeAlloc(alloc, self.tabTitle(tab))) |wide| {
            defer alloc.free(wide);
            _ = c.DrawTextW(hdc, wide.ptr, @intCast(wide.len), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
        } else |_| {}

        var close_rect = close;
        _ = c.DrawTextW(hdc, c.utf16Literal("x"), 1, &close_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
    }

    var plus_rect: c.Rect = .{ .left = @as(i32, @intCast(self.tabs.items.len)) * width, .top = 0, .right = @as(i32, @intCast(self.tabs.items.len)) * width + bar, .bottom = bar };
    _ = c.SetTextColor(hdc, mix(background, foreground, 0.6));
    _ = c.DrawTextW(hdc, c.utf16Literal("+"), 1, &plus_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);
}

fn fillRect(hdc: c.Handle, rect: c.Rect, color: u32) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

// Messages

fn dividerAt(node: *Node, x: i32, y: i32) ?*Node {
    switch (node.kind) {
        .leaf => return null,
        .split => |split| {
            const d = split.divider;
            if (x >= d.left and x < d.right and y >= d.top and y < d.bottom) return node;
            return dividerAt(split.first, x, y) orelse dividerAt(split.second, x, y);
        },
    }
}

fn activeTab(self: *Window) ?*Tab {
    if (self.active_tab >= self.tabs.items.len) return null;
    return self.tabs.items[self.active_tab];
}

fn wndProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const create_struct: *const c.CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(create_struct.create_params)));
        const self: *Window = @ptrCast(@alignCast(create_struct.create_params.?));
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.handleMessage(msg, wparam, lparam);
}

fn handleMessage(self: *Window, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {

    switch (msg) {
        c.WM_DESTROY => {
            self.destroy();
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        destroy_window_message => {
            _ = c.DestroyWindow(self.hwnd);
            return 0;
        },

        c.WM_ACTIVATE => {
            const inactive = (wparam & 0xFFFF) == 0;
            if (self.quick and inactive and self.app.config.@"quick-terminal-autohide") {
                _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
            }
            return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
        },

        c.WM_TIMER => {
            if (wparam == notify_timer_id) {
                _ = c.KillTimer(self.hwnd, notify_timer_id);
                shell.removeNotifyIcon(self.hwnd);
            }
            return 0;
        },

        c.WM_PAINT => {
            self.paint();
            return 0;
        },

        c.WM_SIZE => {
            self.layout();
            return 0;
        },

        c.WM_SETFOCUS => {
            if (self.activeTab()) |tab| _ = c.SetFocus(tab.active.hwnd);
            return 0;
        },

        // Keys normally go straight to the focused terminal. If one ends up
        // here, such as from a tab bar click, pass it along.
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            if (self.overview) {
                if (msg == c.WM_KEYDOWN) _ = self.overviewKey(wparam);
                return 0;
            }
            if (self.activeTab()) |tab| _ = c.PostMessageW(tab.active.hwnd, msg, wparam, lparam);
            return 0;
        },

        c.WM_DPICHANGED => {
            // The drop-down terminal is placed from the screen it is on. Windows
            // suggests a size for the new display's scale that would undo that.
            if (self.quick) {
                self.placeQuick();
                self.layout();
                for (self.tabs.items) |tab| self.notifyScale(tab.root);
                return 0;
            }
            // Windows suggests the rectangle that keeps the window's
            // physical size the same on the new display.
            const suggested: *const c.Rect = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                self.hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            if (self.font) |font| _ = c.DeleteObject(font);
            self.font = null;
            self.layout();
            for (self.tabs.items) |tab| self.notifyScale(tab.root);
            return 0;
        },

        c.WM_GETMINMAXINFO => {
            if (self.min_client.x <= 0 and self.min_client.y <= 0) return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
            var rect: c.Rect = .{ .left = 0, .top = 0, .right = self.min_client.x, .bottom = self.min_client.y + self.tabBarHeight() };
            const style: u32 = @bitCast(c.GetWindowLongW(self.hwnd, c.GWL_STYLE));
            _ = c.AdjustWindowRectExForDpi(&rect, style, 0, 0, c.GetDpiForWindow(self.hwnd));
            const info: *c.MinMaxInfo = @ptrFromInt(@as(usize, @bitCast(lparam)));
            info.min_track_size = .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
            return 0;
        },

        c.WM_CLOSE => {
            if (self.anyNeedsConfirm()) {
                const answer = c.MessageBoxW(
                    self.hwnd,
                    c.utf16Literal("A program is still running in this window. Close it anyway?"),
                    c.utf16Literal("Close Ghostty"),
                    c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2,
                );
                if (answer != c.IDYES) return 0;
            }
            _ = c.DestroyWindow(self.hwnd);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            const x: i32 = c.loword(lparam);
            const y: i32 = c.hiword(lparam);
            if (self.overview) {
                if (self.overviewHit(x, y)) |index| self.closeOverview(index);
                return 0;
            }
            switch (self.hitTest(x, y)) {
                .tab => |i| {
                    self.selectTab(i);
                    // Holding the button and moving drags the tab.
                    self.tab_drag = .{ .start_x = x, .moved = false };
                    _ = c.SetCapture(self.hwnd);
                },
                .close => |i| self.closeTabAt(i),
                .new_tab => {
                    _ = self.newTab() catch |err| {
                        log.warn("error creating tab err={}", .{err});
                    };
                },
                .none => if (self.activeTab()) |tab| {
                    if (dividerAt(tab.root, x, y)) |node| {
                        self.dragging = node;
                        _ = c.SetCapture(self.hwnd);
                    }
                },
            }
            return 0;
        },

        c.WM_MBUTTONDOWN => {
            switch (self.hitTest(c.loword(lparam), c.hiword(lparam))) {
                .tab, .close => |i| self.closeTabAt(i),
                else => {},
            }
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.tab_drag) |*drag| {
                const x: i32 = c.loword(lparam);
                // Small movements while clicking are not a drag.
                if (!drag.moved and @abs(x - drag.start_x) < self.scaled(6)) return 0;
                drag.moved = true;

                // The dragged tab is the active one. It takes the place of
                // whichever tab the pointer is over.
                var client: c.Rect = undefined;
                _ = c.GetClientRect(self.hwnd, &client);
                const slot = @divTrunc(@max(x, 0), @max(self.tabWidth(client.right), 1));
                const target: usize = @min(@as(usize, @intCast(slot)), self.tabs.items.len - 1);
                if (target != self.active_tab) {
                    const tab = self.tabs.orderedRemove(self.active_tab);
                    self.tabs.insertAssumeCapacity(target, tab);
                    self.active_tab = target;
                    self.invalidate();
                }
                return 0;
            }

            const node = self.dragging orelse return 0;
            const split = &node.kind.split;
            const rect = node.rect;
            const gap = self.scaled(divider_width);
            const pos: i32 = switch (split.orientation) {
                .side_by_side => c.loword(lparam) - rect.left,
                .stacked => c.hiword(lparam) - rect.top,
            };
            const total: i32 = switch (split.orientation) {
                .side_by_side => rect.right - rect.left,
                .stacked => rect.bottom - rect.top,
            } - gap;
            if (total <= 0) return 0;

            const ratio = @as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(total));
            split.ratio = std.math.clamp(ratio, min_split_ratio, 1 - min_split_ratio);
            self.layout();
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.tab_drag != null) {
                self.tab_drag = null;
                _ = c.ReleaseCapture();
            }
            if (self.dragging != null) {
                self.dragging = null;
                _ = c.ReleaseCapture();
            }
            return 0;
        },

        c.WM_SETCURSOR => {
            const hit_test: u16 = @truncate(@as(usize, @bitCast(lparam)));
            if (hit_test != c.HTCLIENT) return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);

            var point: c.Point = undefined;
            _ = c.GetCursorPos(&point);
            _ = c.ScreenToClient(self.hwnd, &point);
            if (self.activeTab()) |tab| {
                if (dividerAt(tab.root, point.x, point.y)) |node| {
                    const id = switch (node.kind.split.orientation) {
                        .side_by_side => c.IDC_SIZEWE,
                        .stacked => c.IDC_SIZENS,
                    };
                    _ = c.SetCursor(c.LoadCursorW(null, id));
                    return 1;
                }
            }
            return c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
        },

        else => return c.DefWindowProcW(self.hwnd, msg, wparam, lparam),
    }
}

fn notifyScale(self: *Window, node: *Node) void {
    switch (node.kind) {
        .leaf => |surface| {
            if (!surface.ready) return;
            const scale_value = surface.getContentScale() catch return;
            surface.core_surface.contentScaleCallback(scale_value) catch |err| {
                log.warn("error updating content scale err={}", .{err});
            };
        },
        .split => |split| {
            self.notifyScale(split.first);
            self.notifyScale(split.second);
        },
    }
}

fn anyNeedsConfirm(self: *Window) bool {
    const alloc = self.app.core_app.alloc;
    for (self.tabs.items) |tab| {
        var leaves: std.ArrayList(*Surface) = .empty;
        defer leaves.deinit(alloc);
        collectLeaves(alloc, tab.root, &leaves) catch continue;
        for (leaves.items) |surface| {
            if (surface.ready and surface.core_surface.needsConfirmQuit()) return true;
        }
    }
    return false;
}

/// The window is gone. The terminals inside are child windows that Windows
/// destroys next, and each cleans up after itself.
fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    const app = self.app;
    if (self.quick) {
        if (app.quick == self) app.quick = null;
    } else {
        app.windowClosed();
    }

    for (self.tabs.items) |tab| {
        var leaves: std.ArrayList(*Surface) = .empty;
        defer leaves.deinit(alloc);
        collectLeaves(alloc, tab.root, &leaves) catch {};
        for (leaves.items) |surface| surface.node = null;
        freeNodes(alloc, tab.root);
        if (tab.title) |title| alloc.free(title);
        alloc.destroy(tab);
    }
    self.tabs.deinit(alloc);
    self.closePalette();
    shell.removeNotifyIcon(self.hwnd);
    if (self.font) |font| _ = c.DeleteObject(font);
    alloc.destroy(self);
}
