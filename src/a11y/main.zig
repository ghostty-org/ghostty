//! Accessibility code that does not depend on an apprt.

pub const offsets = @import("offsets.zig");
pub const text = @import("text.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
