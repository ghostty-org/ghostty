//! Host-provided Vulkan device wrapper.
//!
//! libghostty does NOT call `vkCreateInstance` / `vkCreateDevice` for
//! the Vulkan renderer: per `ghostty_platform_vulkan_s` in
//! `include/ghostty.h`, the host (the apprt embedding libghostty —
//! e.g. the Qt frontend) owns the entire Vulkan setup. We consume
//! its handles via the platform callbacks, validate the version /
//! extensions we need, and build a function-pointer dispatch table
//! the rest of the renderer can use.
//!
//! Why host-owned? The host already has a Vulkan instance/device for
//! its own compositing (Qt's RHI). Asking the host to share its
//! device means rendered frames can be handed back as raw `VkImage`
//! handles or dmabuf fds without a CPU readback or a second Vulkan
//! instance fighting for the same GPU resources.
//!
//! Vulkan version: 1.3 (Jan 2022). Promotes dynamic rendering,
//! sync2, extended dynamic state — all of which simplify a
//! dirty-rect-style terminal renderer. Driver coverage is fine on
//! every distro currently in support.
//!
//! Required device extensions (must be enabled on the host's
//! VkDevice; we verify each on init):
//!   - VK_KHR_external_memory_fd
//!   - VK_EXT_external_memory_dma_buf
//!   - VK_EXT_image_drm_format_modifier
//!
//! These are what let libghostty export the rendered VkImage memory
//! as a dmabuf fd so the host can import it for zero-copy
//! presentation (path 3 in the qt-vulkan-renderer scoping log:
//! preserves Qt's QWidget composition model AND avoids the CPU
//! readback the OpenGL path currently does).

const std = @import("std");
const Allocator = std.mem.Allocator;

const vk = @import("c.zig").c;

const log = std.log.scoped(.vulkan);

const Device = @This();

/// Minimum Vulkan API version the renderer requires.
pub const MIN_API_VERSION = vk.VK_API_VERSION_1_3;

/// Device extensions libghostty enables on top of the host's
/// VkDevice setup. The host must have created its VkDevice with
/// these enabled; we only verify availability here.
///
/// `VK_EXT_image_drm_format_modifier` is what lets
/// `vulkan/Target.zig` probe the per-modifier feature set (in
/// particular: does `DRM_FORMAT_MOD_LINEAR` advertise
/// `COLOR_ATTACHMENT_BIT`?) and, when supported, allocate the render
/// image with `VkImageDrmFormatModifierExplicitCreateInfoEXT` so its
/// memory can be exported as a dmabuf directly — no separate LINEAR
/// `VkBuffer` and no end-of-frame `vkCmdCopyImageToBuffer`. Drivers
/// where the modifier path can't satisfy the requested features fall
/// back to the legacy OPTIMAL-plus-copy path inside `Target`.
pub const REQUIRED_DEVICE_EXTENSIONS = [_][:0]const u8{
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
    "VK_EXT_image_drm_format_modifier",
};

/// Errors that can come out of `init`.
pub const Error = error{
    /// The host returned a null handle for `instance` / `device` /
    /// `queue` / `physical_device`, or `get_instance_proc_addr`
    /// failed to resolve a core Vulkan function we need to bootstrap.
    HostHandleMissing,

    /// The host's VkPhysicalDevice doesn't report a Vulkan API version
    /// >= MIN_API_VERSION. Detected via `vkGetPhysicalDeviceProperties`.
    UnsupportedVulkanVersion,

    /// At least one entry in `REQUIRED_DEVICE_EXTENSIONS` was not
    /// listed in `vkEnumerateDeviceExtensionProperties` for the
    /// host's VkPhysicalDevice.
    MissingRequiredExtension,
};

/// The function-pointer dispatch table libghostty resolves against the
/// host's instance / device. We only enumerate the entry points the
/// renderer actually uses; extending the table is the supported way
/// for follow-up renderer code to call additional Vulkan functions.
pub const Dispatch = struct {
    // ---- instance-level -----------------------------------------
    getPhysicalDeviceProperties: std.meta.Child(vk.PFN_vkGetPhysicalDeviceProperties),
    getPhysicalDeviceMemoryProperties: std.meta.Child(vk.PFN_vkGetPhysicalDeviceMemoryProperties),
    getPhysicalDeviceFormatProperties: std.meta.Child(vk.PFN_vkGetPhysicalDeviceFormatProperties),
    /// Used by `Target` to chain `VkDrmFormatModifierPropertiesListEXT`
    /// and enumerate which DRM modifiers the device exposes for a
    /// given format. Vulkan 1.1 promoted `vkGetPhysicalDeviceFormatProperties2`
    /// from `VK_KHR_get_physical_device_properties2` into core, so we
    /// resolve it under the non-suffixed name — `MIN_API_VERSION` is
    /// 1.3 (see line 45), well past the promotion.
    getPhysicalDeviceFormatProperties2: std.meta.Child(vk.PFN_vkGetPhysicalDeviceFormatProperties2),
    enumerateDeviceExtensionProperties: std.meta.Child(vk.PFN_vkEnumerateDeviceExtensionProperties),
    getDeviceProcAddr: std.meta.Child(vk.PFN_vkGetDeviceProcAddr),

    // ---- device-level (resolved via getDeviceProcAddr) ----------
    // Intentionally narrow for now — every additional renderer-side
    // call adds a field here and a `loadDevice` lookup in `init`.
    getDeviceQueue: std.meta.Child(vk.PFN_vkGetDeviceQueue),
    deviceWaitIdle: std.meta.Child(vk.PFN_vkDeviceWaitIdle),

    // Sampler — used by `vulkan/Sampler.zig`.
    createSampler: std.meta.Child(vk.PFN_vkCreateSampler),
    destroySampler: std.meta.Child(vk.PFN_vkDestroySampler),

    // Texture (image + memory + view) — used by `vulkan/Texture.zig`.
    createImage: std.meta.Child(vk.PFN_vkCreateImage),
    destroyImage: std.meta.Child(vk.PFN_vkDestroyImage),
    getImageMemoryRequirements: std.meta.Child(vk.PFN_vkGetImageMemoryRequirements),
    allocateMemory: std.meta.Child(vk.PFN_vkAllocateMemory),
    freeMemory: std.meta.Child(vk.PFN_vkFreeMemory),
    bindImageMemory: std.meta.Child(vk.PFN_vkBindImageMemory),
    createImageView: std.meta.Child(vk.PFN_vkCreateImageView),
    destroyImageView: std.meta.Child(vk.PFN_vkDestroyImageView),

    // Buffer (host-visible vertex / uniform / cell-data storage) —
    // used by `vulkan/buffer.zig`.
    createBuffer: std.meta.Child(vk.PFN_vkCreateBuffer),
    destroyBuffer: std.meta.Child(vk.PFN_vkDestroyBuffer),
    getBufferMemoryRequirements: std.meta.Child(vk.PFN_vkGetBufferMemoryRequirements),
    bindBufferMemory: std.meta.Child(vk.PFN_vkBindBufferMemory),
    mapMemory: std.meta.Child(vk.PFN_vkMapMemory),
    unmapMemory: std.meta.Child(vk.PFN_vkUnmapMemory),

    // Command pool / buffer + queue submit + recording —
    // used by `vulkan/CommandPool.zig` and (later) per-frame command
    // recording in `vulkan/Frame.zig`.
    createCommandPool: std.meta.Child(vk.PFN_vkCreateCommandPool),
    destroyCommandPool: std.meta.Child(vk.PFN_vkDestroyCommandPool),
    allocateCommandBuffers: std.meta.Child(vk.PFN_vkAllocateCommandBuffers),
    freeCommandBuffers: std.meta.Child(vk.PFN_vkFreeCommandBuffers),
    beginCommandBuffer: std.meta.Child(vk.PFN_vkBeginCommandBuffer),
    endCommandBuffer: std.meta.Child(vk.PFN_vkEndCommandBuffer),
    queueSubmit: std.meta.Child(vk.PFN_vkQueueSubmit),
    queueWaitIdle: std.meta.Child(vk.PFN_vkQueueWaitIdle),
    cmdPipelineBarrier: std.meta.Child(vk.PFN_vkCmdPipelineBarrier),
    cmdCopyBufferToImage: std.meta.Child(vk.PFN_vkCmdCopyBufferToImage),
    cmdFillBuffer: std.meta.Child(vk.PFN_vkCmdFillBuffer),
    cmdClearColorImage: std.meta.Child(vk.PFN_vkCmdClearColorImage),
    cmdBindVertexBuffers: std.meta.Child(vk.PFN_vkCmdBindVertexBuffers),

    // Shader modules — used by `vulkan/shaders.zig`.
    createShaderModule: std.meta.Child(vk.PFN_vkCreateShaderModule),
    destroyShaderModule: std.meta.Child(vk.PFN_vkDestroyShaderModule),

    // Graphics pipeline + descriptor set layout —
    // used by `vulkan/Pipeline.zig`.
    createDescriptorSetLayout: std.meta.Child(vk.PFN_vkCreateDescriptorSetLayout),
    destroyDescriptorSetLayout: std.meta.Child(vk.PFN_vkDestroyDescriptorSetLayout),
    createPipelineLayout: std.meta.Child(vk.PFN_vkCreatePipelineLayout),
    destroyPipelineLayout: std.meta.Child(vk.PFN_vkDestroyPipelineLayout),
    createGraphicsPipelines: std.meta.Child(vk.PFN_vkCreateGraphicsPipelines),
    destroyPipeline: std.meta.Child(vk.PFN_vkDestroyPipeline),

    // External memory fd export — used by `vulkan/Target.zig`.
    // `vkGetMemoryFdKHR` is from `VK_KHR_external_memory_fd`; needs
    // device-level resolution like any other device function.
    getMemoryFdKHR: std.meta.Child(vk.PFN_vkGetMemoryFdKHR),
    getImageSubresourceLayout: std.meta.Child(vk.PFN_vkGetImageSubresourceLayout),
    /// From `VK_EXT_image_drm_format_modifier`. Used by
    /// `vulkan/Target.zig` after creating an image with the LIST
    /// variant of the modifier create-info to discover which
    /// modifier the driver actually chose.
    getImageDrmFormatModifierPropertiesEXT: std.meta.Child(vk.PFN_vkGetImageDrmFormatModifierPropertiesEXT),

    // Per-frame sync (fence + command-buffer reset) — used by
    // `vulkan/Frame.zig`.
    createFence: std.meta.Child(vk.PFN_vkCreateFence),
    destroyFence: std.meta.Child(vk.PFN_vkDestroyFence),
    waitForFences: std.meta.Child(vk.PFN_vkWaitForFences),
    resetFences: std.meta.Child(vk.PFN_vkResetFences),
    resetCommandBuffer: std.meta.Child(vk.PFN_vkResetCommandBuffer),

    // Drawing — used by `vulkan/RenderPass.zig` (and the smoke
    // test's renderTriangle helper). Vulkan 1.3 promoted
    // `vkCmdBeginRendering` / `vkCmdEndRendering` from the
    // `VK_KHR_dynamic_rendering` extension into core, so they're
    // available without an extension opt-in.
    cmdBeginRendering: std.meta.Child(vk.PFN_vkCmdBeginRendering),
    cmdEndRendering: std.meta.Child(vk.PFN_vkCmdEndRendering),
    cmdBindPipeline: std.meta.Child(vk.PFN_vkCmdBindPipeline),
    cmdSetViewport: std.meta.Child(vk.PFN_vkCmdSetViewport),
    cmdSetScissor: std.meta.Child(vk.PFN_vkCmdSetScissor),
    cmdDraw: std.meta.Child(vk.PFN_vkCmdDraw),
    cmdCopyImageToBuffer: std.meta.Child(vk.PFN_vkCmdCopyImageToBuffer),

    // Descriptor sets — used by `vulkan/DescriptorPool.zig`. Per-
    // surface lifetime today; per-frame pooling will follow when
    // the actual renderer integration lands.
    createDescriptorPool: std.meta.Child(vk.PFN_vkCreateDescriptorPool),
    destroyDescriptorPool: std.meta.Child(vk.PFN_vkDestroyDescriptorPool),
    resetDescriptorPool: std.meta.Child(vk.PFN_vkResetDescriptorPool),
    allocateDescriptorSets: std.meta.Child(vk.PFN_vkAllocateDescriptorSets),
    updateDescriptorSets: std.meta.Child(vk.PFN_vkUpdateDescriptorSets),
    cmdBindDescriptorSets: std.meta.Child(vk.PFN_vkCmdBindDescriptorSets),
};

// ---- fields ---------------------------------------------------------

instance: vk.VkInstance,
physical_device: vk.VkPhysicalDevice,
device: vk.VkDevice,
queue: vk.VkQueue,
queue_family_index: u32,

/// The Vulkan API version the host's physical device reports. Always
/// >= `MIN_API_VERSION` (if it were lower, `init` returns
/// `error.UnsupportedVulkanVersion`).
api_version: u32,

/// Cached `VkPhysicalDeviceMemoryProperties`. The properties are
/// immutable for the physical device's lifetime, so we query once
/// at `init` time instead of on every `findMemoryType` call (which
/// happens for every Buffer/Texture/Target allocation).
memory_properties: vk.VkPhysicalDeviceMemoryProperties,

dispatch: Dispatch,

/// Process-wide mutex protecting access to `queue`. Vulkan requires
/// external synchronization of `VkQueue` — `vkQueueSubmit` and
/// `vkQueueWaitIdle` from multiple threads must not overlap. Splits
/// and tabs share the host's single queue (one VkQueue per process),
/// so the mutex serializes submissions across all renderer threads.
/// Use via `Device.queueSubmit` / `Device.queueWaitIdle`.
var queue_mutex: std.Thread.Mutex = .{};

/// Externally-synchronized `vkQueueSubmit`. ALL submissions to the
/// host queue (Frame, atlas upload, etc.) MUST go through this so
/// concurrent renderer threads from splits/tabs don't race the
/// driver into a hang.
pub fn queueSubmit(
    self: *const Device,
    submit_count: u32,
    submits: [*c]const vk.VkSubmitInfo,
    fence: vk.VkFence,
) vk.VkResult {
    queue_mutex.lock();
    defer queue_mutex.unlock();
    return self.dispatch.queueSubmit(self.queue, submit_count, submits, fence);
}

/// Externally-synchronized `vkQueueWaitIdle`. Same reasoning as
/// `queueSubmit`.
pub fn queueWaitIdle(self: *const Device) vk.VkResult {
    queue_mutex.lock();
    defer queue_mutex.unlock();
    return self.dispatch.queueWaitIdle(self.queue);
}

// ---- API ------------------------------------------------------------

/// Pre-resolved host-Vulkan handles passed into `Device.init`. Keeps
/// `pkg/vulkan` independent of any apprt type — callers (e.g.
/// libghostty's `src/renderer/Vulkan.zig`) translate their own
/// platform-callback struct into this neutral shape.
pub const HostBootstrap = struct {
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family_index: u32,
    /// Root proc-addr resolver. `Device.init` uses this to pull
    /// `vkGetInstanceProcAddr` itself plus every instance-level
    /// function it needs to bootstrap the dispatch table.
    get_instance_proc_addr_raw: *const anyopaque,
};

/// Build a `Device` from pre-resolved host handles. Performs:
///   1. Load the instance-level dispatch via `vkGetInstanceProcAddr`.
///   2. Verify `physicalDeviceProperties.apiVersion >= 1.3`.
///   3. Verify every entry in `REQUIRED_DEVICE_EXTENSIONS` is present
///      on the physical device.
///   4. Load the device-level dispatch via `vkGetDeviceProcAddr`.
///
/// On success the returned `Device` is ready for the renderer to
/// build pipelines / images / command buffers against. The host
/// retains ownership of `instance` / `device` / `queue` — `deinit`
/// is a no-op stub for symmetry.
pub fn init(
    alloc: Allocator,
    boot: HostBootstrap,
) (Error || Allocator.Error)!Device {
    const instance = boot.instance;
    const physical_device = boot.physical_device;
    const device = boot.device;
    const queue = boot.queue;
    const queue_family_index = boot.queue_family_index;

    // ---- instance-level dispatch ---------------------------------
    // The caller-provided get_instance_proc_addr is our root entry
    // point. We resolve other functions via vkGetInstanceProcAddr
    // (instance, name); per the Vulkan spec, passing a non-null
    // instance is valid for any function that takes an instance,
    // physical device, device, or child object of any of these — i.e.
    // everything we care about.
    const get_instance_proc_addr: std.meta.Child(vk.PFN_vkGetInstanceProcAddr) =
        @ptrCast(@alignCast(boot.get_instance_proc_addr_raw));

    const InstanceLoader = struct {
        instance: vk.VkInstance,
        get_instance_proc_addr: std.meta.Child(vk.PFN_vkGetInstanceProcAddr),

        fn load(self: @This(), comptime T: type, name: [*:0]const u8) Error!std.meta.Child(T) {
            const fp = self.get_instance_proc_addr(self.instance, name) orelse {
                log.err("vkGetInstanceProcAddr returned null for {s}", .{name});
                return error.HostHandleMissing;
            };
            return @ptrCast(fp);
        }
    };
    const il: InstanceLoader = .{
        .instance = instance,
        .get_instance_proc_addr = get_instance_proc_addr,
    };

    const get_physical_device_properties =
        try il.load(vk.PFN_vkGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties");
    const get_physical_device_memory_properties =
        try il.load(vk.PFN_vkGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties");
    const get_physical_device_format_properties =
        try il.load(vk.PFN_vkGetPhysicalDeviceFormatProperties, "vkGetPhysicalDeviceFormatProperties");
    const get_physical_device_format_properties_2 =
        try il.load(vk.PFN_vkGetPhysicalDeviceFormatProperties2, "vkGetPhysicalDeviceFormatProperties2");
    const enumerate_device_extension_properties =
        try il.load(vk.PFN_vkEnumerateDeviceExtensionProperties, "vkEnumerateDeviceExtensionProperties");
    const get_device_proc_addr =
        try il.load(vk.PFN_vkGetDeviceProcAddr, "vkGetDeviceProcAddr");

    // ---- version check ------------------------------------------
    var props: vk.VkPhysicalDeviceProperties = std.mem.zeroes(vk.VkPhysicalDeviceProperties);
    get_physical_device_properties(physical_device, &props);
    if (props.apiVersion < MIN_API_VERSION) {
        log.err(
            "host VkPhysicalDevice reports Vulkan {}.{}.{}, need >= {}.{}.{}",
            .{
                vk.VK_API_VERSION_MAJOR(props.apiVersion),
                vk.VK_API_VERSION_MINOR(props.apiVersion),
                vk.VK_API_VERSION_PATCH(props.apiVersion),
                vk.VK_API_VERSION_MAJOR(MIN_API_VERSION),
                vk.VK_API_VERSION_MINOR(MIN_API_VERSION),
                vk.VK_API_VERSION_PATCH(MIN_API_VERSION),
            },
        );
        return error.UnsupportedVulkanVersion;
    }

    // ---- extension check ----------------------------------------
    var ext_count: u32 = 0;
    {
        const r = enumerate_device_extension_properties(physical_device, null, &ext_count, null);
        // SUCCESS or INCOMPLETE both populate `ext_count`. INCOMPLETE
        // shouldn't happen on the count-only call (no buffer to
        // truncate) but we accept it defensively.
        if (r != vk.VK_SUCCESS and r != vk.VK_INCOMPLETE) {
            log.err("vkEnumerateDeviceExtensionProperties (count) failed: result={}", .{r});
            return error.HostHandleMissing;
        }
    }
    const exts = try alloc.alloc(vk.VkExtensionProperties, ext_count);
    defer alloc.free(exts);
    {
        const r = enumerate_device_extension_properties(physical_device, null, &ext_count, exts.ptr);
        if (r != vk.VK_SUCCESS and r != vk.VK_INCOMPLETE) {
            log.err("vkEnumerateDeviceExtensionProperties (fill) failed: result={}", .{r});
            return error.HostHandleMissing;
        }
        // VK_INCOMPLETE here means the extension list grew between
        // the count and fill calls (race with a driver hot-reload —
        // very unlikely in practice but spec-permitted). The
        // partially-filled buffer is still authoritative for the
        // entries it does contain, but a required extension not yet
        // populated would be missed. Treat as a hard fail since the
        // extension presence check below would silently pass on a
        // truncated list.
        if (r == vk.VK_INCOMPLETE) {
            log.err(
                "vkEnumerateDeviceExtensionProperties returned INCOMPLETE; " ++
                    "device extension list changed between count and fill",
                .{},
            );
            return error.HostHandleMissing;
        }
    }

    inline for (REQUIRED_DEVICE_EXTENSIONS) |required| {
        var found = false;
        for (exts) |ext| {
            const name_cstr: [*:0]const u8 = @ptrCast(&ext.extensionName);
            if (std.mem.eql(u8, std.mem.span(name_cstr), required)) {
                found = true;
                break;
            }
        }
        if (!found) {
            log.err("required Vulkan device extension missing: {s}", .{required});
            return error.MissingRequiredExtension;
        }
    }

    // ---- device-level dispatch ----------------------------------
    const DeviceLoader = struct {
        device: vk.VkDevice,
        get_device_proc_addr: std.meta.Child(vk.PFN_vkGetDeviceProcAddr),

        fn load(self: @This(), comptime T: type, name: [*:0]const u8) Error!std.meta.Child(T) {
            const fp = self.get_device_proc_addr(self.device, name) orelse {
                log.err("vkGetDeviceProcAddr returned null for {s}", .{name});
                return error.HostHandleMissing;
            };
            return @ptrCast(fp);
        }
    };
    const dl: DeviceLoader = .{
        .device = device,
        .get_device_proc_addr = get_device_proc_addr,
    };

    const get_device_queue =
        try dl.load(vk.PFN_vkGetDeviceQueue, "vkGetDeviceQueue");
    const device_wait_idle =
        try dl.load(vk.PFN_vkDeviceWaitIdle, "vkDeviceWaitIdle");
    const create_sampler =
        try dl.load(vk.PFN_vkCreateSampler, "vkCreateSampler");
    const destroy_sampler =
        try dl.load(vk.PFN_vkDestroySampler, "vkDestroySampler");
    const create_image =
        try dl.load(vk.PFN_vkCreateImage, "vkCreateImage");
    const destroy_image =
        try dl.load(vk.PFN_vkDestroyImage, "vkDestroyImage");
    const get_image_memory_requirements =
        try dl.load(vk.PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    const allocate_memory =
        try dl.load(vk.PFN_vkAllocateMemory, "vkAllocateMemory");
    const free_memory =
        try dl.load(vk.PFN_vkFreeMemory, "vkFreeMemory");
    const bind_image_memory =
        try dl.load(vk.PFN_vkBindImageMemory, "vkBindImageMemory");
    const create_image_view =
        try dl.load(vk.PFN_vkCreateImageView, "vkCreateImageView");
    const destroy_image_view =
        try dl.load(vk.PFN_vkDestroyImageView, "vkDestroyImageView");
    const create_buffer =
        try dl.load(vk.PFN_vkCreateBuffer, "vkCreateBuffer");
    const destroy_buffer =
        try dl.load(vk.PFN_vkDestroyBuffer, "vkDestroyBuffer");
    const get_buffer_memory_requirements =
        try dl.load(vk.PFN_vkGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements");
    const bind_buffer_memory =
        try dl.load(vk.PFN_vkBindBufferMemory, "vkBindBufferMemory");
    const map_memory =
        try dl.load(vk.PFN_vkMapMemory, "vkMapMemory");
    const unmap_memory =
        try dl.load(vk.PFN_vkUnmapMemory, "vkUnmapMemory");
    const create_command_pool =
        try dl.load(vk.PFN_vkCreateCommandPool, "vkCreateCommandPool");
    const destroy_command_pool =
        try dl.load(vk.PFN_vkDestroyCommandPool, "vkDestroyCommandPool");
    const allocate_command_buffers =
        try dl.load(vk.PFN_vkAllocateCommandBuffers, "vkAllocateCommandBuffers");
    const free_command_buffers =
        try dl.load(vk.PFN_vkFreeCommandBuffers, "vkFreeCommandBuffers");
    const begin_command_buffer =
        try dl.load(vk.PFN_vkBeginCommandBuffer, "vkBeginCommandBuffer");
    const end_command_buffer =
        try dl.load(vk.PFN_vkEndCommandBuffer, "vkEndCommandBuffer");
    const queue_submit =
        try dl.load(vk.PFN_vkQueueSubmit, "vkQueueSubmit");
    const queue_wait_idle =
        try dl.load(vk.PFN_vkQueueWaitIdle, "vkQueueWaitIdle");
    const cmd_pipeline_barrier =
        try dl.load(vk.PFN_vkCmdPipelineBarrier, "vkCmdPipelineBarrier");
    const cmd_copy_buffer_to_image =
        try dl.load(vk.PFN_vkCmdCopyBufferToImage, "vkCmdCopyBufferToImage");
    const cmd_fill_buffer =
        try dl.load(vk.PFN_vkCmdFillBuffer, "vkCmdFillBuffer");
    const cmd_clear_color_image =
        try dl.load(vk.PFN_vkCmdClearColorImage, "vkCmdClearColorImage");
    const cmd_bind_vertex_buffers =
        try dl.load(vk.PFN_vkCmdBindVertexBuffers, "vkCmdBindVertexBuffers");
    const create_shader_module =
        try dl.load(vk.PFN_vkCreateShaderModule, "vkCreateShaderModule");
    const destroy_shader_module =
        try dl.load(vk.PFN_vkDestroyShaderModule, "vkDestroyShaderModule");
    const create_descriptor_set_layout =
        try dl.load(vk.PFN_vkCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout");
    const destroy_descriptor_set_layout =
        try dl.load(vk.PFN_vkDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout");
    const create_pipeline_layout =
        try dl.load(vk.PFN_vkCreatePipelineLayout, "vkCreatePipelineLayout");
    const destroy_pipeline_layout =
        try dl.load(vk.PFN_vkDestroyPipelineLayout, "vkDestroyPipelineLayout");
    const create_graphics_pipelines =
        try dl.load(vk.PFN_vkCreateGraphicsPipelines, "vkCreateGraphicsPipelines");
    const destroy_pipeline =
        try dl.load(vk.PFN_vkDestroyPipeline, "vkDestroyPipeline");
    const get_memory_fd_khr =
        try dl.load(vk.PFN_vkGetMemoryFdKHR, "vkGetMemoryFdKHR");
    const get_image_subresource_layout =
        try dl.load(vk.PFN_vkGetImageSubresourceLayout, "vkGetImageSubresourceLayout");
    const get_image_drm_format_modifier_properties_ext =
        try dl.load(vk.PFN_vkGetImageDrmFormatModifierPropertiesEXT, "vkGetImageDrmFormatModifierPropertiesEXT");
    const create_fence =
        try dl.load(vk.PFN_vkCreateFence, "vkCreateFence");
    const destroy_fence =
        try dl.load(vk.PFN_vkDestroyFence, "vkDestroyFence");
    const wait_for_fences =
        try dl.load(vk.PFN_vkWaitForFences, "vkWaitForFences");
    const reset_fences =
        try dl.load(vk.PFN_vkResetFences, "vkResetFences");
    const reset_command_buffer =
        try dl.load(vk.PFN_vkResetCommandBuffer, "vkResetCommandBuffer");
    const cmd_begin_rendering =
        try dl.load(vk.PFN_vkCmdBeginRendering, "vkCmdBeginRendering");
    const cmd_end_rendering =
        try dl.load(vk.PFN_vkCmdEndRendering, "vkCmdEndRendering");
    const cmd_bind_pipeline =
        try dl.load(vk.PFN_vkCmdBindPipeline, "vkCmdBindPipeline");
    const cmd_set_viewport =
        try dl.load(vk.PFN_vkCmdSetViewport, "vkCmdSetViewport");
    const cmd_set_scissor =
        try dl.load(vk.PFN_vkCmdSetScissor, "vkCmdSetScissor");
    const cmd_draw =
        try dl.load(vk.PFN_vkCmdDraw, "vkCmdDraw");
    const cmd_copy_image_to_buffer =
        try dl.load(vk.PFN_vkCmdCopyImageToBuffer, "vkCmdCopyImageToBuffer");
    const create_descriptor_pool =
        try dl.load(vk.PFN_vkCreateDescriptorPool, "vkCreateDescriptorPool");
    const destroy_descriptor_pool =
        try dl.load(vk.PFN_vkDestroyDescriptorPool, "vkDestroyDescriptorPool");
    const reset_descriptor_pool =
        try dl.load(vk.PFN_vkResetDescriptorPool, "vkResetDescriptorPool");
    const allocate_descriptor_sets =
        try dl.load(vk.PFN_vkAllocateDescriptorSets, "vkAllocateDescriptorSets");
    const update_descriptor_sets =
        try dl.load(vk.PFN_vkUpdateDescriptorSets, "vkUpdateDescriptorSets");
    const cmd_bind_descriptor_sets =
        try dl.load(vk.PFN_vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets");

    // Snapshot the memory properties once. They never change for
    // the device's lifetime, so per-allocation re-queries (which
    // findMemoryType used to do) were pure waste.
    var memory_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
    get_physical_device_memory_properties(physical_device, &memory_properties);

    return .{
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family_index = queue_family_index,
        .api_version = props.apiVersion,
        .memory_properties = memory_properties,
        .dispatch = .{
            .getPhysicalDeviceProperties = get_physical_device_properties,
            .getPhysicalDeviceMemoryProperties = get_physical_device_memory_properties,
            .getPhysicalDeviceFormatProperties = get_physical_device_format_properties,
            .getPhysicalDeviceFormatProperties2 = get_physical_device_format_properties_2,
            .enumerateDeviceExtensionProperties = enumerate_device_extension_properties,
            .getDeviceProcAddr = get_device_proc_addr,
            .getDeviceQueue = get_device_queue,
            .deviceWaitIdle = device_wait_idle,
            .createSampler = create_sampler,
            .destroySampler = destroy_sampler,
            .createImage = create_image,
            .destroyImage = destroy_image,
            .getImageMemoryRequirements = get_image_memory_requirements,
            .allocateMemory = allocate_memory,
            .freeMemory = free_memory,
            .bindImageMemory = bind_image_memory,
            .createImageView = create_image_view,
            .destroyImageView = destroy_image_view,
            .createBuffer = create_buffer,
            .destroyBuffer = destroy_buffer,
            .getBufferMemoryRequirements = get_buffer_memory_requirements,
            .bindBufferMemory = bind_buffer_memory,
            .mapMemory = map_memory,
            .unmapMemory = unmap_memory,
            .createCommandPool = create_command_pool,
            .destroyCommandPool = destroy_command_pool,
            .allocateCommandBuffers = allocate_command_buffers,
            .freeCommandBuffers = free_command_buffers,
            .beginCommandBuffer = begin_command_buffer,
            .endCommandBuffer = end_command_buffer,
            .queueSubmit = queue_submit,
            .queueWaitIdle = queue_wait_idle,
            .cmdPipelineBarrier = cmd_pipeline_barrier,
            .cmdCopyBufferToImage = cmd_copy_buffer_to_image,
            .cmdFillBuffer = cmd_fill_buffer,
            .cmdClearColorImage = cmd_clear_color_image,
            .cmdBindVertexBuffers = cmd_bind_vertex_buffers,
            .createShaderModule = create_shader_module,
            .destroyShaderModule = destroy_shader_module,
            .createDescriptorSetLayout = create_descriptor_set_layout,
            .destroyDescriptorSetLayout = destroy_descriptor_set_layout,
            .createPipelineLayout = create_pipeline_layout,
            .destroyPipelineLayout = destroy_pipeline_layout,
            .createGraphicsPipelines = create_graphics_pipelines,
            .destroyPipeline = destroy_pipeline,
            .getMemoryFdKHR = get_memory_fd_khr,
            .getImageSubresourceLayout = get_image_subresource_layout,
            .getImageDrmFormatModifierPropertiesEXT = get_image_drm_format_modifier_properties_ext,
            .createFence = create_fence,
            .destroyFence = destroy_fence,
            .waitForFences = wait_for_fences,
            .resetFences = reset_fences,
            .resetCommandBuffer = reset_command_buffer,
            .cmdBeginRendering = cmd_begin_rendering,
            .cmdEndRendering = cmd_end_rendering,
            .cmdBindPipeline = cmd_bind_pipeline,
            .cmdSetViewport = cmd_set_viewport,
            .cmdSetScissor = cmd_set_scissor,
            .cmdDraw = cmd_draw,
            .cmdCopyImageToBuffer = cmd_copy_image_to_buffer,
            .createDescriptorPool = create_descriptor_pool,
            .destroyDescriptorPool = destroy_descriptor_pool,
            .resetDescriptorPool = reset_descriptor_pool,
            .allocateDescriptorSets = allocate_descriptor_sets,
            .updateDescriptorSets = update_descriptor_sets,
            .cmdBindDescriptorSets = cmd_bind_descriptor_sets,
        },
    };
}

/// Symmetry-only: every handle is host-owned. Provided so callers
/// can `defer device.deinit()` without special-casing.
pub fn deinit(self: *Device) void {
    self.* = undefined;
}

/// Block until the device is idle. Useful before tearing down
/// renderer resources to make sure no command buffers are in
/// flight. On `VK_ERROR_DEVICE_LOST` (or any other failure) we
/// log the result so callers proceeding to destroy resources on
/// a dead device leave a diagnostic crumb instead of silently
/// crashing on the subsequent vkDestroy*.
pub fn waitIdle(self: *const Device) void {
    const r = self.dispatch.deviceWaitIdle(self.device);
    if (r != vk.VK_SUCCESS) {
        log.warn("vkDeviceWaitIdle returned {}; teardown proceeding anyway", .{r});
    }
}

/// Find a `VkMemoryType` index satisfying the requirements from a
/// `VkMemoryRequirements.memoryTypeBits` bitmask AND with all of
/// `required_props` set. Returns null if nothing matches.
///
/// Used by `vulkan/Texture.zig` (and later `vulkan/Buffer.zig`) to
/// pick an appropriate heap for a freshly created image/buffer.
pub fn findMemoryType(
    self: *const Device,
    type_bits: u32,
    required_props: vk.VkMemoryPropertyFlags,
) ?u32 {
    const props = &self.memory_properties;
    var i: u32 = 0;
    while (i < props.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if (type_bits & bit == 0) continue;
        if (props.memoryTypes[i].propertyFlags & required_props == required_props) {
            return i;
        }
    }
    return null;
}

test {
    // Force type-checking of every decl in this file so the renderer
    // bring-up catches signature mismatches against the Vulkan
    // binding before the apprt-side wiring lands. The actual init
    // path requires a real host-provided Vulkan device and is
    // exercised end-to-end once the Qt frontend wires up
    // `ghostty_platform_vulkan_s`.
    std.testing.refAllDecls(@This());
}
