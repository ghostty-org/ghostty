const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");
const lut = @import("lut.zig");
const Properties = @import("props.zig").Properties;

pub fn get(cp: u21) Properties {
    if (cp > uucode.config.max_code_point) return .{
        .width = 1,
        .width_zero_in_grapheme = true,
        .grapheme_break = .other,
        .emoji_vs_base = false,
    };

    return .{
        .width = uucode.get(.width, cp),
        .width_zero_in_grapheme = uucode.get(.wcwidth_zero_in_grapheme, cp),
        .grapheme_break = uucode.get(.grapheme_break_no_control, cp),
        .emoji_vs_base = uucode.get(.is_emoji_vs_base, cp),
    };
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const gen: lut.Generator(
        Properties,
        struct {
            pub fn get(ctx: @This(), cp: u21) !Properties {
                _ = ctx;
                return props.get(cp);
            }

            pub fn eql(ctx: @This(), a: Properties, b: Properties) bool {
                _ = ctx;
                return a.eql(b);
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    try t.writeZig(&stdout.interface);
    // Use flush instead of end because stdout is a pipe when captured by
    // the build system, and pipes cannot be truncated (Windows returns
    // INVALID_PARAMETER, Linux returns EINVAL).
    try stdout.interface.flush();

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

test "unicode props: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("props_table.zig").table;

    const min = 0xFF + 1; // start outside ascii
    const max = std.math.maxInt(u21) + 1;
    for (min..max) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            1
        else
            uucode.get(.width, @intCast(cp));
        if (t.width != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t.width, uu });
            try testing.expect(false);
        }
    }
}
