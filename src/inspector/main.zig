const std = @import("std");
const builtin = @import("builtin");
pub const cell = @import("cell.zig");
pub const cursor = @import("cursor.zig");
pub const key = @import("key.zig");
pub const page = @import("page.zig");
pub const termio = @import("termio.zig");

pub const Cell = cell.Cell;
pub const Inspector = if (builtin.cpu.arch != .wasm32) @import("Inspector.zig") else struct {};

test {
    @import("std").testing.refAllDecls(@This());
}
