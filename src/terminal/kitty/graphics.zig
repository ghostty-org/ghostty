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

const render = @import("graphics_render.zig");
const command = @import("graphics_command.zig");
const exec = @import("graphics_exec.zig");
const image = @import("graphics_image.zig");
const storage = @import("graphics_storage.zig");
pub const unicode = @import("graphics_unicode.zig");
pub const Command = command.Command;
pub const CommandParser = command.Parser;
pub const Image = image.Image;
pub const ImageStorage = storage.ImageStorage;
pub const RenderPlacement = render.Placement;
pub const Response = command.Response;

pub const execute = exec.execute;

test {
    @import("std").testing.refAllDecls(@This());
}
