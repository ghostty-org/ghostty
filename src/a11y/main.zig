//! The a11y package contains accessibility logic that is independent of
//! any application runtime: building the flat UTF-8 text snapshot of a
//! terminal viewport that assistive technology clients read, and the
//! offset math for navigating it.

pub const offsets = @import("offsets.zig");
pub const text = @import("text.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
