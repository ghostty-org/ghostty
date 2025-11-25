const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const terminal = @import("../main.zig");

/// A render placement is a way to position a Kitty graphics image onto
/// the screen. It is broken down into the fields that make it easier to
/// position the image using a renderer.
pub const Placement = struct {
    /// The top-left corner of the image in grid coordinates.
    top_left: terminal.Pin,

    /// The offset in pixels from the top-left corner of the grid cell.
    offset_x: u32 = 0,
    offset_y: u32 = 0,

    /// The source rectangle of the image to render. This doesn't have to
    /// match the size the destination size and the renderer is expected
    /// to scale the image to fit the destination size.
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,

    /// The final width/height of the image in pixels.
    dest_width: u32 = 0,
    dest_height: u32 = 0,
};
