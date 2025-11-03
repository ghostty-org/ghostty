//! GSettings wrapper for window state persistence on Linux
const std = @import("std");
const build_config = @import("../../build_config.zig");
const gio = @import("gio");
const glib = @import("glib");

const log = std.log.scoped(.gtk_settings);

/// Window size in terminal grid dimensions (columns, rows)
pub const WindowSize = struct {
    columns: u32,
    rows: u32,
};

/// GSettings wrapper for Ghostty window state
pub const Settings = struct {
    settings: ?*gio.Settings,

    /// Initialize GSettings. Returns null if schema is not installed.
    pub fn init() Settings {
        // Check if schema exists before trying to use it
        const source = gio.SettingsSchemaSource.getDefault() orelse {
            log.warn("no GSettings schema source available", .{});
            return .{ .settings = null };
        };

        const schema = gio.SettingsSchemaSource.lookup(
            source,
            build_config.bundle_id,
            @intFromBool(false),
        ) orelse {
            log.info("GSettings schema '{s}' not installed, window state will not persist", .{build_config.bundle_id});
            return .{ .settings = null };
        };
        defer schema.unref();

        const settings = gio.Settings.new(build_config.bundle_id);
        return .{ .settings = settings };
    }

    pub fn deinit(self: *Settings) void {
        if (self.settings) |s| {
            s.unref();
            self.settings = null;
        }
    }

    /// Get the last saved window size
    pub fn getWindowSize(self: *const Settings) ?WindowSize {
        const settings = self.settings orelse return null;

        var columns: c_uint = 0;
        var rows: c_uint = 0;

        gio.Settings.get(
            settings,
            "window-size",
            "(uu)",
            &columns,
            &rows,
        );

        // Sanity check the values
        if (columns == 0 or rows == 0 or columns > 999 or rows > 999) {
            return null;
        }

        return WindowSize{
            .columns = @intCast(columns),
            .rows = @intCast(rows),
        };
    }

    /// Save the current window size
    pub fn setWindowSize(self: *const Settings, size: WindowSize) void {
        const settings = self.settings orelse return;

        const columns: c_uint = @intCast(size.columns);
        const rows: c_uint = @intCast(size.rows);

        _ = gio.Settings.set(
            settings,
            "window-size",
            "(uu)",
            columns,
            rows,
        );

        log.debug("saved window size: {}x{}", .{ size.columns, size.rows });
    }
};
