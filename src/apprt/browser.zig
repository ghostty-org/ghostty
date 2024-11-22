const CoreSurface = @import("../Surface.zig");
const CoreApp = @import("../App.zig");
const apprt = @import("../apprt.zig");
const std = @import("std");
const log = std.log;

pub const App = struct {
    app: *CoreApp,

    pub const Options = struct {};
    pub fn init(core_app: *CoreApp, _: Options) !App {
        return .{ .app = core_app };
    }
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !void {
        switch (action) {
            .new_window => _ = try self.newSurface(switch (target) {
                .app => null,
                .surface => |v| v,
            }),

            .new_tab => try self.newTab(switch (target) {
                .app => null,
                .surface => |v| v,
            }),

            .initial_size => switch (target) {
                .app => {},
                .surface => |surface| try surface.rt_surface.setInitialWindowSize(
                    value.width,
                    value.height,
                ),
            },

            // Unimplemented
            .size_limit,
            .toggle_fullscreen,
            .set_title,
            .mouse_shape,
            .mouse_visibility,
            .open_config,
            .new_split,
            .goto_split,
            .resize_split,
            .equalize_splits,
            .toggle_split_zoom,
            .present_terminal,
            .close_all_windows,
            .toggle_tab_overview,
            .toggle_window_decorations,
            .toggle_quick_terminal,
            .toggle_visibility,
            .goto_tab,
            .move_tab,
            .inspector,
            .render_inspector,
            .quit_timer,
            .secure_input,
            .key_sequence,
            .desktop_notification,
            .mouse_over_link,
            .cell_size,
            .renderer_health,
            .color_change,
            .pwd,
            .config_change_conditional_state,
            => log.info("unimplemented action={}", .{action}),
        }
    }
    pub fn wakeup(self: *const App) void {
        _ = self;
    }
};
pub const Window = struct {};
pub const Surface = struct {
    pub const opengl_single_threaded_draw = true;
    /// The app we're part of
    app: *App,

    /// A core surface
    core_surface: CoreSurface,
    pub fn init(self: *Surface, app: *App) !void {
        self.app = app;
    }
    pub fn getContentScale(_: *const Surface) !apprt.ContentScale {
        return apprt.ContentScale{ .x = 1, .y = 1 };
    }
    pub fn getSize(_: *const Surface) !apprt.SurfaceSize {
        return apprt.SurfaceSize{ .width = 500, .height = 500 };
    }
    fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
        _ = height; // autofix
        _ = self; // autofix
        _ = width; // autofix
    }
};
