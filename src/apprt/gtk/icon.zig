const std = @import("std");

const App = @import("App.zig");
const c = @import("c.zig");
const global_state = &@import("../../main.zig").state;

const log = std.log.scoped(.gtk_icon);

/// An icon. The icon may be associated with some allocated state so when
/// the icon is no longer in use it should be deinitialized.
pub const Icon = struct {
    name: [:0]const u8,
    state: ?[:0]const u8 = null,

    pub fn deinit(self: *const Icon, app: *App) void {
        if (self.state) |v| app.core_app.alloc.free(v);
    }
};

/// Returns the application icon that can be used anywhere. This attempts to
/// find the icon in the theme and if it can't be found, it is loaded from
/// the resources dir. If the resources dir can't be found, we'll log a warning
/// and let GTK choose a fallback.
pub fn appIcon(app: *App, widget: *c.GtkWidget) !Icon {
    const icon_name = "com.mitchellh.ghostty";
    var result: Icon = .{ .name = icon_name };

    // If we don't have the icon then we'll try to add our resources dir
    // to the search path and see if we can find it there.
    const icon_theme = c.gtk_icon_theme_get_for_display(c.gtk_widget_get_display(widget));
    if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) icon: {
        const base = global_state.resources_dir orelse {
            log.info("gtk app missing Ghostty icon and no resources dir detected", .{});
            log.info("gtk app will not have Ghostty icon", .{});
            break :icon;
        };

        // Note that this method for adding the icon search path is
        // a fallback mechanism. The recommended mechanism is the
        // Freedesktop Icon Theme Specification. We distribute a ".desktop"
        // file in zig-out/share that should be installed to the proper
        // place.
        const dir = try std.fmt.allocPrintZ(app.core_app.alloc, "{s}/icons", .{base});
        errdefer app.core_app.alloc.free(dir);
        result.state = dir;
        c.gtk_icon_theme_add_search_path(icon_theme, dir.ptr);
        if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) {
            log.warn("Ghostty icon for gtk app not found", .{});
        }
    }

    return result;
}
