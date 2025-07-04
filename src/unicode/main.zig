const std = @import("std");
pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
const props = @import("props.zig");
pub const table = props.table;
pub const Properties = props.Properties;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const GraphemeBreakState = grapheme.BreakState;

test {
    @import("std").testing.refAllDecls(@This());
}

/// Build Ghostty with `zig build -Doptimize=ReleaseFast -Demit-unicode-test`.
///
/// Usage: ./zig-out/bin/unicode-test [grapheme|width|all] [zg|ziglyph|all]
///
///     grapheme: this will verify the grapheme break implementation. This
///               iterates over billions of codepoints so it is SLOW.
///
///     width:    this verifies the table codepoint widths match
///     zg:       compare grapheme/width against zg
///     ziglyph:  compare grapheme/width against ziglyph
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var zg = try props.init(alloc);
    defer zg.deinit(alloc);

    const ziglyph = @import("ziglyph");
    const Graphemes = @import("Graphemes");
    const DisplayWidth = @import("DisplayWidth");

    const testAll = args.len < 2 or std.mem.eql(u8, args[1], "all");
    const compareAll = args.len < 3 or std.mem.eql(u8, args[2], "all");
    const compareZg = compareAll or std.mem.eql(u8, args[2], "zg");
    const compareZiglyph = compareAll or std.mem.eql(u8, args[2], "ziglyph");

    // Set the min and max to control the test range.
    const min = 0;
    const max = 0x110000;

    var state: GraphemeBreakState = .{};
    var zg_state: Graphemes.State = .{};
    var ziglyph_state: u3 = 0;

    if (testAll or std.mem.eql(u8, args[1], "grapheme")) {
        std.log.info("============== testing grapheme break ===============", .{});

        for (min..max) |cp1| {
            if (cp1 % 0x100 == 0) std.log.info("progress: cp1={x}", .{cp1});

            if (cp1 == '\r' or cp1 == '\n' or
                Graphemes.gbp(zg.graphemes, @intCast(cp1)) == .Control) continue;

            for (min..max) |cp2| {
                if (cp2 == '\r' or cp2 == '\n' or
                    Graphemes.gbp(zg.graphemes, @intCast(cp1)) == .Control) continue;

                const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);
                if (compareZg) {
                    const zg_gb = Graphemes.graphemeBreak(@intCast(cp1), @intCast(cp2), &zg.graphemes, &zg_state);
                    if (gb != zg_gb) {
                        std.log.warn("[zg mismatch] cp1={x} cp2={x} gb={} zg_gb={} state={} zg_state={}", .{
                            cp1,
                            cp2,
                            gb,
                            zg_gb,
                            state,
                            zg_state,
                        });
                    }
                }
                if (compareZiglyph) {
                    const ziglyph_gb = ziglyph.graphemeBreak(@intCast(cp1), @intCast(cp2), &ziglyph_state);
                    if (gb != ziglyph_gb) {
                        std.log.warn("[ziglyph mismatch] cp1={x} cp2={x} gb={} ziglyph_gb={} state={} ziglyph_state={}", .{
                            cp1,
                            cp2,
                            gb,
                            ziglyph_gb,
                            state,
                            ziglyph_state,
                        });
                    }
                }
            }
        }
    }

    if (testAll or std.mem.eql(u8, args[1], "width")) {
        std.log.info("============== testing codepoint width ==============", .{});

        for (min..max) |cp| {
            if (cp % 0x10000 == 0) std.log.info("progress: cp={x}", .{cp});

            const t = table.get(@intCast(cp));
            if (compareZg) {
                const zg_width = @min(2, @max(0, DisplayWidth.codePointWidth(zg.display_width, @intCast(cp))));
                if (t.width != zg_width) {
                    std.log.warn("[zg mismatch] cp={x} t={} zg={}", .{ cp, t.width, zg_width });
                }
            }
            if (compareZiglyph) {
                const ziglyph_width = @min(2, @max(0, DisplayWidth.codePointWidth(zg.display_width, @intCast(cp))));
                if (t.width != ziglyph_width) {
                    std.log.warn("[ziglyph mismatch] cp={x} t={} zg={}", .{ cp, t.width, ziglyph_width });
                }
            }
        }
    }
}

pub const std_options: std.Options = .{
    .log_level = .debug,
};
