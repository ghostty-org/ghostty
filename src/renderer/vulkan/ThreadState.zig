//! Per-renderer-thread Vulkan state. Lifecycle:
//!
//!   - first `Vulkan.beginFrame` on a thread → `ensureInit(dev)`
//!     lazily creates a `CommandPool`, a single command buffer
//!     allocated from it, a fence (created signaled), and a
//!     `DescriptorPool` sized for one frame's worst-case usage.
//!     All four are reused across frames; only the descriptor
//!     pool is reset every frame.
//!   - `Vulkan.deinit` on a surface (one per renderer thread) →
//!     `cleanup(dev)` waits the per-thread fence, frees CB,
//!     destroys pool + fence, drops the cached `last_target`
//!     pointer, and drains the per-thread `buffer_pool` pending
//!     list (which is bounded by the same fence we just waited).
//!
//! Why threadlocal? Splits/tabs share the host's process-wide
//! `VkDevice`, but each renderer thread submits independently and
//! its fence-paced single-frame-in-flight model needs its own
//! fence + command buffer to avoid stomping the previous frame's
//! still-in-flight work. Threadlocal also matches the lifetime of
//! the buffer-pool's per-thread `pending` list (both are bounded
//! by the same `Frame.complete` fence wait).
//!
//! `last_target` lives here too because it's logically per-thread:
//! `presentLastTarget` re-presents whatever the renderer thread
//! handed to `present` last, and pointing at another thread's
//! target would route a different surface's frames to this
//! thread's window.

const std = @import("std");
const vulkan = @import("vulkan");
const vk = vulkan.c;

const Device = vulkan.Device;
const CommandPool = vulkan.CommandPool;
const DescriptorPool = vulkan.DescriptorPool;
const Target = @import("Target.zig");
const buffer_pool = @import("buffer_pool.zig");

const log = std.log.scoped(.vulkan);

/// Caps for the per-frame `step_pool`. Sized for the worst pass
/// shape (kitty image with N placements + the post pipelines): one
/// set per (image_step × MAX_DESCRIPTOR_SETS) plus a handful of
/// the renderer's other pipelines stepped once each. 256 is generous
/// — actual frames stabilize well under that. If a frame ever
/// exhausts the pool, `RenderPass.step` falls back to the pipeline's
/// static set with a warning logged.
pub const STEP_POOL_MAX_SETS: u32 = 256;
pub const STEP_POOL_UNIFORM_BUFFERS: u32 = 256;
pub const STEP_POOL_COMBINED_IMAGE_SAMPLERS: u32 = 256;
pub const STEP_POOL_STORAGE_BUFFERS: u32 = 256;

pub const Error = error{
    /// `vkAllocateCommandBuffers` / `vkCreateFence` returned a
    /// non-success status. Wrapped here so the lazy-init path in
    /// `ensureInit` can surface a single error type to callers.
    VulkanFailed,
    /// `DescriptorPool.init` rejected the caps we passed it (e.g.
    /// max_sets == 0). Surfaces here so callers' error set matches.
    InvalidPoolConfig,
} || std.mem.Allocator.Error;

/// Most recently presented target, used by `presentLastTarget` when
/// the renderer decides nothing new needs drawing. Stored as a
/// POINTER (not a value copy) into the FrameState's `target` slot
/// so it follows the target through a resize: `frame.resize` calls
/// `target.deinit()` on the old Target and overwrites the slot with
/// a new one — a value copy would now reference a closed fd and
/// freed VkImage/VkBuffer/VkDeviceMemory handles, and Qt's mmap on
/// the closed fd could read whatever a later open() recycled the fd
/// for. Following the pointer instead always re-presents the
/// currently-live target.
pub threadlocal var last_target: ?*Target = null;

/// Per-surface (per-thread) command pool used for the frame's
/// command buffer. Lazily created in `ensureInit` on the first call;
/// destroyed in `cleanup`.
pub threadlocal var frame_pool: ?CommandPool = null;

/// The single command buffer allocated from `frame_pool` and reused
/// across frames. `vkResetCommandBuffer` is called at the start of
/// each `beginFrameReset` to clear prior recording.
pub threadlocal var frame_cb: vk.VkCommandBuffer = null;

/// Fence signaled when each frame's submit completes. Caller waits
/// on it in `Frame.complete` before handing the target dmabuf to
/// the host.
pub threadlocal var frame_fence: vk.VkFence = null;

/// Per-thread descriptor pool used by `RenderPass.step` to allocate
/// fresh descriptor sets when the same pipeline is bound more than
/// once in a single pass (vkCmdDraw reads descriptors at submit
/// time, so re-using the pipeline's static set would silently
/// corrupt prior draws). Reset at the start of every
/// `beginFrameReset` so this frame's allocations don't pile on the
/// previous frame's; the per-pass usage is bounded by a small
/// constant — see the `STEP_POOL_*` caps above.
pub threadlocal var step_pool: ?DescriptorPool = null;

/// Lazy per-thread resource init. The first call on a renderer
/// thread sets up the command pool + buffer + fence + descriptor
/// pool that get reused for every subsequent frame. Subsequent
/// calls are no-ops.
///
/// Failure-mode contract: on error the threadlocal state is rolled
/// back to its pre-call values so the next `ensureInit` retries
/// cleanly. Without rollback, a partial failure would leave e.g.
/// `frame_pool != null and frame_cb == null`, and the next call's
/// `if (frame_pool == null)` guard would skip re-init — locking the
/// thread out of the renderer permanently.
pub fn ensureInit(dev: *const Device) Error!void {
    if (frame_pool == null) {
        // Stage everything into locals; only commit to threadlocals
        // after every step succeeds. errdefers chain rollback.
        var pool = try CommandPool.init(dev);
        errdefer pool.deinit();

        const alloc_info: vk.VkCommandBufferAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = pool.pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cb: vk.VkCommandBuffer = null;
        if (dev.dispatch.allocateCommandBuffers(dev.device, &alloc_info, &cb) != vk.VK_SUCCESS)
            return error.VulkanFailed;
        errdefer dev.dispatch.freeCommandBuffers(dev.device, pool.pool, 1, &cb);

        const fence_info: vk.VkFenceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            // Created signaled so the very first `Frame.complete`
            // doesn't try to reset an unsignaled fence.
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        var fence: vk.VkFence = null;
        if (dev.dispatch.createFence(dev.device, &fence_info, null, &fence) != vk.VK_SUCCESS)
            return error.VulkanFailed;
        // No errdefer for fence — past this point all three threadlocals
        // are about to be set together, atomically from the caller's
        // perspective, so any later error in this function is impossible.
        // (`if (step_pool == null)` is a separate block.)

        frame_pool = pool;
        frame_cb = cb;
        frame_fence = fence;
    }
    if (step_pool == null) {
        // Independent of the frame_pool/cb/fence triple — its own
        // failure leaves those committed and only step_pool null,
        // which the next ensureInit() call retries correctly.
        step_pool = try DescriptorPool.init(.{
            .device = dev,
            .max_sets = STEP_POOL_MAX_SETS,
            .uniform_buffers = STEP_POOL_UNIFORM_BUFFERS,
            .combined_image_samplers = STEP_POOL_COMBINED_IMAGE_SAMPLERS,
            .storage_buffers = STEP_POOL_STORAGE_BUFFERS,
        });
    }
}

/// Reset per-frame state at the start of `beginFrame`. Caller is
/// responsible for installing an `errdefer` re-signal of the fence
/// so a failure here doesn't hang the next `Vulkan.deinit` on
/// `waitForFences(UINT64_MAX)` — see the comment in
/// `Vulkan.beginFrame` for the full rationale.
pub fn beginFrameReset(dev: *const Device) error{VulkanFailed}!void {
    if (dev.dispatch.resetCommandBuffer(frame_cb, 0) != vk.VK_SUCCESS)
        return error.VulkanFailed;
    if (step_pool) |*p| {
        if (dev.dispatch.resetDescriptorPool(dev.device, p.pool, 0) != vk.VK_SUCCESS)
            return error.VulkanFailed;
    }
    if (dev.dispatch.resetFences(dev.device, 1, &frame_fence) != vk.VK_SUCCESS)
        return error.VulkanFailed;
}

/// Tear down THIS thread's state. Called from `Vulkan.deinit` on
/// each surface. Waits the per-thread fence (covers any in-flight
/// submit), then destroys the fence, frees the command buffer,
/// destroys the pools, drains the per-thread `buffer_pool` pending
/// list (bounded by the same fence wait), and clears `last_target`.
///
/// Per-surface teardown only needs THIS surface's submissions to be
/// done — block on this thread's frame fence (if it exists) instead
/// of `vkDeviceWaitIdle` on the shared device, which would stall
/// every other tab/split's in-flight GPU work just to close one.
/// The final-refcount path in `Vulkan.deinit` does the device-wide
/// waitIdle.
pub fn cleanup(dev: *const Device) void {
    if (frame_fence != null) {
        const wait_r = dev.dispatch.waitForFences(
            dev.device,
            1,
            &frame_fence,
            vk.VK_TRUE,
            std.math.maxInt(u64),
        );
        if (wait_r != vk.VK_SUCCESS) {
            log.warn(
                "ThreadState.cleanup: vkWaitForFences returned {}, falling back to device-wide wait",
                .{wait_r},
            );
            dev.waitIdle();
        }
        dev.dispatch.destroyFence(dev.device, frame_fence, null);
        frame_fence = null;
    }
    if (frame_pool != null and frame_cb != null) {
        dev.dispatch.freeCommandBuffers(dev.device, frame_pool.?.pool, 1, &frame_cb);
        frame_cb = null;
    }
    if (frame_pool) |*p| {
        p.deinit();
        frame_pool = null;
    }
    if (step_pool) |*p| {
        p.deinit();
        step_pool = null;
    }
    // Drain THIS thread's pending buffer-pool entries. The
    // frame-fence wait above proved the GPU is done with them,
    // and we have to do this from THIS thread because the
    // pending list is in this thread's threadlocal storage —
    // the final-refcount drainShared can't reach it.
    buffer_pool.drainSelf(dev);
    // `last_target` is a borrow into this thread's FrameState
    // target slot. The SwapChain teardown destroys the target;
    // we just drop our reference.
    last_target = null;
}
