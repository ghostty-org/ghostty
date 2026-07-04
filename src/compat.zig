const builtin = @import("builtin");
const std = @import("std");

pub const max_path_bytes = switch (builtin.os.tag) {
    .visionos => 4096,
    else => std.fs.max_path_bytes,
};
