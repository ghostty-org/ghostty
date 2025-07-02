//! Implements a texture atlas (https://en.wikipedia.org/wiki/Texture_atlas).
//!
//! The implementation is based on "A Thousand Ways to Pack the Bin - A
//! Practical Approach to Two-Dimensional Rectangle Bin Packing" by Jukka
//! Jylänki. This specific implementation is based heavily on
//! Nicolas P. Rougier's freetype-gl project as well as Jukka's C++
//! implementation: https://github.com/juj/RectangleBinPack
//!
//! Limitations that are easy to fix, but I didn't need them:
//!
//!   * Written data must be packed, no support for custom strides.
//!   * Texture is always a square, no ability to set width != height. Note
//!     that regions written INTO the atlas do not have to be square, only
//!     the full atlas texture itself.
//!
const Atlas = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const fastmem = @import("../fastmem.zig");

const log = std.log.scoped(.atlas);

/// Data is the raw texture data.
data: []u8,

/// Width and height of the atlas texture. The current implementation is
/// always square so this is both the width and the height.
size: u32 = 0,

/// The nodes (rectangles) of available space.
nodes: std.ArrayListUnmanaged(Node) = .{},

/// The format of the texture data being written into the Atlas. This must be
/// uniform for all textures in the Atlas. If you have some textures with
/// different formats, you must use multiple atlases or convert the textures.
format: Format = .grayscale,

/// This will be incremented every time the atlas is modified. This is useful
/// for knowing if the texture data has changed since the last time it was
/// sent to the GPU. It is up the user of the atlas to read this value atomically
/// to observe it.
modified: std.atomic.Value(usize) = .{ .raw = 0 },

/// This will be incremented every time the atlas is resized. This is useful
/// for knowing if a GPU texture can be updated in-place or if it requires
/// a resize operation.
resized: std.atomic.Value(usize) = .{ .raw = 0 },

pub const Format = enum(u8) {
    /// 1 byte per pixel grayscale.
    grayscale = 0,
    /// 3 bytes per pixel BGR.
    bgr = 1,
    /// 4 bytes per pixel BGRA.
    bgra = 2,

    pub fn depth(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .bgr => 3,
            .bgra => 4,
        };
    }
};

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Error = error{
    /// Atlas cannot fit the desired region. You must enlarge the atlas.
    AtlasFull,
};

/// A region within the texture atlas. These can be acquired using the
/// "reserve" function. A region reservation is required to write data.
pub const Region = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub fn init(alloc: Allocator, size: u32, format: Format) Allocator.Error!Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size * format.depth()),
        .size = size,
        .nodes = .{},
        .format = format,
    };
    errdefer result.deinit(alloc);

    // TODO: figure out optimal prealloc based on real world usage
    try result.nodes.ensureUnusedCapacity(alloc, 64);

    // This sets up our initial state
    result.clear();

    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}

/// Reserve a region within the atlas with the given width and height.
///
/// May allocate to add a new rectangle into the internal list of rectangles.
/// This will not automatically enlarge the texture if it is full.
pub fn reserve(
    self: *Atlas,
    alloc: Allocator,
    width: u32,
    height: u32,
) (Allocator.Error || Error)!Region {
    // x, y are populated within :best_idx below
    var region: Region = .{ .x = 0, .y = 0, .width = width, .height = height };

    // If our width/height are 0, then we return the region as-is. This
    // may seem like an error case but it simplifies downstream callers who
    // might be trying to write empty data.
    if (width == 0 and height == 0) return region;

    // Find the location in our nodes list to insert the new node for this region.
    const best_idx: usize = best_idx: {
        var best_height: u32 = std.math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;

        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            // Check if our region fits within this node.
            const y = self.fit(i, width, height) orelse continue;

            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                    (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }

        // If we never found a chosen index, the atlas cannot fit our region.
        break :best_idx chosen orelse return Error.AtlasFull;
    };

    // Insert our new node for this rectangle at the exact best index
    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });

    // Optimize our rectangles
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }

        break;
    }
    self.merge();

    return region;
}

/// Attempts to fit a rectangle of width x height into the node at idx.
/// The return value is the y within the texture where the rectangle can be
/// placed. The x is the same as the node.
fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    // If the added width exceeds our texture size, it doesn't fit.
    const node = self.nodes.items[idx];
    if ((node.x + width) > (self.size - 1)) return null;

    // Go node by node looking for space that can fit our width.
    var y = node.y;
    var i = idx;
    var width_left = width;
    while (width_left > 0) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;

        // If the added height exceeds our texture size, it doesn't fit.
        if ((y + height) > (self.size - 1)) return null;

        width_left -|= n.width;
    }

    return y;
}

/// Merge adjacent nodes with the same y value.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }

        i += 1;
    }
}

/// Set the data associated with a reserved region. The data is expected
/// to fit exactly within the region. The data must be formatted with the
/// proper bpp configured on init.
pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const data_offset = i * reg.width * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            data[data_offset .. data_offset + (reg.width * depth)],
        );
    }

    _ = self.modified.fetchAdd(1, .monotonic);
}

/// Like `set` but allows specifying a width for the source data and an
/// offset x and y, so that a section of a larger buffer may be copied
/// in to the atlas.
pub fn setFromLarger(
    self: *Atlas,
    reg: Region,
    src: []const u8,
    src_width: u32,
    src_x: u32,
    src_y: u32,
) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const src_offset = (((src_y + i) * src_width) + src_x) * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            src[src_offset .. src_offset + (reg.width * depth)],
        );
    }

    _ = self.modified.fetchAdd(1, .monotonic);
}

// Grow the texture to the new size, preserving all previously written data.
pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    assert(size_new >= self.size);
    if (size_new == self.size) return;

    // Preserve our old values so we can copy the old data
    const data_old = self.data;
    const size_old = self.size;

    // Allocate our new data
    self.data = try alloc.alloc(u8, size_new * size_new * self.format.depth());
    defer alloc.free(data_old);
    errdefer {
        alloc.free(self.data);
        self.data = data_old;
    }

    // Add our new rectangle for our added righthand space. We do this
    // right away since its the only operation that can fail and we want
    // to make error cleanup easier.
    try self.nodes.append(alloc, .{
        .x = size_old - 1,
        .y = 1,
        .width = size_new - size_old,
    });

    // If our allocation and rectangle add succeeded, we can go ahead
    // and persist our new size and copy over the old data.
    self.size = size_new;
    @memset(self.data, 0);
    self.set(.{
        .x = 0, // don't bother skipping border so we can avoid strides
        .y = 1, // skip the first border row
        .width = size_old,
        .height = size_old - 2, // skip the last border row
    }, data_old[size_old * self.format.depth() ..]);

    // We are both modified and resized
    _ = self.modified.fetchAdd(1, .monotonic);
    _ = self.resized.fetchAdd(1, .monotonic);
}

// Empty the atlas. This doesn't reclaim any previously allocated memory.
pub fn clear(self: *Atlas) void {
    _ = self.modified.fetchAdd(1, .monotonic);
    @memset(self.data, 0);
    self.nodes.clearRetainingCapacity();

    // Add our initial rectangle. This is the size of the full texture
    // and is the initial rectangle we fit our regions in. We keep a 1px border
    // to avoid artifacting when sampling the texture.
    self.nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .width = self.size - 2 });
}

/// Dump the atlas as a PPM to a writer, for debug purposes.
/// Only supports grayscale and bgr atlases.
///
/// NOTE: BGR atlases will have the red and blue channels
///       swapped because PPM expects RGB. This would be
///       easy enough to fix so next time someone needs
///       to debug a color atlas they should fix it.
pub fn dump(self: Atlas, writer: anytype) !void {
    try writer.print(
        \\P{c}
        \\{d} {d}
        \\255
        \\
    , .{
        @as(u8, switch (self.format) {
            .grayscale => '5',
            .bgr => '6',
            else => {
                log.err("Unsupported format for dump: {}", .{self.format});
                @panic("Cannot dump this atlas format.");
            },
        }),
        self.size,
        self.size,
    });
    try writer.writeAll(self.data);
}

/// The wasm-compatible API. This lacks documentation unless the API differs
/// from the standard Zig API. To learn what a function does, just look one
/// level deeper to what Zig function is called and read the documentation there.
pub const Wasm = struct {
    // If you're copying this file (Atlas.zig) out to a separate project,
    // just replace this with the allocator you want to use.
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;
    const js = @import("zig-js");

    export fn atlas_new(size: u32, format: u8) ?*Atlas {
        const atlas = init(
            alloc,
            size,
            @enumFromInt(format),
        ) catch return null;
        const result = alloc.create(Atlas) catch return null;
        result.* = atlas;
        return result;
    }

    export fn atlas_free(ptr: ?*Atlas) void {
        if (ptr) |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        }
    }

    /// The return value for this should be freed by the caller with "free".
    export fn atlas_reserve(self: *Atlas, width: u32, height: u32) ?*Region {
        return atlas_reserve_(self, width, height) catch return null;
    }

    fn atlas_reserve_(self: *Atlas, width: u32, height: u32) !*Region {
        const reg = try self.reserve(alloc, width, height);
        const result = try alloc.create(Region);
        errdefer alloc.destroy(result);
        _ = try wasm.toHostOwned(result);
        result.* = reg;
        return result;
    }

    export fn atlas_set(self: *Atlas, reg: *Region, data: [*]const u8, len: usize) void {
        self.set(reg.*, data[0..len]);
    }

    export fn atlas_grow(self: *Atlas, size_new: u32) bool {
        self.grow(alloc, size_new) catch return false;
        return true;
    }

    export fn atlas_clear(self: *Atlas) void {
        self.clear();
    }

    /// This creates a Canvas element identified by the id returned that
    /// the caller can draw into the DOM to visualize the atlas. The returned
    /// ID must be freed from the JS runtime by calling "zigjs.deleteValue".
    export fn atlas_debug_canvas(self: *Atlas) u32 {
        return atlas_debug_canvas_(self) catch |err| {
            log.warn("error dumping atlas canvas err={}", .{err});
            return 0;
        };
    }

    fn atlas_debug_canvas_(self: *Atlas) !u32 {
        // Create our canvas
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();

        // Setup our canvas size
        {
            try canvas.set("width", self.size);
            try canvas.set("height", self.size);

            const width_str = try std.fmt.allocPrint(alloc, "{d}px", .{self.size});
            defer alloc.free(width_str);

            const style = try canvas.get(js.Object, "style");
            defer style.deinit();
            try style.set("width", js.string(width_str));
            try style.set("height", js.string(width_str));
        }

        // This will return the same context on subsequent calls so it
        // is important to reset it.
        const ctx = try canvas.call(js.Object, "getContext", .{js.string("2d")});
        defer ctx.deinit();

        // We need to draw pixels so this is format dependent.
        const buf: []u8 = switch (self.format) {
            .bgra => buf: {
                // Convert from BGRA to RGBA by swapping every R and B.
                var buf: []u8 = try alloc.dupe(u8, self.data);
                errdefer alloc.free(buf);
                var i: usize = 0;
                while (i < self.data.len) : (i += 4) {
                    std.mem.swap(u8, &buf[i], &buf[i + 2]);
                }
                break :buf buf;
            },

            .grayscale => buf: {
                // Convert from A8 to RGBA so every 4th byte is set to a value.
                var buf: []u8 = try alloc.alloc(u8, self.data.len * 4);
                errdefer alloc.free(buf);
                @memset(buf, 0);
                for (self.data, 0..) |value, i| {
                    buf[(i * 4) + 3] = value;
                }
                break :buf buf;
            },

            else => return error.UnsupportedAtlasFormat,
        };
        defer if (buf.ptr != self.data.ptr) alloc.free(buf);

        // Create an ImageData from our buffer and then write it to the canvas
        const image_data: js.Object = data: {
            // Get our runtime memory
            const mem = try js.runtime.get(js.Object, "memory");
            defer mem.deinit();
            const mem_buf = try mem.get(js.Object, "buffer");
            defer mem_buf.deinit();

            // Create an array that points to our buffer
            const arr = arr: {
                const Uint8ClampedArray = try js.global.get(js.Object, "Uint8ClampedArray");
                defer Uint8ClampedArray.deinit();
                const arr = try Uint8ClampedArray.new(.{ mem_buf, buf.ptr, buf.len });
                if (!wasm.shared_mem) break :arr arr;

                // If we're sharing memory then we have to copy the data since
                // we can't set ImageData directly using a SharedArrayBuffer.
                defer arr.deinit();
                break :arr try arr.call(js.Object, "slice", .{});
            };
            defer arr.deinit();

            // Create the image data from our array
            const ImageData = try js.global.get(js.Object, "ImageData");
            defer ImageData.deinit();
            const data = try ImageData.new(.{ arr, self.size, self.size });
            errdefer data.deinit();

            break :data data;
        };
        defer image_data.deinit();

        // Draw it
        try ctx.call(void, "putImageData", .{ image_data, 0, 0 });

        const id = @as(js.Ref, @bitCast(@intFromEnum(canvas.value))).id;
        return id;
    }

    test "happy path" {
        const atlas = atlas_new(512, @intFromEnum(Format.grayscale)).?;
        defer atlas_free(atlas);

        const reg = atlas_reserve(atlas, 2, 2).?;
        defer alloc.destroy(reg);
        try testing.expect(wasm.isHostOwned(reg));
        defer wasm.toModuleOwned(reg);
        try testing.expect(reg.width > 0);

        const data = &[_]u8{ 1, 2, 3, 4 };
        try testing.expect(!atlas.modified);
        atlas_set(atlas, reg, data, data.len);
        try testing.expect(atlas.modified);
    }
};

test "exact fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 34, .grayscale); // +2 for 1px border
    defer atlas.deinit(alloc);

    const modified = atlas.modified.load(.monotonic);
    _ = try atlas.reserve(alloc, 32, 32);
    try testing.expectEqual(modified, atlas.modified.load(.monotonic));
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "doesnt fit" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);

    // doesn't fit due to border
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 32, 32));
}

test "fit multiple" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);

    _ = try atlas.reserve(alloc, 15, 30);
    _ = try atlas.reserve(alloc, 15, 30);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}

test "writing data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    const old = atlas.modified.load(.monotonic);
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    const new = atlas.modified.load(.monotonic);
    try testing.expect(new > old);

    // 33 because of the 1px border and so on
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);
}

test "writing data from a larger source" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .grayscale);
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    const old = atlas.modified.load(.monotonic);
    // zig fmt: off
    atlas.setFromLarger(reg, &[_]u8{
        8, 8, 8, 8, 8,
        8, 8, 1, 2, 8,
        8, 8, 3, 4, 8,
        8, 8, 8, 8, 8,
    }, 5, 2, 1);
    // zig fmt: on
    const new = atlas.modified.load(.monotonic);
    try testing.expect(new > old);

    // 33 because of the 1px border and so on
    try testing.expectEqual(@as(u8, 1), atlas.data[33]);
    try testing.expectEqual(@as(u8, 2), atlas.data[34]);
    try testing.expectEqual(@as(u8, 3), atlas.data[65]);
    try testing.expectEqual(@as(u8, 4), atlas.data[66]);

    // None of the `8`s from the source data outside of the
    // specified region should have made it on to the atlas.
    try testing.expectEqual(null, std.mem.indexOfScalar(u8, atlas.data, 8));
}

test "grow" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 4, .grayscale); // +2 for 1px border
    defer atlas.deinit(alloc);

    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    // Write some data so we can verify that growing doesn't mess it up
    atlas.set(reg, &[_]u8{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(u8, 1), atlas.data[5]);
    try testing.expectEqual(@as(u8, 2), atlas.data[6]);
    try testing.expectEqual(@as(u8, 3), atlas.data[9]);
    try testing.expectEqual(@as(u8, 4), atlas.data[10]);

    // Expand by exactly 1 should fit our new 1x1 block.
    const old_modified = atlas.modified.load(.monotonic);
    const old_resized = atlas.resized.load(.monotonic);
    try atlas.grow(alloc, atlas.size + 1);
    const new_modified = atlas.modified.load(.monotonic);
    const new_resized = atlas.resized.load(.monotonic);
    try testing.expect(new_modified > old_modified);
    try testing.expect(new_resized > old_resized);
    _ = try atlas.reserve(alloc, 1, 1);

    // Ensure our data is still set. Not the offsets change due to size.
    try testing.expectEqual(@as(u8, 1), atlas.data[atlas.size + 1]);
    try testing.expectEqual(@as(u8, 2), atlas.data[atlas.size + 2]);
    try testing.expectEqual(@as(u8, 3), atlas.data[atlas.size * 2 + 1]);
    try testing.expectEqual(@as(u8, 4), atlas.data[atlas.size * 2 + 2]);
}

test "writing BGR data" {
    const alloc = testing.allocator;
    var atlas = try init(alloc, 32, .bgr);
    defer atlas.deinit(alloc);

    // This is BGR so its 3 bpp
    const reg = try atlas.reserve(alloc, 1, 2);
    atlas.set(reg, &[_]u8{
        1, 2, 3,
        4, 5, 6,
    });

    // 33 because of the 1px border and so on
    const depth = @as(usize, @intCast(atlas.format.depth()));
    try testing.expectEqual(@as(u8, 1), atlas.data[33 * depth]);
    try testing.expectEqual(@as(u8, 2), atlas.data[33 * depth + 1]);
    try testing.expectEqual(@as(u8, 3), atlas.data[33 * depth + 2]);
    try testing.expectEqual(@as(u8, 4), atlas.data[65 * depth]);
    try testing.expectEqual(@as(u8, 5), atlas.data[65 * depth + 1]);
    try testing.expectEqual(@as(u8, 6), atlas.data[65 * depth + 2]);
}

test "grow BGR" {
    const alloc = testing.allocator;

    // Atlas is 4x4 so its a 1px border meaning we only have 2x2 available
    var atlas = try init(alloc, 4, .bgr);
    defer atlas.deinit(alloc);

    // Get our 2x2, which should be ALL our usable space
    const reg = try atlas.reserve(alloc, 2, 2);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));

    // This is BGR so its 3 bpp
    atlas.set(reg, &[_]u8{
        10, 11, 12, // (0, 0) (x, y) from top-left
        13, 14, 15, // (1, 0)
        20, 21, 22, // (0, 1)
        23, 24, 25, // (1, 1)
    });

    // Our top left skips the first row (size * depth) and the first
    // column (depth) for the 1px border.
    const depth = @as(usize, @intCast(atlas.format.depth()));
    var tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    tl += (atlas.size * depth); // next row
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    // Expand by exactly 1 should fit our new 1x1 block.
    try atlas.grow(alloc, atlas.size + 1);

    // Data should be in same place accounting for the new size
    tl = (atlas.size * depth) + depth;
    try testing.expectEqual(@as(u8, 10), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 11), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 12), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 13), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 14), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 15), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    tl += (atlas.size * depth); // next row
    try testing.expectEqual(@as(u8, 20), atlas.data[tl]);
    try testing.expectEqual(@as(u8, 21), atlas.data[tl + 1]);
    try testing.expectEqual(@as(u8, 22), atlas.data[tl + 2]);
    try testing.expectEqual(@as(u8, 23), atlas.data[tl + 3]);
    try testing.expectEqual(@as(u8, 24), atlas.data[tl + 4]);
    try testing.expectEqual(@as(u8, 25), atlas.data[tl + 5]);
    try testing.expectEqual(@as(u8, 0), atlas.data[tl + 6]); // border

    // Should fit the new blocks around the edges
    _ = try atlas.reserve(alloc, 1, 3);
    _ = try atlas.reserve(alloc, 2, 1);
    try testing.expectError(Error.AtlasFull, atlas.reserve(alloc, 1, 1));
}
