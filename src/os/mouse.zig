const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const objc = @import("objc");

const log = std.log.scoped(.os);

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    // On macOS, we can ask the system.
    if (comptime builtin.target.isDarwin()) {
        const NSEvent = objc.Class.getClass("NSEvent") orelse {
            log.err("NSEvent class not found. Can't get click interval.", .{});
            return null;
        };

        // Get the interval and convert to ms
        const interval = NSEvent.msgSend(f64, objc.sel("doubleClickInterval"), .{});
        const ms = @as(u32, @intFromFloat(@ceil(interval * 1000)));
        return ms;
    }

    return null;
}
