//! Host-coherent `VkBuffer` wrapper, generic over element type.
//!
//! Mirrors `src/renderer/opengl/buffer.zig`: `Buffer(T)` returns a
//! struct that holds one buffer's worth of `T`s, with init / initFill
//! / sync / syncFromArrayLists semantics that match the OpenGL
//! contract.
//!
//! Storage strategy: `HOST_VISIBLE | HOST_COHERENT` memory.
//! - HOST_VISIBLE lets us `vkMapMemory` the buffer and write directly.
//! - HOST_COHERENT means the writes are visible to the GPU without a
//!   `vkFlushMappedMemoryRanges` round-trip.
//! - This is the simplest "dynamic" buffer pattern in Vulkan. It does
//!   pay a small cost over device-local + staging on discrete GPUs,
//!   but the renderer's per-frame buffer payloads are KBs (cell
//!   instances + uniforms), not bandwidth-bound. The OpenGL backend
//!   uses `dynamic_draw` for the same buffers, which behaves
//!   similarly on most drivers.
//!
//! Growth policy: matches the OpenGL backend — `sync` doubles the
//! buffer when content outgrows it, with no shrink. The buffer is
//! recreated (destroy/create) on growth because Vulkan buffers are
//! immutable in size.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// Buffer construction parameters. The OpenGL backend's `target` /
/// `usage` enums don't map to Vulkan — `target` (vertex vs element
/// binding point) is replaced by descriptor binding at draw time, and
/// `usage` (static_draw / dynamic_draw / etc.) is implicit in our
/// host-coherent allocation strategy. What's left is the Vulkan
/// `VkBufferUsageFlags` bitmask, which the renderer's `api.*BufferOptions`
/// methods will return differently per buffer kind (VERTEX_BUFFER_BIT
/// for instance buffers, UNIFORM_BUFFER_BIT for uniforms, etc.).
pub const Options = struct {
    device: *const Device,
    /// `VkBufferUsageFlagBits` for the buffer.
    usage: vk.VkBufferUsageFlags,
};

pub const Error = error{
    /// A `vkCreate*` / `vkAllocateMemory` / `vkBindBufferMemory` /
    /// `vkMapMemory` returned a non-success status.
    VulkanFailed,
    /// `Device.findMemoryType` couldn't find a `HOST_VISIBLE | HOST_COHERENT`
    /// memory type matching the buffer's requirements. Unlikely on any
    /// real driver but worth flagging distinctly.
    NoSuitableMemoryType,
};

/// `Buffer(T)`: a `VkBuffer` + backing `VkDeviceMemory` typed to hold
/// some number of `T`s. Mirrors `opengl/buffer.zig`'s `Buffer(T)` so
/// the renderer's call sites don't need a per-backend branch.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `VkBuffer` handle.
        buffer: vk.VkBuffer,
        /// Backing memory. Host-coherent; mappable directly.
        memory: vk.VkDeviceMemory,
        /// Options this buffer was allocated with.
        opts: Options,
        /// Current capacity, in number of `T`s.
        len: usize,

        /// Initialize a buffer with capacity for `len` `T`s. Contents
        /// are uninitialized; call `sync` to populate.
        pub fn init(opts: Options, len: usize) Error!Self {
            return try create(opts, len);
        }

        /// Initialize a buffer pre-filled with the provided data.
        pub fn initFill(opts: Options, data: []const T) Error!Self {
            var self = try create(opts, data.len);
            errdefer self.deinit();
            try self.write(0, data);
            return self;
        }

        pub fn deinit(self: Self) void {
            const dev = self.opts.device;
            // Queue for destruction after the next frame's fence
            // signals. `renderer/image.zig` creates a temp Buffer
            // per kitty-image draw with `defer buf.deinit()` — that
            // pattern is fine on OpenGL (GL defers deletion of
            // in-flight buffers itself) but use-after-free on
            // Vulkan, where the command buffer recorded against
            // `self.buffer` hasn't been submitted yet at the point
            // of deinit. The deferred queue keeps the VkBuffer +
            // VkDeviceMemory alive until `Frame.complete` waits the
            // fence; only then is destruction safe.
            const deferred = @import("../Vulkan.zig").deferred_destruction;
            deferred.queueBuffer(dev, self.buffer, self.memory) catch {
                // OOM growing the queue — fall back to immediate
                // destroy. Probably crashes the GPU; logging from
                // here is awkward (no logger in scope) so we accept
                // the leak / crash and let stderr from Vulkan
                // diagnose.
                dev.dispatch.destroyBuffer(dev.device, self.buffer, null);
                dev.dispatch.freeMemory(dev.device, self.memory, null);
            };
        }

        /// Replace the buffer's contents. Grows (doubles) if needed —
        /// matches the OpenGL backend's behavior. Data shorter than
        /// the current capacity leaves the trailing slots untouched.
        pub fn sync(self: *Self, data: []const T) Error!void {
            if (data.len > self.len) try self.grow(data.len * 2);
            try self.write(0, data);
        }

        /// Like `sync` but pulls from multiple `ArrayList`s in
        /// sequence; returns the total number of elements written.
        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) Error!usize {
            var total: usize = 0;
            for (lists) |list| total += list.items.len;

            if (total > self.len) try self.grow(total * 2);

            var off: usize = 0;
            for (lists) |list| {
                if (list.items.len == 0) continue;
                try self.write(off, list.items);
                off += list.items.len;
            }
            return total;
        }

        // ---- internals -------------------------------------------

        fn create(opts: Options, len: usize) Error!Self {
            const dev = opts.device;
            // Vulkan requires `size > 0` for buffer creation. Round up
            // a zero request to 1 so the buffer exists and can be
            // grown later via `sync`. (OpenGL silently accepts size=0.)
            const byte_size: u64 = @max(1, len * @sizeOf(T));

            const info: vk.VkBufferCreateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .size = byte_size,
                .usage = opts.usage,
                .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
                .queueFamilyIndexCount = 0,
                .pQueueFamilyIndices = null,
            };
            var buffer: vk.VkBuffer = undefined;
            {
                const r = dev.dispatch.createBuffer(dev.device, &info, null, &buffer);
                if (r != vk.VK_SUCCESS) {
                    log.err("vkCreateBuffer failed: result={}", .{r});
                    return error.VulkanFailed;
                }
            }
            errdefer dev.dispatch.destroyBuffer(dev.device, buffer, null);

            var reqs: vk.VkMemoryRequirements = undefined;
            dev.dispatch.getBufferMemoryRequirements(dev.device, buffer, &reqs);

            const type_index = dev.findMemoryType(
                reqs.memoryTypeBits,
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                    vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ) orelse {
                log.err(
                    "no HOST_VISIBLE|HOST_COHERENT memory type for buffer (typeBits=0x{x})",
                    .{reqs.memoryTypeBits},
                );
                return error.NoSuitableMemoryType;
            };

            const alloc_info: vk.VkMemoryAllocateInfo = .{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .pNext = null,
                .allocationSize = reqs.size,
                .memoryTypeIndex = type_index,
            };
            var memory: vk.VkDeviceMemory = undefined;
            {
                const r = dev.dispatch.allocateMemory(dev.device, &alloc_info, null, &memory);
                if (r != vk.VK_SUCCESS) {
                    log.err("vkAllocateMemory (buffer) failed: result={}", .{r});
                    return error.VulkanFailed;
                }
            }
            errdefer dev.dispatch.freeMemory(dev.device, memory, null);

            {
                const r = dev.dispatch.bindBufferMemory(dev.device, buffer, memory, 0);
                if (r != vk.VK_SUCCESS) {
                    log.err("vkBindBufferMemory failed: result={}", .{r});
                    return error.VulkanFailed;
                }
            }

            return .{
                .buffer = buffer,
                .memory = memory,
                .opts = opts,
                .len = len,
            };
        }

        /// Grow the buffer to hold at least `new_len` Ts. Destroys
        /// and recreates the underlying VkBuffer (Vulkan buffers are
        /// immutable in size). Contents are discarded — callers
        /// always `sync` immediately after `grow` returns.
        fn grow(self: *Self, new_len: usize) Error!void {
            const dev = self.opts.device;
            dev.dispatch.destroyBuffer(dev.device, self.buffer, null);
            dev.dispatch.freeMemory(dev.device, self.memory, null);
            const replacement = try create(self.opts, new_len);
            self.* = replacement;
        }

        /// Copy `data` into the buffer starting at element offset
        /// `elem_off`. Host-coherent memory means the GPU sees the
        /// writes without an explicit flush.
        fn write(self: *const Self, elem_off: usize, data: []const T) Error!void {
            if (data.len == 0) return;
            const dev = self.opts.device;
            const byte_off: u64 = elem_off * @sizeOf(T);
            const byte_size: u64 = data.len * @sizeOf(T);
            var mapped: ?*anyopaque = null;
            {
                const r = dev.dispatch.mapMemory(
                    dev.device,
                    self.memory,
                    byte_off,
                    byte_size,
                    0,
                    &mapped,
                );
                if (r != vk.VK_SUCCESS) {
                    log.err("vkMapMemory failed: result={}", .{r});
                    return error.VulkanFailed;
                }
            }
            defer dev.dispatch.unmapMemory(dev.device, self.memory);

            const dst: [*]u8 = @ptrCast(mapped.?);
            const src: [*]const u8 = @ptrCast(data.ptr);
            @memcpy(dst[0..byte_size], src[0..byte_size]);
        }
    };
}

test {
    // Exercise top-level decls of a representative instantiation so
    // type errors in the generic body surface during compile-check.
    std.testing.refAllDecls(Buffer(u32));
}
