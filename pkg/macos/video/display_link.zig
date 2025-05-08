const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const DisplayLink = opaque {
    pub const Error = error{
        InvalidOperation,
    };

    pub fn createWithActiveCGDisplays() Allocator.Error!*DisplayLink {
        var result: ?*DisplayLink = null;
        if (c.CVDisplayLinkCreateWithActiveCGDisplays(
            @ptrCast(&result),
        ) != c.kCVReturnSuccess)
            return error.OutOfMemory;

        return result orelse error.OutOfMemory;
    }

    pub fn release(self: *DisplayLink) void {
        c.CVDisplayLinkRelease(@ptrCast(self));
    }

    pub fn start(self: *DisplayLink) Error!void {
        if (c.CVDisplayLinkStart(@ptrCast(self)) != c.kCVReturnSuccess)
            return error.InvalidOperation;
    }

    pub fn stop(self: *DisplayLink) Error!void {
        if (c.CVDisplayLinkStop(@ptrCast(self)) != c.kCVReturnSuccess)
            return error.InvalidOperation;
    }

    pub fn isRunning(self: *DisplayLink) bool {
        return c.CVDisplayLinkIsRunning(@ptrCast(self)) != 0;
    }

    pub fn setCurrentCGDisplay(
        self: *DisplayLink,
        display_id: c.CGDirectDisplayID,
    ) Error!void {
        if (c.CVDisplayLinkSetCurrentCGDisplay(
            @ptrCast(self),
            display_id,
        ) != c.kCVReturnSuccess)
            return error.InvalidOperation;
    }

    // Note: this purposely throws away a ton of arguments I didn't need.
    // It would be trivial to refactor this into Zig types and properly
    // pass this through.
    pub fn setOutputCallback(
        self: *DisplayLink,
        comptime Userdata: type,
        comptime callbackFn: *const fn (*DisplayLink, ?*Userdata) void,
        userinfo: ?*Userdata,
    ) Error!void {
        if (c.CVDisplayLinkSetOutputCallback(
            @ptrCast(self),
            @ptrCast(&(struct {
                fn callback(
                    displayLink: *DisplayLink,
                    inNow: *const c.CVTimeStamp,
                    inOutputTime: *const c.CVTimeStamp,
                    flagsIn: c.CVOptionFlags,
                    flagsOut: *c.CVOptionFlags,
                    inner_userinfo: ?*anyopaque,
                ) callconv(.c) c.CVReturn {
                    _ = inNow;
                    _ = inOutputTime;
                    _ = flagsIn;
                    _ = flagsOut;

                    callbackFn(
                        displayLink,
                        @alignCast(@ptrCast(inner_userinfo)),
                    );
                    return c.kCVReturnSuccess;
                }
            }).callback),
            userinfo,
        ) != c.kCVReturnSuccess)
            return error.InvalidOperation;
    }
};
