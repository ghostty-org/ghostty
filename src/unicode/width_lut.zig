const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The number of low codepoint bits that select an entry within a block.
pub const block_bits = 8;
const block_size = 1 << block_bits;
const Block = [block_size]u8;

/// Creates a type that generates a two-level lookup table from a codepoint
/// to its width. This is a narrower table than the one in lut.zig: it maps
/// only to the width, so many more blocks are identical and the whole table
/// is a fraction of the size. Each entry is one byte, so a lookup is two
/// dependent loads with no shifting or masking of the entry.
///
/// The layout (a byte per entry and 256-codepoint blocks) was chosen by
/// deriving the smallest two-level table from Ghostty's own widths and
/// timing it against the three-stage lookup in lut.zig.
///
/// Context must have one function:
///   - `get(Context, u21) u2`: returns the width for a given codepoint
///
pub fn Generator(comptime Context: type) type {
    return struct {
        const Self = @This();

        const BlockMap = std.HashMap(
            Block,
            u16,
            struct {
                pub fn hash(ctx: @This(), k: Block) u64 {
                    _ = ctx;
                    return std.hash.Wyhash.hash(0, &k);
                }

                pub fn eql(ctx: @This(), a: Block, b: Block) bool {
                    _ = ctx;
                    return std.mem.eql(u8, &a, &b);
                }
            },
            std.hash_map.default_max_load_percentage,
        );

        ctx: Context = undefined,

        /// Generate the lookup tables. The arrays in the return value
        /// are owned by the caller and must be freed.
        pub fn generate(self: *const Self, alloc: Allocator) !Tables {
            var blocks_map = BlockMap.init(alloc);
            defer blocks_map.deinit();

            var index: std.ArrayList(u16) = .empty;
            var leaf: std.ArrayList(u8) = .empty;
            defer {
                index.deinit(alloc);
                leaf.deinit(alloc);
            }

            const blocks = (std.math.maxInt(u21) + 1) / block_size;
            for (0..blocks) |i| {
                var block: Block = undefined;
                for (&block, 0..) |*entry, j| {
                    entry.* = try self.ctx.get(@intCast(i * block_size + j));
                }

                const gop = try blocks_map.getOrPut(block);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.math.cast(
                        u16,
                        blocks_map.count() - 1,
                    ) orelse return error.TooManyBlocks;
                    try leaf.appendSlice(alloc, &block);
                }
                try index.append(alloc, gop.value_ptr.*);
            }

            const index_owned = try index.toOwnedSlice(alloc);
            errdefer alloc.free(index_owned);
            const leaf_owned = try leaf.toOwnedSlice(alloc);
            errdefer alloc.free(leaf_owned);

            return .{
                .index = index_owned,
                .leaf = leaf_owned,
            };
        }
    };
}

/// The generated width tables. `index` maps the high bits of a codepoint to
/// a block of `leaf`; the low `block_bits` bits select the width in the block.
pub const Tables = struct {
    index: []const u16,
    leaf: []const u8,

    pub inline fn get(self: *const Tables, cp: u21) u2 {
        const block: u32 = self.index[cp >> block_bits];
        return @intCast(self.leaf[(block << block_bits) | (cp & (block_size - 1))]);
    }

    /// Writes the tables as Zig to the given writer: the constants
    /// width_index and width_leaf. The index is written as u8 entries when
    /// there are few enough distinct blocks, which halves its size.
    pub fn writeZig(self: *const Tables, writer: *std.Io.Writer) !void {
        const blocks = self.leaf.len / block_size;
        const index_type = if (blocks <= std.math.maxInt(u8) + 1) "u8" else "u16";
        try writer.print(
            \\
            \\pub const width_index: [{}]{s} align(64) = .{{
        , .{ self.index.len, index_type });
        for (self.index) |entry| try writer.print("{},", .{entry});
        try writer.print(
            \\}};
            \\
            \\pub const width_leaf: [{}]u8 align(64) = .{{
        , .{self.leaf.len});
        for (self.leaf) |entry| try writer.print("{},", .{entry});
        try writer.writeAll(
            \\};
            \\
        );
    }
};

test "width lut: round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const gen: Generator(struct {
        pub fn get(ctx: @This(), cp: u21) !u2 {
            _ = ctx;
            return @intCast(cp % 3);
        }
    }) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.index);
    defer alloc.free(t.leaf);

    // Every block is the same pattern only when block_size is a multiple
    // of 3, which it is not, so there are three distinct blocks.
    try testing.expectEqual(@as(usize, 3 * block_size), t.leaf.len);
    for (0..std.math.maxInt(u21) + 1) |cp| {
        try testing.expectEqual(@as(u2, @intCast(cp % 3)), t.get(@intCast(cp)));
    }
}
