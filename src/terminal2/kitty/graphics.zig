//! Kitty graphics protocol support.
//!
//! Documentation:
//! https://sw.kovidgoyal.net/kitty/graphics-protocol
//!
//! Unimplemented features that are still todo:
//! - shared memory transmit
//! - virtual placement w/ unicode
//! - animation
//!
//! Performance:
//! The performance of this particular subsystem of Ghostty is not great.
//! We can avoid a lot more allocations, we can replace some C code (which
//! implicitly allocates) with native Zig, we can improve the data structures
//! to avoid repeated lookups, etc. I tried to avoid pessimization but my
//! aim to ship a v1 of this implementation came at some cost. I learned a lot
//! though and I think we can go back through and fix this up.

pub usingnamespace @import("graphics_command.zig");
pub usingnamespace @import("graphics_exec.zig");
pub usingnamespace @import("graphics_image.zig");
pub usingnamespace @import("graphics_storage.zig");
