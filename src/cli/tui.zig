const builtin = @import("builtin");

pub const can_pretty_print = switch (builtin.os.tag) {
    .ios, .tvos, .visionos, .watchos => false,
    else => true,
};
