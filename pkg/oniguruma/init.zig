const c = @import("c.zig").c;
const Encoding = @import("types.zig").Encoding;
const errors = @import("errors.zig");

/// Call once per process to initialize Oniguruma. This should be given
/// the encodings that the program will use.
pub fn init(encs: []const *Encoding) !void {
    _ = try errors.convertError(c.onig_initialize(
        @ptrCast(@alignCast(@constCast(encs.ptr))),
        @intCast(encs.len),
    ));
}

pub fn deinit() void {
    _ = c.onig_end();
}
