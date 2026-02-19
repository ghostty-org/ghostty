/// Win32 Window represents a top-level Ghostty window (HWND).
/// A Window contains one or more tabs, each with a split tree of surfaces.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const split_tree_mod = @import("../../datastruct/split_tree.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const WinUI = @import("WinUI.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_window);

const HWND = c.HWND;
const UINT = u32;
const WPARAM = c.WPARAM;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;

/// The SplitTree parameterized for surfaces.
pub const SurfaceSplitTree = split_tree_mod.SplitTree(Surface);

/// Half the divider gap in pixels. Each surface is inset by this amount,
/// so two adjacent surfaces have a total gap of DIVIDER_HALF * 2.
const DIVIDER_HALF: i32 = 1;

/// Custom window messages.
pub const WM_GHOSTTY_CLOSE_SURFACE = c.WM_USER + 1;
pub const WM_GHOSTTY_NEW_TAB = c.WM_USER + 2;
pub const WM_GHOSTTY_CLOSE_TAB = c.WM_USER + 3;
pub const WM_GHOSTTY_SELECT_TAB = c.WM_USER + 4;

/// Window handle (top-level)
hwnd: HWND,

/// Parent app
app: *App,

/// All tabs in this window.
tabs: std.ArrayListUnmanaged(Tab) = .{},

/// Index of the active tab.
active_tab_idx: usize = 0,

/// Tab bar (created on demand when 2+ tabs exist).
tab_bar: ?*TabBar = null,

/// WinUI XAML Island host (null if WinUI not available).
winui_host: WinUI.XamlHost = null,

/// WinUI TabView control (null if WinUI not available).
winui_tabview: WinUI.TabView = null,

/// Whether this window is using WinUI controls.
using_winui: bool = false,
/// Suppress WinUI SelectionChanged callback during programmatic tab operations.
suppress_tab_selection: bool = false,

/// Window title (stored as UTF-8)
title_buf: [256]u8 = undefined,
title_len: u16 = 0,

/// Window sizing
initial_width: u32 = 0,
initial_height: u32 = 0,
min_width: i32 = 0,
min_height: i32 = 0,
max_width: i32 = 0,
max_height: i32 = 0,

/// Cell dimensions in pixels (used for sizing calculations)
cell_width: u32 = 0,
cell_height: u32 = 0,

/// Fullscreen state
is_fullscreen: bool = false,
saved_style: isize = 0,
saved_placement: c.WINDOWPLACEMENT = .{
    .length = @sizeOf(c.WINDOWPLACEMENT),
    .flags = 0,
    .showCmd = 0,
    .ptMinPosition = .{ .x = 0, .y = 0 },
    .ptMaxPosition = .{ .x = 0, .y = 0 },
    .rcNormalPosition = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
},

/// Whether a key sequence is active (shown in title bar).
key_sequence_active: bool = false,

/// Quit timer ID
pub const QUIT_TIMER_ID: usize = 1;

// ---------------------------------------------------------------
// Tab
// ---------------------------------------------------------------

pub const Tab = struct {
    tree: SurfaceSplitTree,
    active_handle: SurfaceSplitTree.Node.Handle,

    pub fn deinit(self: *Tab) void {
        self.tree.deinit();
    }

    pub fn activeSurface(self: *const Tab) *Surface {
        return switch (self.tree.nodes[self.active_handle.idx()]) {
            .leaf => |v| v,
            .split => unreachable,
        };
    }

    /// Create a new split in the given direction.
    pub fn newSplit(
        self: *Tab,
        window: *Window,
        direction: SurfaceSplitTree.Split.Direction,
    ) !void {
        const alloc = window.app.core_app.alloc;

        const new_surface = try Surface.create(window.app, window);
        errdefer {
            new_surface.destroyResources();
            _ = c.DestroyWindow(new_surface.hwnd);
            alloc.destroy(new_surface);
        }

        var config = try apprt.surface.newConfig(window.app.core_app, &window.app.config, .split);
        defer config.deinit();

        const core_surface = try alloc.create(CoreSurface);
        errdefer alloc.destroy(core_surface);

        try window.app.core_app.addSurface(new_surface);
        errdefer window.app.core_app.deleteSurface(new_surface);

        try core_surface.init(alloc, &config, window.app.core_app, window.app, new_surface);
        new_surface.core_surface = core_surface;

        const scheme = Window.detectColorScheme();
        core_surface.colorSchemeCallback(scheme) catch {};

        var insert_tree = try SurfaceSplitTree.init(alloc, new_surface);
        defer insert_tree.deinit();

        const new_tree = try self.tree.split(
            alloc,
            self.active_handle,
            direction,
            @as(f16, 0.5),
            &insert_tree,
        );

        var new_handle = self.active_handle;
        var it = new_tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == new_surface) {
                new_handle = entry.handle;
                break;
            }
        }

        self.tree.deinit();
        self.tree = new_tree;
        self.active_handle = new_handle;

        window.layout();
        _ = c.SetFocus(new_surface.hwnd);
    }

    /// Navigate to a different split.
    pub fn gotoSplit(
        self: *Tab,
        window: *Window,
        to: SurfaceSplitTree.Goto,
    ) !void {
        const alloc = window.app.core_app.alloc;
        const target = try self.tree.goto(alloc, self.active_handle, to) orelse return;
        self.active_handle = target;
        const surface = switch (self.tree.nodes[target.idx()]) {
            .leaf => |v| v,
            .split => return,
        };
        _ = c.SetFocus(surface.hwnd);
    }

    /// Resize the nearest split in the given layout direction.
    pub fn resizeSplit(
        self: *Tab,
        window: *Window,
        split_layout: SurfaceSplitTree.Split.Layout,
        ratio_delta: f16,
    ) !void {
        const alloc = window.app.core_app.alloc;
        const new_tree = try self.tree.resize(
            alloc,
            self.active_handle,
            split_layout,
            ratio_delta,
        );
        self.tree.deinit();
        self.tree = new_tree;
        window.layout();
    }

    /// Equalize all split ratios.
    pub fn equalizeSplits(self: *Tab, window: *Window) !void {
        const alloc = window.app.core_app.alloc;
        const new_tree = try self.tree.equalize(alloc);
        self.tree.deinit();
        self.tree = new_tree;
        window.layout();
    }

    /// Toggle zoom on the active surface.
    pub fn toggleZoom(self: *Tab, window: *Window) void {
        if (self.tree.zoomed != null) {
            self.tree.zoom(null);
        } else {
            self.tree.zoom(self.active_handle);
        }
        window.layout();
    }

    /// Close a specific surface in this tab.
    /// Returns true if the entire tab should be removed (last surface closed).
    pub fn closeSurface(
        self: *Tab,
        window: *Window,
        surface: *Surface,
    ) !bool {
        const alloc = window.app.core_app.alloc;

        var handle: ?SurfaceSplitTree.Node.Handle = null;
        {
            var it = self.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) {
                    handle = entry.handle;
                    break;
                }
            }
        }

        const h = handle orelse return true;

        // Single surface: signal that tab should be removed.
        if (!self.tree.isSplit()) return true;

        // Find the next surface to focus.
        const next_surface: ?*Surface = blk: {
            if (try self.tree.goto(alloc, h, .previous)) |prev| {
                break :blk switch (self.tree.nodes[prev.idx()]) {
                    .leaf => |v| v,
                    .split => null,
                };
            }
            if (try self.tree.goto(alloc, h, .next)) |nxt| {
                break :blk switch (self.tree.nodes[nxt.idx()]) {
                    .leaf => |v| v,
                    .split => null,
                };
            }
            break :blk null;
        };

        const new_tree = try self.tree.remove(alloc, h);
        self.tree.deinit();
        self.tree = new_tree;

        if (next_surface) |ns| {
            var it = self.tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == ns) {
                    self.active_handle = entry.handle;
                    _ = c.SetFocus(ns.hwnd);
                    break;
                }
            }
        } else {
            self.active_handle = self.tree.deepest(.left, .root);
        }

        window.layout();
        return false;
    }

    /// Hide all surfaces in this tab.
    pub fn hideAll(self: *const Tab) void {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            _ = c.ShowWindow(entry.view.hwnd, c.SW_HIDE);
        }
    }

    /// Show all surfaces in this tab (layout will position them).
    pub fn showAll(self: *const Tab) void {
        var it = self.tree.iterator();
        while (it.next()) |entry| {
            _ = c.ShowWindow(entry.view.hwnd, c.SW_SHOW);
        }
    }
};

// ---------------------------------------------------------------
// Window public API
// ---------------------------------------------------------------

/// Get the tab bar height in pixels.
pub fn getTabBarHeight(self: *const Window) i32 {
    if (self.using_winui) {
        if (self.app.winui.tabview_get_height) |get_h| {
            return get_h(self.winui_tabview);
        }
    }
    return TabBar.HEIGHT;
}

/// Get the content area rect (where surfaces are drawn).
/// Reserves space for the tab bar at the top.
pub fn getContentRect(self: *const Window) c.RECT {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.getTabBarHeight();
    return rect;
}

/// Get the active tab.
pub fn activeTab(self: *Window) *Tab {
    return &self.tabs.items[self.active_tab_idx];
}

/// Get the currently active surface.
pub fn activeSurface(self: *Window) *Surface {
    return self.activeTab().activeSurface();
}

pub fn create(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);

    window.* = .{
        .hwnd = undefined,
        .app = app,
    };

    try window.createWindow();

    // Extend DWM frame into client area for custom titlebar.
    window.extendFrameIntoClientArea();

    // Try WinUI TabView first, fall back to GDI TabBar.
    if (app.winui.isAvailable()) {
        window.initWinUITabView();
    }

    if (!window.using_winui) {
        // Fallback: always create the GDI tab bar (it IS the titlebar).
        window.tab_bar = TabBar.create(window) catch |err| {
            log.warn("Failed to create tab bar: {}", .{err});
            return error.CreateWindowFailed;
        };
    }

    // Create the first surface and tab.
    const surface = try Surface.create(app, window);
    const tree = try SurfaceSplitTree.init(alloc, surface);

    try window.tabs.append(alloc, .{
        .tree = tree,
        .active_handle = .root,
    });

    // Initial layout so the tab bar shows the first tab.
    if (window.tab_bar) |tb| {
        tb.update(window.tabs.items.len, window.active_tab_idx);
    }

    log.info("Created Win32 window", .{});
    return window;
}

/// Layout the content area by positioning child HWNDs from the active tab's split tree.
pub fn layout(self: *Window) void {
    // Update tab controls.
    if (self.using_winui) {
        self.resizeWinUIHost();
    }
    if (self.tab_bar) |tb| {
        tb.update(self.tabs.items.len, self.active_tab_idx);
    }

    const content_rect = self.getContentRect();
    const cw: f32 = @floatFromInt(content_rect.right - content_rect.left);
    const ch: f32 = @floatFromInt(content_rect.bottom - content_rect.top);
    if (cw <= 0 or ch <= 0) return;

    if (self.tabs.items.len == 0) return;
    const tab = self.activeTab();

    const alloc = self.app.core_app.alloc;

    // If zoomed, show only the zoomed surface and hide all others.
    if (tab.tree.zoomed) |zoomed_handle| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle.idx() == zoomed_handle.idx()) {
                _ = c.ShowWindow(entry.view.hwnd, c.SW_SHOW);
                _ = c.SetWindowPos(
                    entry.view.hwnd,
                    null,
                    content_rect.left,
                    content_rect.top,
                    @intFromFloat(cw),
                    @intFromFloat(ch),
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                );
            } else {
                _ = c.ShowWindow(entry.view.hwnd, c.SW_HIDE);
            }
        }
        return;
    }

    // Normal layout: use spatial positions from the tree.
    var sp = tab.tree.spatial(alloc) catch return;
    defer sp.deinit(alloc);

    const has_splits = tab.tree.isSplit();

    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const slot = sp.slots[entry.handle.idx()];
        var x: i32 = content_rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(slot.x)) * cw));
        var y: i32 = content_rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(slot.y)) * ch));
        var w: i32 = @intFromFloat(@as(f32, @floatCast(slot.width)) * cw);
        var h: i32 = @intFromFloat(@as(f32, @floatCast(slot.height)) * ch);

        // Inset each surface to create a visible divider gap between splits.
        if (has_splits) {
            const sx: f32 = @floatCast(slot.x);
            const sy: f32 = @floatCast(slot.y);
            const sw: f32 = @floatCast(slot.width);
            const sh: f32 = @floatCast(slot.height);

            // Inset on edges that are internal (not at the content boundary).
            if (sx > 0.001) {
                x += DIVIDER_HALF;
                w -= DIVIDER_HALF;
            }
            if (sy > 0.001) {
                y += DIVIDER_HALF;
                h -= DIVIDER_HALF;
            }
            if (sx + sw < 0.999) {
                w -= DIVIDER_HALF;
            }
            if (sy + sh < 0.999) {
                h -= DIVIDER_HALF;
            }
        }

        _ = c.ShowWindow(entry.view.hwnd, c.SW_SHOW);
        _ = c.SetWindowPos(
            entry.view.hwnd,
            null,
            x,
            y,
            @max(1, w),
            @max(1, h),
            c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        );
    }

    // Repaint the window background so the divider color shows through gaps.
    if (has_splits) {
        _ = c.InvalidateRect(self.hwnd, null, 1);
    }
}

/// Close a specific surface. Called from WM_GHOSTTY_CLOSE_SURFACE.
pub fn closeSurface(self: *Window, surface: *Surface) void {
    // Find which tab contains this surface.
    for (self.tabs.items, 0..) |*tab, i| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) {
                const should_close_tab = tab.closeSurface(self, surface) catch |err| {
                    log.warn("Failed to close surface in split: {}", .{err});
                    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
                    return;
                };
                if (should_close_tab) {
                    self.closeTabAt(i);
                }
                return;
            }
        }
    }

    // Surface not found in any tab — close the window as fallback.
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

// ---------------------------------------------------------------
// Tab operations
// ---------------------------------------------------------------

/// Create a new tab with a single surface.
pub fn newTab(self: *Window) !void {
    const alloc = self.app.core_app.alloc;

    const new_surface = try Surface.create(self.app, self);
    errdefer {
        new_surface.destroyResources();
        _ = c.DestroyWindow(new_surface.hwnd);
        alloc.destroy(new_surface);
    }

    var config = try apprt.surface.newConfig(self.app.core_app, &self.app.config, .window);
    defer config.deinit();

    const core_surface = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core_surface);

    try self.app.core_app.addSurface(new_surface);
    errdefer self.app.core_app.deleteSurface(new_surface);

    try core_surface.init(alloc, &config, self.app.core_app, self.app, new_surface);
    new_surface.core_surface = core_surface;

    const scheme = detectColorScheme();
    core_surface.colorSchemeCallback(scheme) catch {};

    const tree = try SurfaceSplitTree.init(alloc, new_surface);

    try self.tabs.append(alloc, .{
        .tree = tree,
        .active_handle = .root,
    });

    // Add tab to WinUI TabView if active.
    if (self.using_winui) {
        if (self.app.winui.tabview_add_tab) |add_fn| {
            _ = add_fn(self.winui_tabview, "New Tab");
        }
    }

    // Switch to the new tab.
    self.switchToTab(self.tabs.items.len - 1);
}

/// Close a tab at the given index.
fn closeTabAt(self: *Window, idx: usize) void {
    if (self.tabs.items.len == 0) return;

    // If this is the last tab, close the whole window.
    if (self.tabs.items.len == 1) {
        _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
        return;
    }

    // Suppress WinUI SelectionChanged during removal — it fires
    // synchronously and would call switchToTab with stale indices.
    self.suppress_tab_selection = true;

    // Compute new active index BEFORE removing, so the render loop
    // never sees active_tab_idx pointing past the end of tabs.
    const new_len = self.tabs.items.len - 1;
    const new_active = if (self.active_tab_idx > idx)
        self.active_tab_idx - 1
    else if (self.active_tab_idx >= new_len)
        new_len - 1
    else
        self.active_tab_idx;
    self.active_tab_idx = new_active;

    // Deinit and remove the Zig tab.
    var tab = self.tabs.orderedRemove(idx);
    tab.deinit();

    // Now remove from WinUI TabView (may trigger SelectionChanged, but suppressed).
    if (self.using_winui) {
        if (self.app.winui.tabview_remove_tab) |rm_fn| {
            rm_fn(self.winui_tabview, @intCast(idx));
        }
    }

    self.suppress_tab_selection = false;

    // Sync WinUI selected index with our active tab.
    if (self.using_winui) {
        if (self.app.winui.tabview_select_tab) |sel_fn| {
            sel_fn(self.winui_tabview, @intCast(self.active_tab_idx));
        }
    }

    // Show the active tab's surfaces and layout.
    self.activeTab().showAll();
    self.layout();

    // Focus the active surface.
    _ = c.SetFocus(self.activeSurface().hwnd);
}

/// Close tabs based on mode (this, other, right).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode) void {
    switch (mode) {
        .this => {
            self.closeTabAt(self.active_tab_idx);
        },
        .other => {
            // Close all tabs except the active one.
            var i: usize = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (i != self.active_tab_idx) {
                    var tab = self.tabs.orderedRemove(i);
                    tab.deinit();
                    if (self.active_tab_idx > i) {
                        self.active_tab_idx -= 1;
                    }
                }
            }
            self.layout();
        },
        .right => {
            // Close all tabs to the right of active.
            while (self.tabs.items.len > self.active_tab_idx + 1) {
                var tab = self.tabs.orderedRemove(self.tabs.items.len - 1);
                tab.deinit();
            }
            self.layout();
        },
    }
}

/// Switch to a specific tab index.
fn switchToTab(self: *Window, idx: usize) void {
    if (idx >= self.tabs.items.len) return;
    if (idx == self.active_tab_idx and self.tabs.items.len > 1) {
        // Already active, just ensure focus.
        _ = c.SetFocus(self.activeSurface().hwnd);
        return;
    }

    // Hide current tab's surfaces.
    self.activeTab().hideAll();

    // Switch.
    self.active_tab_idx = idx;

    // Sync WinUI TabView selection.
    if (self.using_winui) {
        if (self.app.winui.tabview_select_tab) |sel_fn| {
            sel_fn(self.winui_tabview, @intCast(idx));
        }
    }

    // Show new tab's surfaces and layout.
    self.activeTab().showAll();
    self.layout();

    // Focus the active surface.
    _ = c.SetFocus(self.activeSurface().hwnd);
}

/// Go to a tab by GotoTab enum.
pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) void {
    const len = self.tabs.items.len;
    if (len == 0) return;

    const idx: usize = switch (target) {
        .previous => if (self.active_tab_idx == 0) len - 1 else self.active_tab_idx - 1,
        .next => if (self.active_tab_idx + 1 >= len) 0 else self.active_tab_idx + 1,
        .last => len - 1,
        _ => blk: {
            const i: usize = @intCast(@intFromEnum(target));
            break :blk if (i < len) i else return;
        },
    };

    self.switchToTab(idx);
}

/// Move the active tab by an offset (wrapping).
pub fn moveTab(self: *Window, amount: isize) void {
    const len: isize = @intCast(self.tabs.items.len);
    if (len <= 1) return;

    const cur: isize = @intCast(self.active_tab_idx);
    var new_pos = @mod(cur + amount, len);
    if (new_pos < 0) new_pos += len;
    const new_idx: usize = @intCast(new_pos);

    if (new_idx == self.active_tab_idx) return;

    const old_idx = self.active_tab_idx;

    // Swap the tab entries.
    const tmp = self.tabs.items[self.active_tab_idx];
    if (new_idx > self.active_tab_idx) {
        // Shift left.
        var i = self.active_tab_idx;
        while (i < new_idx) : (i += 1) {
            self.tabs.items[i] = self.tabs.items[i + 1];
        }
    } else {
        // Shift right.
        var i = self.active_tab_idx;
        while (i > new_idx) : (i -= 1) {
            self.tabs.items[i] = self.tabs.items[i - 1];
        }
    }
    self.tabs.items[new_idx] = tmp;
    self.active_tab_idx = new_idx;

    // Sync WinUI TabView.
    if (self.using_winui) {
        if (self.app.winui.tabview_move_tab) |move_fn| {
            move_fn(self.winui_tabview, @intCast(old_idx), @intCast(new_idx));
        }
    }

    // Repaint tab bar.
    if (self.tab_bar) |tb| {
        tb.update(self.tabs.items.len, self.active_tab_idx);
    }
}

/// Set the window title from a UTF-8 string.
pub fn setTitle(self: *Window, title: [:0]const u8) void {
    const len = @min(title.len, self.title_buf.len - 1);
    @memcpy(self.title_buf[0..len], title[0..len]);
    self.title_buf[len] = 0;
    self.title_len = @intCast(len);

    var wide_buf: [256]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, title[0..len]) catch 0;
    if (wide_len < wide_buf.len) {
        wide_buf[wide_len] = 0;
        const wide_z: [*:0]const u16 = wide_buf[0..wide_len :0];
        _ = c.SetWindowTextW(self.hwnd, wide_z);
    }

    // Update WinUI tab title if active.
    if (self.using_winui) {
        if (self.app.winui.tabview_set_tab_title) |set_title_fn| {
            set_title_fn(self.winui_tabview, @intCast(self.active_tab_idx), title);
        }
    }

    // Also repaint tab bar to show updated title.
    if (self.tab_bar) |tb| {
        tb.update(self.tabs.items.len, self.active_tab_idx);
    }
}

/// Get the window title if set.
pub fn getTitle(self: *const Window) ?[:0]const u8 {
    if (self.title_len == 0) return null;
    const slice = self.title_buf[0..self.title_len];
    if (self.title_len < self.title_buf.len and self.title_buf[self.title_len] == 0) {
        return slice.ptr[0..self.title_len :0];
    }
    return null;
}

/// Show or hide the key sequence indicator in the window title.
pub fn setKeySequenceActive(self: *Window, active: bool) void {
    if (self.key_sequence_active == active) return;
    self.key_sequence_active = active;

    // Append " [keys...]" indicator to the title when active, restore when done.
    if (active) {
        const suffix = " [keys...]";
        var wide_buf: [280]u16 = undefined;
        var pos: usize = 0;

        // Get current title.
        if (self.title_len > 0) {
            pos = std.unicode.utf8ToUtf16Le(&wide_buf, self.title_buf[0..self.title_len]) catch 0;
        }
        const suffix_len = std.unicode.utf8ToUtf16Le(wide_buf[pos..], suffix) catch 0;
        pos += suffix_len;
        if (pos < wide_buf.len) {
            wide_buf[pos] = 0;
            const wide_z: [*:0]const u16 = wide_buf[0..pos :0];
            _ = c.SetWindowTextW(self.hwnd, wide_z);
        }
    } else {
        // Restore the original title.
        if (self.title_len > 0) {
            var wide_buf: [256]u16 = undefined;
            const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, self.title_buf[0..self.title_len]) catch 0;
            if (wide_len < wide_buf.len) {
                wide_buf[wide_len] = 0;
                const wide_z: [*:0]const u16 = wide_buf[0..wide_len :0];
                _ = c.SetWindowTextW(self.hwnd, wide_z);
            }
        }
    }
}

/// Detect Windows dark/light mode from registry.
pub fn detectColorScheme() apprt.ColorScheme {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

    var hkey: c.HKEY = null;
    if (c.RegOpenKeyExW(c.HKEY_CURRENT_USER, subkey, 0, c.KEY_READ, &hkey) != 0) {
        return .dark;
    }
    defer _ = c.RegCloseKey(hkey);

    var data: u32 = 1;
    var data_size: c.DWORD = @sizeOf(u32);
    var reg_type: c.DWORD = 0;
    if (c.RegQueryValueExW(hkey, value_name, null, &reg_type, @ptrCast(&data), &data_size) != 0) {
        return .dark;
    }

    return if (data == 0) .dark else .light;
}

// ---------------------------------------------------------------
// Private implementation
// ---------------------------------------------------------------

fn createWindow(self: *Window) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const window_name_w = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

    const hwnd = c.CreateWindowExW(
        0,
        class_name_w,
        window_name_w,
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        self.app.hinstance,
        null,
    );

    if (hwnd == null) {
        log.err("Failed to create window", .{});
        return error.CreateWindowFailed;
    }

    self.hwnd = hwnd.?;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    log.info("Created top-level window", .{});
}

/// Get the split divider color from config, or fall back to a default.
fn getDividerColor(self: *const Window) c.COLORREF {
    if (self.app.config.@"split-divider-color") |color| {
        return c.RGB(color.r, color.g, color.b);
    }
    // Default: a subtle gray that works for dark themes.
    return c.RGB(80, 80, 80);
}

/// Extend the DWM frame into the client area so we paint over the titlebar.
/// We use a 1-pixel top margin to keep the DWM window shadow while we
/// paint our own titlebar/tab bar over the client area.
pub fn extendFrameIntoClientArea(self: *Window) void {
    self.updateDwmFrameMargins();
    // Trigger a frame change so Windows re-evaluates NC area.
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER,
    );
}

/// Update DWM frame margins. The top margin must cover the tab bar height
/// so DWM can render caption buttons (min/max/close) in the right area.
/// When maximized, we still need the margin for caption buttons but use
/// the tab bar height (not 0) since 0 would hide the buttons.
fn updateDwmFrameMargins(self: *Window) void {
    // Extend the DWM frame by 1px at the top for the drop shadow.
    // We don't extend by the full tab bar height because that causes
    // DWM to paint its glass/white frame behind the tab bar.
    const margins = c.MARGINS{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = 0,
        .cyBottomHeight = 0,
    };
    const hr = c.DwmExtendFrameIntoClientArea(self.hwnd, &margins);
    if (hr < 0) {
        log.warn("DwmExtendFrameIntoClientArea failed: {}", .{hr});
    }
}

/// Get the resize border thickness for the current DPI.
pub fn getResizeBorderThickness(self: *const Window) i32 {
    const dpi = c.GetDpiForWindow(self.hwnd);
    const frame = c.GetSystemMetricsForDpi(c.SM_CYFRAME, dpi);
    const padding = c.GetSystemMetricsForDpi(c.SM_CXPADDEDBORDER, dpi);
    return frame + padding;
}

/// Iterate all surfaces in all tabs.
fn forEachSurface(self: *Window, comptime callback: fn (*Surface) void) void {
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            callback(entry.view);
        }
    }
}

/// Window procedure for the top-level window.
pub fn windowProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    const window: ?*Window = if (ptr != 0)
        @ptrFromInt(@as(usize, @bitCast(ptr)))
    else
        null;

    switch (msg) {
        c.WM_NCCALCSIZE => {
            if (wparam != 0) {
                const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));

                if (c.IsZoomed(hwnd) != 0) {
                    // When maximized, Windows extends the window past the
                    // screen edges. Use the monitor workarea to get the
                    // correct bounds (accounts for taskbar, auto-hide, etc.)
                    // and avoids the thin white DWM frame strip at the top.
                    var mi: c.MONITORINFO = undefined;
                    mi.cbSize = @sizeOf(c.MONITORINFO);
                    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST);
                    if (monitor != null and c.GetMonitorInfoW(monitor.?, &mi) != 0) {
                        params.rgrc[0] = mi.rcWork;
                    }
                }
                // When not maximized: return 0 to make the entire window
                // rect our client area. The 1px DWM frame extension
                // (cyTopHeight=1) gives us the drop shadow.
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_NCHITTEST => {
            if (window) |w| {
                // Do NOT call DwmDefWindowProc when using WinUI — we provide
                // our own caption buttons via XAML. DwmDefWindowProc would
                // create invisible hit targets for DWM's built-in buttons.
                if (!w.using_winui) {
                    var dwm_result: LRESULT = 0;
                    if (c.DwmDefWindowProc(hwnd, msg, wparam, lparam, &dwm_result) != 0) {
                        return dwm_result;
                    }
                }

                // Get mouse position in screen coordinates.
                var cursor: c.POINT = .{
                    .x = c.GET_X_LPARAM(lparam),
                    .y = c.GET_Y_LPARAM(lparam),
                };

                // Get window rect in screen coordinates.
                var win_rect: c.RECT = undefined;
                if (c.GetWindowRect(hwnd, &win_rect) == 0) {
                    return c.HTCLIENT;
                }

                // Resize borders (only when not maximized and not fullscreen).
                if (c.IsZoomed(hwnd) == 0 and !w.is_fullscreen) {
                    const border = w.getResizeBorderThickness();

                    // Top edge.
                    if (cursor.y < win_rect.top + border) {
                        if (cursor.x < win_rect.left + border) return c.HTTOPLEFT;
                        if (cursor.x >= win_rect.right - border) return c.HTTOPRIGHT;
                        return c.HTTOP;
                    }
                    // Bottom edge.
                    if (cursor.y >= win_rect.bottom - border) {
                        if (cursor.x < win_rect.left + border) return c.HTBOTTOMLEFT;
                        if (cursor.x >= win_rect.right - border) return c.HTBOTTOMRIGHT;
                        return c.HTBOTTOM;
                    }
                    // Left/right edges.
                    if (cursor.x < win_rect.left + border) return c.HTLEFT;
                    if (cursor.x >= win_rect.right - border) return c.HTRIGHT;
                }

                // Convert to client coordinates for tab bar hit test.
                _ = c.ScreenToClient(hwnd, &cursor);

                // Tab bar area hit testing.
                const tab_height = w.getTabBarHeight();
                if (cursor.y < tab_height) {
                    if (w.using_winui) {
                        // The drag overlay window handles hit-testing for
                        // the XAML Island area. The parent just returns
                        // HTCLIENT here — the overlay intercepts mouse
                        // messages before the island gets them.
                        return c.HTCLIENT;
                    }
                    if (w.tab_bar) |tb| {
                        const zone = tb.hitTest(cursor.x, cursor.y);
                        if (TabBar.hitTestToNCHIT(zone)) |nc_hit| {
                            return nc_hit;
                        }
                        // Tab clicks, new-tab, etc. — handled in client area.
                        return c.HTCLIENT;
                    }
                }

                return c.HTCLIENT;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_NCACTIVATE => {
            // Return TRUE to prevent Windows from redrawing the default
            // non-client area (we draw our own titlebar).
            return 1;
        },

        c.WM_DESTROY => {
            log.info("WM_DESTROY received on window", .{});
            if (window) |w| {
                const alloc = w.app.core_app.alloc;

                // Deinit all tabs (unrefs all surfaces).
                for (w.tabs.items) |*tab| {
                    tab.deinit();
                }
                w.tabs.deinit(alloc);

                // Clean up WinUI controls.
                w.destroyWinUIControls();

                // Clean up tab bar.
                if (w.tab_bar) |tb| {
                    alloc.destroy(tb);
                    w.tab_bar = null;
                }

                w.app.removeWindow(w);
                const no_windows_left = w.app.windows.items.len == 0;

                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
                alloc.destroy(w);

                if (no_windows_left) {
                    c.PostQuitMessage(0);
                }
            } else {
                c.PostQuitMessage(0);
            }
            return 0;
        },

        c.WM_CLOSE => {
            log.info("WM_CLOSE received on window", .{});
            _ = c.DestroyWindow(hwnd);
            return 0;
        },

        c.WM_SIZE => {
            if (window) |w| {
                // Update DWM frame margins: 1px when restored (for shadow),
                // 0px when maximized (to avoid white strip at top).
                w.updateDwmFrameMargins();
                // Update tab bar.
                if (w.tab_bar) |tb| {
                    tb.update(w.tabs.items.len, w.active_tab_idx);
                }
                w.layout();
            }
            return 0;
        },

        c.WM_ERASEBKGND => {
            if (window) |w| {
                const hdc: c.HDC = @ptrFromInt(@as(usize, @bitCast(wparam)));
                var client_rect: c.RECT = undefined;
                if (c.GetClientRect(hwnd, &client_rect) != 0) {
                    // Paint tab bar area with dark background to match
                    // the WinUI theme.
                    const content_rect = w.getContentRect();
                    var top_rect = client_rect;
                    top_rect.bottom = content_rect.top;
                    const dark_brush = c.CreateSolidBrush(c.RGB(32, 32, 32));
                    _ = c.FillRect(hdc, &top_rect, dark_brush);
                    _ = c.DeleteObject(@ptrCast(dark_brush));

                    // Paint the content area with the divider color.
                    const divider_color = w.getDividerColor();
                    const brush = c.CreateSolidBrush(divider_color);
                    _ = c.FillRect(hdc, &content_rect, brush);
                    _ = c.DeleteObject(@ptrCast(brush));
                }
            }
            return 1;
        },

        c.WM_GETMINMAXINFO => {
            if (window) |w| {
                const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (w.min_width > 0) info.ptMinTrackSize.x = w.min_width;
                if (w.min_height > 0) info.ptMinTrackSize.y = w.min_height;
                if (w.max_width > 0) info.ptMaxTrackSize.x = w.max_width;
                if (w.max_height > 0) info.ptMaxTrackSize.y = w.max_height;
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wparam == Window.QUIT_TIMER_ID) {
                if (window) |w| {
                    w.app.terminate();
                }
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_SETTINGCHANGE => {
            if (window) |w| {
                if (lparam != 0) {
                    const setting_ptr: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                    const setting = std.mem.span(setting_ptr);
                    const immersive = std.unicode.utf8ToUtf16LeStringLiteral("ImmersiveColorSet");
                    if (std.mem.eql(u16, setting, immersive)) {
                        const scheme = detectColorScheme();
                        // Notify ALL surfaces in ALL tabs.
                        for (w.tabs.items) |*tab| {
                            var it = tab.tree.iterator();
                            while (it.next()) |entry| {
                                if (entry.view.core_surface) |cs| {
                                    cs.colorSchemeCallback(scheme) catch {};
                                }
                            }
                        }
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_DPICHANGED => {
            if (window) |w| {
                const new_dpi: u32 = @intCast(wparam & 0xFFFF);
                log.info("WM_DPICHANGED: new DPI={}", .{new_dpi});

                const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                );

                const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / 96.0;
                // Notify ALL surfaces in ALL tabs.
                for (w.tabs.items) |*tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| {
                        if (entry.view.core_surface) |cs| {
                            cs.contentScaleCallback(.{ .x = scale, .y = scale }) catch {};
                        }
                    }
                }
            }
            return 0;
        },

        c.WM_SETCURSOR => {
            if (c.LOWORD(lparam) == c.HTCLIENT) {
                _ = c.SetCursor(c.LoadCursorW(null, c.IDC_ARROW));
                return 1;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_CTLCOLORSTATIC => {
            if (window) |w| {
                const ctrl_hwnd: HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
                // Check if this STATIC control is a child-exited banner.
                for (w.tabs.items) |*tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| {
                        if (entry.view.banner_hwnd) |bh| {
                            if (bh == ctrl_hwnd) {
                                const hdc_static: c.HDC = @ptrFromInt(@as(usize, @bitCast(wparam)));
                                _ = c.SetTextColor(hdc_static, c.RGB(255, 255, 255));
                                const exit_code = if (entry.view.child_exited_info) |info| info.exit_code else 0;
                                const bg = if (exit_code != 0) c.RGB(180, 40, 40) else c.RGB(40, 140, 40);
                                _ = c.SetBkColor(hdc_static, bg);
                                // Return the cached brush from the surface.
                                if (entry.view.banner_brush) |brush| {
                                    return @bitCast(@intFromPtr(brush));
                                }
                            }
                        }
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_GHOSTTY_CLOSE_SURFACE => {
            if (window) |w| {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(wparam)));
                w.closeSurface(surface);
            }
            return 0;
        },

        WM_GHOSTTY_NEW_TAB => {
            if (window) |w| {
                w.newTab() catch |err| {
                    log.warn("Failed to create new tab: {}", .{err});
                };
            }
            return 0;
        },

        WM_GHOSTTY_CLOSE_TAB => {
            if (window) |w| {
                const idx: usize = @intCast(wparam);
                if (idx < w.tabs.items.len) {
                    w.closeTabAt(idx);
                }
            }
            return 0;
        },

        WM_GHOSTTY_SELECT_TAB => {
            if (window) |w| {
                const idx: usize = @intCast(wparam);
                w.switchToTab(idx);
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------
// WinUI integration helpers
// ---------------------------------------------------------------

/// Initialize WinUI XAML Island and TabView for this window.
fn initWinUITabView(self: *Window) void {
    const winui = &self.app.winui;

    // Create XAML Island host.
    if (winui.xaml_host_create) |create_fn| {
        self.winui_host = create_fn(self.hwnd);
    }
    if (self.winui_host == null) {
        const hr = winui.lastError();
        log.warn("Failed to create XAML host (HRESULT=0x{X:0>8}), falling back to GDI", .{@as(u32, @bitCast(hr))});
        return;
    }

    // Create TabView with callbacks.
    if (winui.tabview_create) |create_fn| {
        self.winui_tabview = create_fn(self.winui_host, .{
            .ctx = @ptrCast(self),
            .on_tab_selected = &winuiOnTabSelected,
            .on_tab_close_requested = &winuiOnTabCloseRequested,
            .on_new_tab_requested = &winuiOnNewTabRequested,
            .on_tab_reordered = &winuiOnTabReordered,
            .on_minimize = &winuiOnMinimize,
            .on_maximize = &winuiOnMaximize,
            .on_close = &winuiOnClose,
        });
    }
    if (self.winui_tabview == null) {
        log.warn("Failed to create WinUI TabView, falling back to GDI", .{});
        if (winui.xaml_host_destroy) |destroy_fn| {
            destroy_fn(self.winui_host);
        }
        self.winui_host = null;
        return;
    }

    self.using_winui = true;

    // Get the island HWND for debugging.
    const island_hwnd: ?HWND = if (winui.xaml_host_get_hwnd) |get_fn| get_fn(self.winui_host) else null;
    log.info("XAML Island HWND: {?}, parent HWND: {?}", .{ island_hwnd, self.hwnd });

    // Check island HWND parent and visibility.
    if (island_hwnd) |ih| {
        const actual_parent = c.GetParent(ih);
        const style = c.GetWindowLongPtrW(ih, c.GWL_STYLE);
        const is_visible = (style & @as(isize, c.WS_VISIBLE)) != 0;
        const is_child = (style & @as(isize, c.WS_CHILD)) != 0;
        log.info("Island parent: {?}, visible: {}, child: {}", .{ actual_parent, is_visible, is_child });

        // Force reparent if needed.
        if (actual_parent != self.hwnd) {
            log.warn("Island HWND not parented to our window! Reparenting...", .{});
            _ = c.SetParent(ih, self.hwnd);
        }
    }

    // Set initial theme.
    const scheme = detectColorScheme();
    const theme: i32 = if (scheme == .dark) WinUI.THEME_DARK else WinUI.THEME_LIGHT;
    if (winui.tabview_set_theme) |set_theme_fn| {
        set_theme_fn(self.winui_tabview, theme);
    }

    // Set initial tab bar background color from config.
    if (winui.tabview_set_background_color) |set_bg| {
        const bg = self.app.config.background;
        set_bg(self.winui_tabview, bg.r, bg.g, bg.b);
    }

    // Add the initial tab.
    if (winui.tabview_add_tab) |add_fn| {
        _ = add_fn(self.winui_tabview, "Ghostty");
    }

    // Position the XAML Island first so it has its final size/position.
    self.resizeWinUIHost();

    // Set up InputNonClientPointerSource for tab bar drag regions.
    if (winui.tabview_setup_drag_regions) |setup_fn| {
        log.info("initWinUITabView: setting up drag regions for HWND={?}", .{self.hwnd});
        setup_fn(self.winui_tabview, self.hwnd);
    }

    // Update DWM frame margins now that we know the tab bar height.
    // This is needed for DWM to render caption buttons in the right area.
    self.updateDwmFrameMargins();

    log.info("WinUI TabView created successfully", .{});
}

/// Resize the XAML Island host and drag overlay. When a WinUI search
/// panel is visible, the island extends to cover the full client area
/// so the search overlay can render over the terminal surface.
/// Otherwise it only covers the tab bar.
pub fn resizeWinUIHost(self: *Window) void {
    if (!self.using_winui) return;
    const winui = &self.app.winui;
    if (winui.xaml_host_resize) |resize_fn| {
        var client_rect: c.RECT = undefined;
        if (c.GetClientRect(self.hwnd, &client_rect) == 0) return;

        const width = client_rect.right - client_rect.left;
        const needs_overlay = self.hasVisibleWinUISearch();

        const tab_height: i32 = if (winui.tabview_get_height) |get_h|
            get_h(self.winui_tabview)
        else
            TabBar.HEIGHT;

        if (needs_overlay) {
            const height = client_rect.bottom - client_rect.top;
            resize_fn(self.winui_host, client_rect.left, 0, width, height);
        } else {
            resize_fn(self.winui_host, client_rect.left, 0, width, tab_height);
        }
        // Update drag regions after resize.
        if (winui.tabview_update_drag_regions) |update_fn| {
            update_fn(self.winui_tabview, self.hwnd);
        }
    }
}

/// Returns true if any surface in the active tab has a visible WinUI search panel.
fn hasVisibleWinUISearch(self: *const Window) bool {
    if (self.tabs.items.len == 0) return false;
    const tab = &self.tabs.items[self.active_tab_idx];
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.winui_search_visible) return true;
    }
    return false;
}

/// Destroy WinUI controls for this window.
fn destroyWinUIControls(self: *Window) void {
    if (!self.using_winui) return;
    const winui = &self.app.winui;

    if (winui.tabview_destroy) |destroy_fn| {
        destroy_fn(self.winui_tabview);
    }
    self.winui_tabview = null;

    if (winui.xaml_host_destroy) |destroy_fn| {
        destroy_fn(self.winui_host);
    }
    self.winui_host = null;

    self.using_winui = false;
}

// WinUI callback trampolines (C calling convention → Zig method calls).

fn winuiOnTabSelected(ctx: ?*anyopaque, index: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    if (self.suppress_tab_selection) return;
    self.switchToTab(@intCast(index));
}

fn winuiOnTabCloseRequested(ctx: ?*anyopaque, index: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    if (index < self.tabs.items.len) {
        self.closeTabAt(@intCast(index));
    }
}

fn winuiOnNewTabRequested(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    self.newTab() catch |err| {
        log.warn("Failed to create new tab from WinUI callback: {}", .{err});
    };
}

fn winuiOnTabReordered(ctx: ?*anyopaque, from: u32, to: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    _ = from;
    _ = to;
    // Tab reorder is handled by WinUI TabView itself.
    // We'd need to sync the Zig tabs array here if the WinUI
    // TabView fires this after a drag-drop reorder.
    // For now, the moveTab() function handles Zig-initiated moves.
    _ = self;
}

fn winuiOnMinimize(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    _ = c.ShowWindow(self.hwnd, c.SW_MINIMIZE);
}

fn winuiOnMaximize(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    if (c.IsZoomed(self.hwnd) != 0) {
        _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    } else {
        _ = c.ShowWindow(self.hwnd, c.SW_MAXIMIZE);
    }
}

fn winuiOnClose(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}
