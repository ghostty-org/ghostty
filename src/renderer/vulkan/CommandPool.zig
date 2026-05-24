//! Wrapper for `VkCommandPool` with a one-shot command-buffer helper.
//!
//! Initially used by `vulkan/Texture.zig` for staging-buffer uploads:
//! allocate a transient command buffer, record an upload + layout
//! barriers, submit, wait for completion, free.
//!
//! Eventually the renderer will grow a separate per-frame command
//! pool for the main draw stream; this pool stays around for
//! infrequent operations like atlas uploads where blocking the
//! caller is fine. The choice keeps the API small and avoids the
//! complication of multi-frame fence tracking for resources that
//! will outlive the upload.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

pub const Error = error{
    /// A `vkCreateCommandPool` / `vkAllocateCommandBuffers` /
    /// `vkBeginCommandBuffer` / `vkEndCommandBuffer` / `vkQueueSubmit`
    /// returned a non-success status. Logged with the raw `VkResult`.
    VulkanFailed,
};

device: *const Device,
pool: vk.VkCommandPool,

/// Create a command pool on the device's graphics queue family. The
/// pool is created with `TRANSIENT_BIT | RESET_COMMAND_BUFFER_BIT`
/// because every command buffer we allocate here is short-lived and
/// freed (or reset) immediately after submit.
pub fn init(device: *const Device) Error!Self {
    const info: vk.VkCommandPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
            vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = device.queue_family_index,
    };
    var pool: vk.VkCommandPool = undefined;
    const r = device.dispatch.createCommandPool(device.device, &info, null, &pool);
    if (r != vk.VK_SUCCESS) {
        log.err("vkCreateCommandPool failed: result={}", .{r});
        return error.VulkanFailed;
    }
    return .{ .device = device, .pool = pool };
}

pub fn deinit(self: *Self) void {
    self.device.dispatch.destroyCommandPool(self.device.device, self.pool, null);
    self.* = undefined;
}

/// A one-shot recording session. Yielded from `beginOneShot`, drives
/// `endAndSubmit` when the caller is done recording.
pub const OneShot = struct {
    pool: *Self,
    cb: vk.VkCommandBuffer,

    /// Record any commands directly via `cb` and the device dispatch
    /// table (e.g. `pool.device.dispatch.cmdPipelineBarrier(cb, …)`).
    /// Then call `endAndSubmit`. The command buffer is freed by the
    /// time this returns.
    pub fn endAndSubmit(self: OneShot) Error!void {
        const dev = self.pool.device;

        {
            const r = dev.dispatch.endCommandBuffer(self.cb);
            if (r != vk.VK_SUCCESS) {
                log.err("vkEndCommandBuffer failed: result={}", .{r});
                return error.VulkanFailed;
            }
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
        {
            // Externally-synchronized via `Device.queueSubmit` —
            // see the note there. Splits/tabs both submit here for
            // atlas uploads, and the per-frame Frame.complete path
            // also uses the same queue.
            const r = dev.queueSubmit(1, &submit_info, null);
            if (r != vk.VK_SUCCESS) {
                log.err("vkQueueSubmit failed: result={}", .{r});
                return error.VulkanFailed;
            }
        }

        // Block until the submit completes. Acceptable for one-shot
        // uploads (atlas resizes are rare and the caller is willing
        // to stall). Per-frame command submission will use fences
        // and never queueWaitIdle.
        {
            const r = dev.queueWaitIdle();
            if (r != vk.VK_SUCCESS) {
                log.err("vkQueueWaitIdle failed: result={}", .{r});
                return error.VulkanFailed;
            }
        }

        // Free the command buffer. The pool itself stays around so
        // back-to-back uploads can reuse it without re-allocating
        // VkCommandPool.
        const cb_local = self.cb;
        dev.dispatch.freeCommandBuffers(dev.device, self.pool.pool, 1, &cb_local);
    }
};

/// Allocate + begin a transient command buffer for a one-shot
/// upload. Pair with `OneShot.endAndSubmit`.
pub fn beginOneShot(self: *Self) Error!OneShot {
    const dev = self.device;

    const alloc_info: vk.VkCommandBufferAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var cb: vk.VkCommandBuffer = undefined;
    {
        const r = dev.dispatch.allocateCommandBuffers(dev.device, &alloc_info, &cb);
        if (r != vk.VK_SUCCESS) {
            log.err("vkAllocateCommandBuffers failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.freeCommandBuffers(dev.device, self.pool, 1, &cb);

    const begin_info: vk.VkCommandBufferBeginInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    {
        const r = dev.dispatch.beginCommandBuffer(cb, &begin_info);
        if (r != vk.VK_SUCCESS) {
            log.err("vkBeginCommandBuffer failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    return .{ .pool = self, .cb = cb };
}

test {
    std.testing.refAllDecls(@This());
}
