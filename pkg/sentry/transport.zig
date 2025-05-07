const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const Envelope = @import("envelope.zig").Envelope;

/// sentry_transport_t
pub const Transport = opaque {
    pub const SendFunc = *const fn (envelope: *Envelope, state: ?*anyopaque) callconv(.c) void;
    pub const FreeFunc = *const fn (state: ?*anyopaque) callconv(.c) void;

    pub fn init(f: SendFunc) *Transport {
        return @ptrCast(c.sentry_transport_new(@ptrCast(f)).?);
    }

    pub fn deinit(self: *Transport) void {
        c.sentry_transport_free(@ptrCast(self));
    }

    pub fn setState(self: *Transport, state: ?*anyopaque) void {
        c.sentry_transport_set_state(@ptrCast(self), state);
    }

    pub fn setStateFreeFunc(self: *Transport, f: FreeFunc) void {
        c.sentry_transport_set_free_func(@ptrCast(self), f);
    }
};
