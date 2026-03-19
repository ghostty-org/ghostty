const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

/// Maximum number of bytes that `encode` will write. Any users of this
/// should be resilient to this changing, so this is always a specific
/// value (e.g. we don't add unnecessary padding).
pub const max_encode_size = 3;

/// A focus event that can be reported to the application running in the
/// terminal when focus reporting mode (mode 1004) is enabled.
pub const Event = lib.Enum(lib_target, &.{
    "gained",
    "lost",
});

/// Encode a focus in/out report (CSI I / CSI O).
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (event) {
        .gained => "\x1B[I",
        .lost => "\x1B[O",
    });
}

test "encode focus gained" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .gained);
    try std.testing.expectEqualStrings("\x1B[I", writer.buffered());
}

test "encode focus lost" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .lost);
    try std.testing.expectEqualStrings("\x1B[O", writer.buffered());
}
