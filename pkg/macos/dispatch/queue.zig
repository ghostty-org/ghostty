const std = @import("std");
const c = @import("c");

pub const Queue = *anyopaque; // dispatch_queue_t

pub fn getMain() Queue {
    return c.dispatch_get_main_queue().?;
}
