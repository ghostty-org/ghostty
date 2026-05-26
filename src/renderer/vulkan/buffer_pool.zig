//! Process-wide pool of `(VkBuffer, VkDeviceMemory)` pairs recycled
//! across frames on the renderer thread. Solves two problems
//! together:
//!
//!   1. Lifetime: `vulkan/buffer.zig`'s `Buffer.deinit` is called
//!      mid-frame (by `renderer/image.zig:draw`'s `defer buf.deinit()`)
//!      while the command buffer that references the buffer hasn't
//!      been submitted yet. Naive immediate destroy → use-after-free.
//!   2. Allocation thrash: a frame with N kitty-image placements
//!      would otherwise allocate N tiny VkBuffers + VkDeviceMemories
//!      per frame, every frame. NVIDIA driver SIGSEGVs after a few
//!      seconds of that.
//!
//! Multi-thread design: `pending` is THREADLOCAL (each renderer
//! thread accumulates the buffers IT released during the current
//! frame), while `ready` is process-wide and mutex-protected (any
//! thread can recycle from it). Splits/tabs run independent
//! renderer threads against the SAME shared VkDevice — a single
//! shared `pending` list would let thread A's `Frame.complete`
//! retire buffers thread B released but whose fence hasn't
//! signaled yet, handing B's still-GPU-in-flight buffer back to a
//! new `acquire`. Per-thread pending bounds the visibility of
//! each entry to the thread that knows when its fence signals.
//!
//! Lifecycle:
//!   - `release(dev, …)` (renderer thread) pushes to THAT thread's
//!     `pending`.
//!   - `cycle(dev)` (renderer thread, after `vkWaitForFences` on
//!     the SAME thread's per-frame fence) moves THAT thread's
//!     `pending` → shared `ready` under the mutex.
//!   - `acquire(…)` (any thread) pops a matching entry from `ready`
//!     under the mutex.
//!
//! Caller responsibilities:
//!   - Only call `release` from the renderer thread whose fence
//!     the frame's GPU work signals; calling from a thread that
//!     never reaches its own `Frame.complete` would leak entries
//!     (they sit in that thread's `pending` forever). For one-shot
//!     uploads from a non-renderer thread (atlas staging), use
//!     `Buffer.destroyImmediate` instead, which bypasses this
//!     pool entirely.

const std = @import("std");
const vulkan = @import("vulkan");
const vk = vulkan.c;

const Device = vulkan.Device;

const log = std.log.scoped(.vulkan);

pub const Entry = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    usage: vk.VkBufferUsageFlags,
    capacity: u64,
};

/// Guards the process-wide `ready` list. Per-thread `pending` is
/// threadlocal and never under this mutex.
var ready_mutex: std.Thread.Mutex = .{};

/// Per-thread pending list. Entries here were released by THIS
/// thread during the current frame and are bounded by the
/// fence THIS thread will wait on in `Frame.complete`. Moved
/// to the shared `ready` list by `cycle()` after that wait
/// returns.
threadlocal var pending: std.ArrayList(Entry) = .{};

/// Process-wide ready list. Entries here are provably retired
/// (the bounding fence has signaled) and any thread may
/// `acquire` them.
var ready: std.ArrayList(Entry) = .{};

/// Queue a buffer for recycling. The buffer cannot be reused
/// until the next fence-wait (handled by `cycle`); it sits in
/// THIS thread's `pending` until then. Bounded by THIS thread's
/// per-frame fence — see the per-thread pending rationale at
/// the top of this module.
pub fn release(
    dev: *const Device,
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    usage: vk.VkBufferUsageFlags,
    capacity: u64,
) !void {
    _ = dev;
    // No mutex: `pending` is threadlocal, only THIS thread
    // touches it.
    try pending.append(std.heap.smp_allocator, .{
        .buffer = buffer,
        .memory = memory,
        .usage = usage,
        .capacity = capacity,
    });
}

/// Pop a `ready` entry whose usage matches and whose capacity is
/// >= the requested size. Linear scan — pools tend to have a
/// small number of distinct (usage, size) shapes (image: 48B
/// VERTEX, bg_image: 8B VERTEX) so this stays cheap.
pub fn acquire(
    usage: vk.VkBufferUsageFlags,
    min_capacity: u64,
) ?Entry {
    ready_mutex.lock();
    defer ready_mutex.unlock();
    var i: usize = 0;
    while (i < ready.items.len) : (i += 1) {
        const e = ready.items[i];
        if (e.usage == usage and e.capacity >= min_capacity) {
            _ = ready.swapRemove(i);
            return e;
        }
    }
    return null;
}

/// Move THIS thread's `pending` entries to the shared `ready` —
/// THIS thread's fence has signaled, so the GPU is done with
/// every buffer in `pending`. Call from `Frame.complete` after
/// `vkWaitForFences`.
///
/// `dev` is needed only on the OOM fallback path: if `ready`
/// can't grow to absorb `pending`, we wait the device idle
/// (OUTSIDE the mutex — see below) and then destroy the pending
/// entries directly so the next frame doesn't double up on a
/// pending list that can never drain.
pub fn cycle(dev: *const Device) void {
    // Try the fast path first — append THIS thread's `pending`
    // to the shared `ready` under the lock, then clear pending.
    // On OOM we have to destroy the pending entries, but
    // `vkDeviceWaitIdle` is slow and holding the pool mutex
    // across it would block every other renderer thread's
    // release/acquire/cycle. Move the pending list into a
    // local outside the lock, then drain.
    var oom_pending: std.ArrayList(Entry) = .{};
    defer oom_pending.deinit(std.heap.smp_allocator);
    {
        ready_mutex.lock();
        defer ready_mutex.unlock();
        if (ready.appendSlice(std.heap.smp_allocator, pending.items)) {
            pending.clearRetainingCapacity();
            return;
        } else |_| {
            // OOM. Move THIS thread's `pending` into our local
            // so we can drain without holding the mutex.
            oom_pending = pending;
            pending = .{};
        }
    }
    // Mutex released. Other threads can release/acquire/cycle
    // while we wait the device idle and destroy our slice.
    _ = dev.dispatch.deviceWaitIdle(dev.device);
    for (oom_pending.items) |e| {
        dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
        dev.dispatch.freeMemory(dev.device, e.memory, null);
    }
}

/// Destroy THIS thread's `pending` entries directly. Call from
/// the same thread's `Vulkan.deinit` AFTER `vkWaitForFences`
/// on this thread's frame fence — the bounding fence has
/// signaled so the GPU is provably done with these buffers.
///
/// Each renderer thread is responsible for cleaning up its own
/// pending list because Zig threadlocal storage is the calling
/// thread's; the final-refcount tear-down (`drainShared`) only
/// handles the process-wide `ready` list.
pub fn drainSelf(dev: *const Device) void {
    for (pending.items) |e| {
        dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
        dev.dispatch.freeMemory(dev.device, e.memory, null);
    }
    pending.clearRetainingCapacity();
}

/// Destroy every entry in the shared `ready` list. Call only
/// from the FINAL surface tear-down (the path that hits
/// `device_refcount == 0`) and only after every other renderer
/// thread has already run `drainSelf` on its own pending list.
pub fn drainShared(dev: *const Device) void {
    ready_mutex.lock();
    defer ready_mutex.unlock();
    for (ready.items) |e| {
        dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
        dev.dispatch.freeMemory(dev.device, e.memory, null);
    }
    ready.clearRetainingCapacity();
}
