const std = @import("std");
const c = @import("c.zig").c;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const org = wayland.client.org;

const log = std.log.scoped(.gtk_wayland);

const Wayland = @This();

surface: *wl.Surface,

blur_manager: ?*org.KdeKwinBlurManager = null,
blur_token: ?*org.KdeKwinBlur = null,

pub fn init(window: *c.GtkWindow) !?Wayland {
    const surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return null;
    const display = c.gdk_surface_get_display(surface) orelse return null;

    // Check if we're actually on Wayland
    if (c.g_type_check_instance_is_a(
        @ptrCast(@alignCast(surface)),
        c.gdk_wayland_surface_get_type(),
    ) == 0)
        return null;

    const wl_surface: *wl.Surface = @ptrCast(c.gdk_wayland_surface_get_wl_surface(surface) orelse return null);
    const wl_display: *wl.Display = @ptrCast(c.gdk_wayland_display_get_wl_display(display) orelse return null);

    const registry = try wl_display.getRegistry();

    var self = Wayland{ .surface = wl_surface };

    registry.setListener(*Wayland, registryListener, &self);
    if (wl_display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    log.debug("wayland init={}", .{self});

    return self;
}

pub fn setBlur(self: *Wayland, blurred: bool) !void {
    log.debug("setting blur={}", .{blurred});

    const mgr = self.blur_manager orelse {
        log.warn("can't set blur: org_kde_kwin_blur_manager protocol unavailable", .{});
        return;
    };

    if (self.blur_token) |*tok| {
        // Only release token when transitioning from blurred -> not blurred
        if (!blurred) {
            mgr.unset(self.surface);
            tok.*.release();
            self.blur_token = null;
        }
    } else {
        // Only acquire token when transitioning from not blurred -> blurred
        if (blurred) {
            const blur_token = try mgr.create(self.surface);
            blur_token.commit();
            self.blur_token = blur_token;
        }
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, state: *Wayland) void {
    switch (event) {
        .global => |global| {
            log.debug("got global interface={s}", .{global.interface});
            if (bindInterface(org.KdeKwinBlurManager, registry, global, 1)) |iface| {
                state.blur_manager = iface;
                return;
            }
        },
        .global_remove => {},
    }
}

fn bindInterface(comptime T: type, registry: *wl.Registry, global: anytype, version: u32) ?*T {
    if (std.mem.orderZ(u8, global.interface, T.interface.name) == .eq) {
        return registry.bind(global.name, T, version) catch |err| {
            log.warn("encountered error={} while binding interface {s}", .{ err, global.interface });
            return null;
        };
    } else {
        return null;
    }
}
