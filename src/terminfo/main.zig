//! Package terminfo provides functionality related to terminfo/termcap files.
//!
//! At the time of writing this comment, the focus is on generating terminfo
//! files so that we can maintain our terminfo in Zig instead of hand-writing
//! the archaic (imo) terminfo format by hand. But eventually we may want to
//! extract this into a more full-featured library on its own.

pub const ghostty = @import("ghostty.zig").ghostty;
pub const version = @import("ghostty.zig").version;
pub const Source = @import("Source.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
