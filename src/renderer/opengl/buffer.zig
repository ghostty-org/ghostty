const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a buffer.
pub const Options = struct {
    target: gl.Buffer.Target = .array,
    usage: gl.Buffer.Usage = .dynamic_draw,
};

/// OpenGL data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with OpenGL.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `gl.Buffer` instance.
        buffer: gl.Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setDataNullManual(len * @sizeOf(T), opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setData(data, opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = data.len * @sizeOf(T),
            };
        }

        pub fn deinit(self: Self) void {
            self.buffer.destroy();
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            // If we need more space than our buffer has, we need to reallocate.
            if (data.len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = data.len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            try binding.setSubData(0, data);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more space than our buffer has, we need to reallocate.
            if (total_len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = total_len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            var i: usize = 0;

            for (lists) |list| {
                try binding.setSubData(i, list.items);
                i += list.items.len * @sizeOf(T);
            }

            return total_len;
        }
    };
}
