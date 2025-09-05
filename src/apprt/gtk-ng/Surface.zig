const Self = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const Application = @import("class/application.zig").Application;
const Surface = @import("class/surface.zig").Surface;

/// The GObject Surface
surface: *Surface,

pub fn deinit(self: *Self) void {
    _ = self;
}

/// Returns the GObject surface for this apprt surface. This is a function
/// so we can add some extra logic if we ever have to here.
pub fn gobj(self: *Self) *Surface {
    return self.surface;
}

pub fn core(self: *Self) *CoreSurface {
    // This asserts the non-optional because libghostty should only
    // be calling this for initialized surfaces.
    return self.surface.core().?;
}

pub fn rtApp(self: *Self) *ApprtApp {
    _ = self;
    return Application.default().rt();
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;
    self.surface.close();
}

pub fn cgroup(self: *Self) ?[]const u8 {
    return self.surface.cgroupPath();
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.surface.getTitle();
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    return self.surface.getContentScale();
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return self.surface.getSize();
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.surface.getCursorPos();
}

pub fn supportsClipboard(
    self: *const Self,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard,
        .selection,
        .primary,
        => true,
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !void {
    try self.surface.clipboardRequest(
        clipboard_type,
        state,
    );
}

pub fn setClipboardString(
    self: *Self,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    self.surface.setClipboardString(
        val,
        clipboard_type,
        confirm,
    );
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    return try self.surface.defaultTermioEnv();
}

/// Redraw the inspector for our surface.
pub fn redrawInspector(self: *Self) void {
    self.surface.redrawInspector();
}

/// Handle the toggle_search_mode action from the core terminal.
/// This shows or hides the search bar widget in the GTK interface.
/// When toggled on, the search bar appears and gets keyboard focus.
/// When toggled off, the search bar disappears and focus returns to terminal.
pub fn actionToggleSearchMode(self: *Self, action: *const apprt.action.ToggleSearchMode) !void {
    self.surface.toggleSearchMode(action.visible);
}

/// Handle the update_search_results action from the core terminal.
/// This updates the search bar display to show current search results.
/// The search bar will show "X of Y matches" or "No results" based on the data.
pub fn actionUpdateSearchResults(self: *Self, action: *const apprt.action.UpdateSearchResults) !void {
    self.surface.updateSearchResults(action.current, action.total);
}
