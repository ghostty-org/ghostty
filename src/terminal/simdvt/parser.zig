const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const ScalarStream = terminal.Stream;
const simd = @import("../../simd/main.zig");
const aarch64 = simd.aarch64;

pub fn Stream(comptime Handler: type) type {
    return struct {
        const Self = @This();

        handler: Handler,

        pub fn init(h: Handler) Self {
            return .{ .handler = h };
        }

        pub fn feed(self: *Self, input: []const u8) void {
            // TODO: I want to do the UTF-8 decoding as we stream the input,
            // but I don't want to deal with UTF-8 decode in SIMD right now.
            // So for now we just go back over the input and decode using
            // a scalar loop. Ugh.

            // We search for ESC (0x1B) very frequently, since this is what triggers
            // the start of a terminal escape sequence of any kind, so put this into
            // a register immediately.
            const esc_vec = aarch64.vdupq_n_u8(0x1B);

            // Iterate 16 bytes at a time, which is the max size of a vector register.
            var i: usize = 0;
            while (i + 16 <= input.len) : (i += 16) {
                // Load the next 16 bytes into a vector register.
                const input_vec = aarch64.vld1q_u8(input[i..]);

                // Check for ESC to determine if we should go to the next state.
                if (simd.index_of.Neon.indexOfVec(input_vec, esc_vec)) |index| {
                    _ = index;
                    @panic("TODO");
                }

                // No ESC found, decode UTF-8.
                // TODO(mitchellh): I don't have a UTF-8 decoder in SIMD yet, so
                // for now we just use a scalar loop. This is slow.
                const view = std.unicode.Utf8View.initUnchecked(input[i .. i + 16]);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    self.handler.print(cp);
                }
            }

            // Handle the remaining bytes
            if (i < input.len) {
                @panic("input must be a multiple of 16 bytes for now");
            }
        }
    };
}

test "ascii" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const H = struct {
        const Self = @This();
        alloc: Allocator,
        buf: std.ArrayListUnmanaged(u21) = .{},

        pub fn print(self: *Self, c: u21) void {
            self.buf.append(self.alloc, c) catch unreachable;
        }
    };

    const str = "hello" ** 16;
    var s = Stream(H).init(.{ .alloc = alloc });
    s.feed(str);

    try testing.expectEqual(str.len, s.handler.buf.items.len);
}
