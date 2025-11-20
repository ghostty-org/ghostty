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
    pub fn init(app_id: [*:0]const u8) Settings {
        // Check if schema exists before trying to use it
        const source = gio.SettingsSchemaSource.getDefault() orelse {
            log.warn("no GSettings schema source available", .{});
            return .{ .settings = null };
        };

        const schema = gio.SettingsSchemaSource.lookup(
            source,
            app_id,
            @intFromBool(false),
        ) orelse {
            log.warn("GSettings schema '{s}' not installed, window state will not persist", .{app_id});
            return .{ .settings = null };
        };
        defer schema.unref();

        // Attempt to fetch and log localized summary/description for our key.
        // We only do this for debugging/verification of translations.
        const key_name: [*:0]const u8 = "window-size";
        if (getSchemaKey(schema, key_name)) |key| {
            defer schemaKeyUnref(key);
            const summary = schemaKeyGetSummary(key) orelse "(null)";
            const desc = schemaKeyGetDescription(key) orelse "(null)";
            log.debug(
                "schema key '{s}' summary='{s}' description='{s}'",
                .{ key_name, summary, desc },
            );
        } else {
            log.debug("failed to lookup schema key '{s}' for translation test", .{key_name});
        }

        const settings = gio.Settings.new(app_id);
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

        return .{
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

// Minimal extern bindings for GSettingsSchemaKey access. We keep them local
// to this file since we only need them for debug logging of translations.
extern fn g_settings_schema_get_key(schema: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn g_settings_schema_key_get_summary(key: *anyopaque) ?[*:0]const u8;
extern fn g_settings_schema_key_get_description(key: *anyopaque) ?[*:0]const u8;
extern fn g_settings_schema_key_unref(key: *anyopaque) void;

fn getSchemaKey(schema: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return g_settings_schema_get_key(schema, name);
}

fn schemaKeyGetSummary(key: *anyopaque) ?[*:0]const u8 {
    return g_settings_schema_key_get_summary(key);
}

fn schemaKeyGetDescription(key: *anyopaque) ?[*:0]const u8 {
    return g_settings_schema_key_get_description(key);
}

fn schemaKeyUnref(key: *anyopaque) void {
    g_settings_schema_key_unref(key);
}
