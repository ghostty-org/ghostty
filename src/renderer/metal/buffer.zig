const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const objc = @import("objc");
const macos = @import("macos");

const mtl = @import("api.zig");

const log = std.log.scoped(.metal);

/// Metal data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with Metal.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The resource options for this buffer.
        options: mtl.MTLResourceOptions,

        buffer: objc.Object, // MTLBuffer

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(
            device: objc.Object,
            len: usize,
            options: mtl.MTLResourceOptions,
        ) !Self {
            const buffer = device.msgSend(
                objc.Object,
                objc.sel("newBufferWithLength:options:"),
                .{
                    @as(c_ulong, @intCast(len * @sizeOf(T))),
                    options,
                },
            );

            return .{ .buffer = buffer, .options = options };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(
            device: objc.Object,
            data: []const T,
            options: mtl.MTLResourceOptions,
        ) !Self {
            const buffer = device.msgSend(
                objc.Object,
                objc.sel("newBufferWithBytes:length:options:"),
                .{
                    @as(*const anyopaque, @ptrCast(data.ptr)),
                    @as(c_ulong, @intCast(data.len * @sizeOf(T))),
                    options,
                },
            );

            return .{ .buffer = buffer, .options = options };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.msgSend(void, objc.sel("release"), .{});
        }

        /// Get the buffer contents as a slice of T. The contents are
        /// mutable. The contents may or may not be automatically synced
        /// depending on the buffer storage mode. See the Metal docs.
        pub fn contents(self: *Self) ![]T {
            const len_bytes = self.buffer.getProperty(c_ulong, "length");
            assert(@mod(len_bytes, @sizeOf(T)) == 0);
            const len = @divExact(len_bytes, @sizeOf(T));
            const ptr = self.buffer.msgSend(
                ?[*]T,
                objc.sel("contents"),
                .{},
            ).?;
            return ptr[0..len];
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, device: objc.Object, data: []const T) !void {
            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = data.len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                const size = req_bytes * 2;
                self.buffer = device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(size * @sizeOf(T))),
                        self.options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            const src = src: {
                const ptr = @as([*]const u8, @ptrCast(data.ptr));
                break :src ptr[0..req_bytes];
            };

            @memcpy(dst, src);

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, device: objc.Object, lists: []std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more bytes than our buffer has, we need to reallocate.
            const req_bytes = total_len * @sizeOf(T);
            const avail_bytes = self.buffer.getProperty(c_ulong, "length");
            if (req_bytes > avail_bytes) {
                // Deallocate previous buffer
                self.buffer.msgSend(void, objc.sel("release"), .{});

                // Allocate a new buffer with enough to hold double what we require.
                const size = req_bytes * 2;
                self.buffer = device.msgSend(
                    objc.Object,
                    objc.sel("newBufferWithLength:options:"),
                    .{
                        @as(c_ulong, @intCast(size * @sizeOf(T))),
                        self.options,
                    },
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            const dst = dst: {
                const ptr = self.buffer.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
                    log.warn("buffer contents ptr is null", .{});
                    return error.MetalFailed;
                };

                break :dst ptr[0..req_bytes];
            };

            var i: usize = 0;

            for (lists) |list| {
                const ptr = @as([*]const u8, @ptrCast(list.items.ptr));
                @memcpy(dst[i..][0 .. list.items.len * @sizeOf(T)], ptr);
                i += list.items.len * @sizeOf(T);
            }

            // If we're using the managed resource storage mode, then
            // we need to signal Metal to synchronize the buffer data.
            //
            // Ref: https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos?language=objc
            if (self.options.storage_mode == .managed) {
                self.buffer.msgSend(
                    void,
                    "didModifyRange:",
                    .{macos.foundation.Range.init(0, req_bytes)},
                );
            }

            return total_len;
        }
    };
}
