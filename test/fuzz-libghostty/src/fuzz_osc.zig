const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const mem = @import("mem.zig");
const osc = ghostty_vt.osc;

/// Use a single global allocator for simplicity and to avoid heap
/// allocation overhead in the fuzzer. The allocator is backed by a fixed
/// buffer, and every fuzz input resets the bump pointer to the start.
var fuzz_alloc: mem.FuzzAllocator(8 * 1024 * 1024) = .{};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    // Need at least one byte for the selector bitfield.
    if (len == 0) return;

    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];

    // Use the first byte as a selector bitfield for parser options and terminator.
    const selector = input[0];
    const payload = input[1..];

    var p = osc.Parser.init(alloc);
    defer p.deinit();

    // Bits 2..3 of selector configure unknown OSC capture limits:
    //   0 -> disabled (default, preserves existing corpus behavior for 0..2)
    //   1 -> fixed buffer limit
    //   2 -> allocating buffer limit
    //   3 -> tiny limit (truncation edge cases)
    p.unknown_max_bytes = switch ((selector >> 2) & 0b11) {
        0 => 0,
        1 => osc.Parser.MAX_BUF,
        2 => osc.Parser.MAX_BUF + 64,
        3 => 8,
        else => unreachable,
    };

    // Bit 4 toggles bulk nextSlice vs byte-at-a-time next
    if (selector & 0b10000 != 0) {
        p.nextSlice(payload);
    } else {
        for (payload) |byte| p.next(byte);
    }

    // Bits 0..1 of selector choose the terminator variant:
    //   0    -> BEL (0x07)
    //   1    -> ST  (0x9c)
    //   2, 3 -> missing terminator (null)
    const terminator: ?u8 = switch (selector & 0b11) {
        0 => 0x07,
        1 => 0x9c,
        else => null,
    };

    // If the parser successfully produced an OSC command, exercise any lazy
    // or post-processing code paths (OSC 133, OSC 3008, OSC 7501).
    //
    // Most commands are parsed eagerly, but hierarchical context (OSC 3008) parses
    // metadata fields on-demand via `readOption()`.
    // Actively querying every possible field ensures the fuzzer
    // covers option extraction, numeric/enum parsing, and escape sequence
    // de-escaping (\x3b, \x5c) across both iterator and allocation paths.
    //
    if (p.end(terminator)) |cmd| {
        switch (cmd.*) {
            .semantic_prompt => |sp| {
                const SP = osc.semantic_prompt;

                inline for (std.enums.values(SP.Option)) |opt| {
                    std.mem.doNotOptimizeAway(sp.readOption(opt));
                }

                var decode_buf: [osc.Parser.MAX_BUF]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&decode_buf);
                sp.writeCommandLine(&writer) catch {};
                std.mem.doNotOptimizeAway(writer.buffered());
            },
            .hierarchical_context => |ctx| {
                const HC = osc.hierarchical_context;

                inline for (std.enums.values(HC.Field)) |field| {
                    if (ctx.readOption(field)) |val| {
                        switch (@TypeOf(val)) {
                            HC.UnescapedString => {
                                var it = val.iterator();
                                while (it.next()) |c| {
                                    std.mem.doNotOptimizeAway(c);
                                }
                                _ = val.toAllocated(alloc) catch {};
                            },
                            else => {
                                std.mem.doNotOptimizeAway(val);
                            },
                        }
                    }
                }
            },
            .program_status => |ps| {
                switch (ps) {
                    .query => |q| std.mem.doNotOptimizeAway(q),
                    .report => |r| {
                        const PS = osc.program_status;

                        inline for (std.enums.values(PS.Option)) |field| {
                            std.mem.doNotOptimizeAway(r.readOption(field));
                        }

                        var text_buf: [PS.max_msg_bytes]u8 = undefined;
                        var writer: std.Io.Writer = .fixed(&text_buf);
                        r.writeText(.title, &writer) catch {};
                        writer.end = 0;
                        r.writeText(.msg, &writer) catch {};
                        std.mem.doNotOptimizeAway(writer.buffered());
                    },
                }
            },
            else => |v| std.mem.doNotOptimizeAway(v),
        }
    }
}
