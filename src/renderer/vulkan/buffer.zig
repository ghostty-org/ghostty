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
const vulkan = @import("vulkan");
const vk = vulkan.c;

const Device = vulkan.Device;

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

        /// Hand the (VkBuffer, VkDeviceMemory) pair back to the
        /// process-wide pool. The pool (see `Vulkan.buffer_pool`)
        /// holds the entry until the current frame's fence has
        /// signaled (the GPU is done with our recorded references)
        /// and then makes it available to a future `Buffer.create`
        /// call. Returning to the pool solves both:
        ///   - `renderer/image.zig:draw`'s `defer buf.deinit()` no
        ///     longer use-after-frees the in-flight buffer.
        ///   - It avoids the per-frame allocation thrash that
        ///     drove the driver to SIGSEGV on image-heavy frames.
        ///
        /// MUST be called only from the renderer thread (the path
        /// whose fence will eventually retire references to this
        /// buffer in `Frame.complete`). One-shot uploads (atlas
        /// staging buffers, etc.) that already block on
        /// `vkQueueWaitIdle` post-submit must use
        /// `destroyImmediate` instead — they don't share the
        /// renderer thread's fence cycle.
        pub fn deinit(self: Self) void {
            const dev = self.opts.device;
            const bp = @import("../Vulkan.zig").buffer_pool;
            const capacity_bytes: u64 = @as(u64, self.len) * @sizeOf(T);
            bp.release(
                dev,
                self.buffer,
                self.memory,
                self.opts.usage,
                capacity_bytes,
            ) catch |err| {
                // OOM growing the pool. The buffer may still be
                // referenced by an in-flight command buffer, so we
                // wait the entire device idle before destroying —
                // expensive but correct.
                log.warn(
                    "Buffer.deinit: pool release failed ({}); falling " ++
                        "back to vkDeviceWaitIdle + destroy",
                    .{err},
                );
                _ = dev.dispatch.deviceWaitIdle(dev.device);
                dev.dispatch.destroyBuffer(dev.device, self.buffer, null);
                dev.dispatch.freeMemory(dev.device, self.memory, null);
            };
        }

        /// Destroy the buffer immediately, bypassing the recycle
        /// pool. The caller MUST ensure no in-flight command buffer
        /// references this buffer (e.g. by having waited on a fence
        /// or `vkQueueWaitIdle` covering its submission).
        ///
        /// Used by short-lived staging buffers like
        /// `Texture.replaceRegion` whose lifetime is bounded by a
        /// `OneShot.endAndSubmit` that already drains the queue;
        /// stuffing those into the pool from a non-renderer thread
        /// would leak them (the renderer thread's `cycle` runs the
        /// pool, so an upload thread's pushes never get reused).
        pub fn destroyImmediate(self: Self) void {
            const dev = self.opts.device;
            dev.dispatch.destroyBuffer(dev.device, self.buffer, null);
            dev.dispatch.freeMemory(dev.device, self.memory, null);
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

            // Reach into the buffer pool first — a previous frame's
            // released VkBuffer of matching usage+capacity is safe to
            // reuse, no allocator round trip needed. Image-draw
            // frames stabilize at ~hundreds of pool entries per
            // (usage, size) bucket.
            const bp = @import("../Vulkan.zig").buffer_pool;
            if (bp.acquire(opts.usage, byte_size)) |entry| {
                return .{
                    .buffer = entry.buffer,
                    .memory = entry.memory,
                    .opts = opts,
                    .len = @intCast(entry.capacity / @sizeOf(T)),
                };
            }

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

        /// Grow the buffer to hold at least `new_len` Ts. Vulkan
        /// buffers are immutable in size, so we allocate a fresh
        /// one and then route the old one through the recycle pool
        /// (it may still be referenced by the in-flight command
        /// buffer — destroying it directly would race the GPU same
        /// as `deinit` would). Contents are discarded; callers
        /// always `sync` immediately after `grow` returns.
        ///
        /// Order is critical: `create` first, `release` second.
        /// If we released the old buffer first and `create`
        /// failed, `self.{buffer,memory}` would be left dangling
        /// at freed handles, and the caller's eventual
        /// `self.deinit()` would double-destroy via the pool.
        fn grow(self: *Self, new_len: usize) Error!void {
            const dev = self.opts.device;
            const replacement = try create(self.opts, new_len);
            // From here on `self.{buffer,memory}` are the OLD pair;
            // release them. If `release` itself OOMs, we have to
            // destroy directly (same fallback as `deinit`), but the
            // new pair is already constructed and `self.* =
            // replacement` will reach a healthy state regardless.
            const bp = @import("../Vulkan.zig").buffer_pool;
            const capacity_bytes: u64 = @as(u64, self.len) * @sizeOf(T);
            bp.release(
                dev,
                self.buffer,
                self.memory,
                self.opts.usage,
                capacity_bytes,
            ) catch {
                _ = dev.dispatch.deviceWaitIdle(dev.device);
                dev.dispatch.destroyBuffer(dev.device, self.buffer, null);
                dev.dispatch.freeMemory(dev.device, self.memory, null);
            };
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
