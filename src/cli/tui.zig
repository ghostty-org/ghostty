const builtin = @import("builtin");

pub const can_pretty_print = switch (builtin.target.os.tag) {
    .ios, .tvos, .watchos => false,
    else => true,
};
