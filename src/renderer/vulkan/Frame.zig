//! Per-draw recording context. Lifecycle: `begin` → caller records
//! commands (via the eventual `renderPass()` accessor) → `complete`.
//!
//! Unlike `opengl/Frame.zig` (which is a zero-state wrapper around
//! the implicit GL context), Vulkan's Frame drives the explicit
//! sync model: a fence is signaled when the GPU finishes the
//! frame's submit, and `complete` waits on it before handing the
//! dmabuf fd to the host. That's required for correctness — the
//! host shouldn't sample memory the GPU is still writing — and
//! acceptable for perf because terminal frames cap at ~60Hz.
//!
//! Ownership: the command buffer and fence are owned by the
//! top-level renderer (`Vulkan.zig`, not yet wired) and passed into
//! `begin` via `Options`. Frame just borrows them. The top-level
//! is responsible for creating/destroying them and for resetting
//! the fence to unsignaled state before `begin` (this layer would
//! conflate ownership otherwise).
//!
//! Why not semaphores? With dmabuf export to the host (rather than
//! a `VkSwapchain` we own), we have no acquire/present semaphore
//! pair to sync against. Fence-only is the right model when
//! libghostty hands the host a "GPU is done writing to this fd"
//! guarantee at present time. The host's own compositor handles
//! display sync from there.
//!
//! `renderPass()` will land alongside `vulkan/RenderPass.zig` in a
//! follow-up commit. For now it's not declared — calling code that
//! tries to record into a frame will fail to compile, which is
//! intentional: the recording path isn't ready.
//!
//! Counterpart: `src/renderer/opengl/Frame.zig`.

const Self = @This();

const std = @import("std");
const vulkan = @import("vulkan");
const vk = vulkan.c;

const Device = vulkan.Device;
const DescriptorPool = vulkan.DescriptorPool;
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Vulkan = @import("../Vulkan.zig");
const Renderer = @import("../generic.zig").Renderer(Vulkan);
const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.vulkan);

pub const Options = struct {
    /// Command buffer this frame's commands record into. Caller
    /// resets it to a fresh state before `begin` is called.
    cb: vk.VkCommandBuffer,

    /// Fence that gets signaled when the submit completes. Caller
    /// resets it to unsignaled before `begin` is called.
    fence: vk.VkFence,

    /// Per-frame descriptor pool. `RenderPass.step` borrows it for
    /// the per-call descriptor sets it allocates whenever a
    /// pipeline is re-used within a single pass. The pool is
    /// caller-owned (top-level `Vulkan.zig` keeps it threadlocal)
    /// and must be reset (`vkResetDescriptorPool`) by the caller
    /// before each Frame.begin so this frame's allocations don't
    /// pile on the previous frame's.
    step_pool: ?*DescriptorPool = null,
};

pub const Error = error{
    /// `vkBeginCommandBuffer` / `vkEndCommandBuffer` /
    /// `vkQueueSubmit` / `vkWaitForFences` returned a non-success
    /// status.
    VulkanFailed,
};

device: *const Device,
renderer: *Renderer,
target: *Target,
cb: vk.VkCommandBuffer,
fence: vk.VkFence,
step_pool: ?*DescriptorPool = null,

/// Begin recording a frame. The command buffer is reset and started
/// with `ONE_TIME_SUBMIT` since we always submit before the next
/// `begin` overwrites it.
pub fn begin(
    opts: Options,
    device: *const Device,
    renderer: *Renderer,
    target: *Target,
) Error!Self {
    const begin_info: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    const r = device.dispatch.beginCommandBuffer(opts.cb, &begin_info);
    if (r != vk.VK_SUCCESS) {
        log.err("vkBeginCommandBuffer (frame) failed: result={}", .{r});
        return error.VulkanFailed;
    }

    return .{
        .device = device,
        .renderer = renderer,
        .target = target,
        .cb = opts.cb,
        .fence = opts.fence,
        .step_pool = opts.step_pool,
    };
}

/// End recording, submit to the queue with `self.fence`, and (if
/// `sync` is true, which it always is for our dmabuf-export model)
/// wait on the fence so the GPU is guaranteed to be done before
/// the host imports the target's dmabuf.
///
/// `sync == false` is accepted by the interface for parity with
/// `opengl/Frame.zig`, but currently still does the wait — without
/// it, handing the dmabuf fd to the host would race the GPU. The
/// argument may eventually drive multi-frame pipelining once a
/// proper queue of frames is in flight.
pub fn complete(self: *const Self, sync: bool) void {
    // `sync` is part of the cross-backend `Frame.complete` interface
    // (OpenGL / Metal / Vulkan all share it). The Vulkan path is
    // always synchronous today: we waitForFences before handing the
    // dmabuf fd to the host, and the host cannot sample a buffer
    // mid-GPU-write. So `sync=false` is silently treated as
    // `sync=true`. If multi-frame pipelining ever lands, this is
    // where the param would gate the wait.
    _ = sync;
    const dev = self.device;

    // `health` becomes `.unhealthy` on any GPU-side error below. We
    // ALWAYS run `buffer_pool.cycle` and `frameCompleted` on the
    // way out — skipping them on error left every retired buffer
    // stuck in `pending` (unbounded growth) and held the renderer's
    // swap-chain semaphore forever, so the NEXT `drawFrame` would
    // hang with no diagnostic.
    var health: Health = .healthy;
    var submitted = false;

    // Make the rendered pixels visible to the host's mmap read. In
    // `.direct` mode this is just a memory barrier; in `.legacy_copy`
    // mode it also runs `vkCmdCopyImageToBuffer`. See `Target.zig`.
    self.target.recordPresentBarrier(self.cb);

    end_cb: {
        const r = dev.dispatch.endCommandBuffer(self.cb);
        if (r != vk.VK_SUCCESS) {
            log.err("vkEndCommandBuffer (frame) failed: result={}", .{r});
            health = .unhealthy;
            break :end_cb;
        }

        const submit_info: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cb,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        // Externally-synchronized via `Device.queueSubmit` — splits
        // and tabs share the host's VkQueue and Vulkan rejects
        // concurrent unsynchronized access.
        const sr = dev.queueSubmit(1, &submit_info, self.fence);
        if (sr != vk.VK_SUCCESS) {
            log.err("vkQueueSubmit (frame) failed: result={}", .{sr});
            health = .unhealthy;
            break :end_cb;
        }
        submitted = true;

        // Wait for the GPU to finish writing the target before letting
        // the host import the dmabuf. UINT64_MAX = "wait indefinitely".
        const wr = dev.dispatch.waitForFences(
            dev.device,
            1,
            &self.fence,
            vk.VK_TRUE,
            std.math.maxInt(u64),
        );
        if (wr != vk.VK_SUCCESS) {
            log.err("vkWaitForFences (frame) failed: result={}", .{wr});
            health = .unhealthy;
        }
    }

    // Recycle the per-frame Buffer pool. Even on the error path we
    // still want to cycle: buffers that the failed submit referenced
    // are now stuck (we can't prove the GPU is done with them), so
    // we conservatively wait the device idle when submit DID happen
    // but the fence wait failed (DEVICE_LOST etc.) before draining.
    // Without that wait, every failed submit could leak the buffers
    // the renderer queued for the frame.
    if (health == .unhealthy and submitted) {
        _ = dev.dispatch.deviceWaitIdle(dev.device);
    }
    Vulkan.buffer_pool.cycle(dev);

    // Hand the rendered target off to the host. On the unhealthy
    // path we skip present — the dmabuf may be partially written
    // and the host should see the previous frame instead (the
    // generic renderer's no-op-frame logic re-presents
    // `last_target`).
    if (health == .healthy) {
        self.renderer.api.present(self.target) catch |err| {
            log.err("present failed: {}", .{err});
            health = .unhealthy;
        };
    }

    // Tell the generic renderer the frame is done so it releases the
    // swap-chain semaphore. Without this, `SwapChain.nextFrame()`
    // blocks the second call to `drawFrame` forever (one buffer in
    // the chain, never freed). MUST run regardless of `health`.
    self.renderer.frameCompleted(health);
}

/// Begin a render pass recording into this frame's command buffer.
/// The returned `RenderPass` accepts `step()` calls for the
/// per-pipeline draw work, and is finalized with `complete()`.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .device = self.device,
        .cb = self.cb,
        .step_pool = self.step_pool,
        .attachments = attachments,
    });
}

test {
    std.testing.refAllDecls(@This());
}
