pub const c = @import("dispatch/c.zig").c;
pub const data = @import("dispatch/data.zig");
pub const queue = @import("dispatch/queue.zig");
pub const Data = data.Data;

pub extern "c" fn dispatch_sync(
    queue: *anyopaque,
    block: *anyopaque,
) void;

pub extern "c" fn dispatch_async(
    queue: *anyopaque,
    block: *anyopaque,
) void;

test {
    @import("std").testing.refAllDecls(@This());
}
