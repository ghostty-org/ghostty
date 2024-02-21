const builtin = @import("builtin");

pub const Terminal = @import("Terminal.zig");

test {
    @import("std").testing.refAllDecls(@This());

    // todo: make top-level imports
    _ = @import("bitmap_allocator.zig");
    _ = @import("hash_map.zig");
    _ = @import("page.zig");
    _ = @import("PageList.zig");
    _ = @import("Screen.zig");
    _ = @import("point.zig");
    _ = @import("size.zig");
    _ = @import("style.zig");
}
