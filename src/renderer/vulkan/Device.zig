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

const apprt = @import("../../apprt.zig");
const vk = @import("vulkan").c;

const log = std.log.scoped(.vulkan);

const Device = @This();

/// Minimum Vulkan API version the renderer requires.
pub const MIN_API_VERSION = vk.VK_API_VERSION_1_3;

/// Device extensions libghostty enables on top of the host's
/// VkDevice setup. The host must have created its VkDevice with
/// these enabled; we only verify availability here.
///
/// Note: `VK_EXT_image_drm_format_modifier` is intentionally NOT
/// required yet — `vulkan/Target.zig` currently uses
/// `VK_IMAGE_TILING_LINEAR` for dmabuf export, which only needs the
/// two extensions below. When the driver-chosen modifier path lands,
/// add the modifier extension back here.
pub const REQUIRED_DEVICE_EXTENSIONS = [_][:0]const u8{
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
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
    allocateDescriptorSets: std.meta.Child(vk.PFN_vkAllocateDescriptorSets),
    updateDescriptorSets: std.meta.Child(vk.PFN_vkUpdateDescriptorSets),
    cmdBindDescriptorSets: std.meta.Child(vk.PFN_vkCmdBindDescriptorSets),
};

// ---- fields ---------------------------------------------------------

/// The callbacks the apprt handed us. Held by value (not pointer)
/// because the apprt's `Platform.Vulkan` is itself stored by value
/// inside the `Surface`.
platform: apprt.embedded.Platform.Vulkan,

instance: vk.VkInstance,
physical_device: vk.VkPhysicalDevice,
device: vk.VkDevice,
queue: vk.VkQueue,
queue_family_index: u32,

/// The Vulkan API version the host's physical device reports. Always
/// >= `MIN_API_VERSION` (if it were lower, `init` returns
/// `error.UnsupportedVulkanVersion`).
api_version: u32,

dispatch: Dispatch,

// ---- API ------------------------------------------------------------

/// Build a `Device` from the host's platform callbacks. Performs:
///   1. Pull host handles via the callbacks. Any null returns ->
///      `error.HostHandleMissing`.
///   2. Load the instance-level dispatch via `vkGetInstanceProcAddr`.
///   3. Verify `physicalDeviceProperties.apiVersion >= 1.3`.
///   4. Verify every entry in `REQUIRED_DEVICE_EXTENSIONS` is present
///      on the physical device.
///   5. Load the device-level dispatch via `vkGetDeviceProcAddr`.
///
/// On success the returned `Device` is ready for the renderer to
/// build pipelines / images / command buffers against. The host
/// retains ownership of `instance` / `device` / `queue` — `deinit`
/// is a no-op stub for symmetry.
pub fn init(
    alloc: Allocator,
    platform: apprt.embedded.Platform.Vulkan,
) (Error || Allocator.Error)!Device {
    // ---- 1. resolve host handles ---------------------------------
    const instance_handle = platform.instance(platform.userdata) orelse
        return error.HostHandleMissing;
    const physical_device_handle = platform.physical_device(platform.userdata) orelse
        return error.HostHandleMissing;
    const device_handle = platform.device(platform.userdata) orelse
        return error.HostHandleMissing;
    const queue_handle = platform.queue(platform.userdata) orelse
        return error.HostHandleMissing;

    const instance: vk.VkInstance = @ptrCast(instance_handle);
    const physical_device: vk.VkPhysicalDevice = @ptrCast(physical_device_handle);
    const device: vk.VkDevice = @ptrCast(device_handle);
    const queue: vk.VkQueue = @ptrCast(queue_handle);
    const queue_family_index = platform.queue_family_index(platform.userdata);

    // ---- 2. instance-level dispatch ------------------------------
    // The host's get_instance_proc_addr is our root entry point. We
    // resolve other functions via vkGetInstanceProcAddr (instance,
    // name); per the Vulkan spec, passing a non-null instance is
    // valid for any function that takes an instance, physical
    // device, device, or child object of any of these — i.e.
    // everything we care about.
    const get_instance_proc_addr_raw =
        platform.get_instance_proc_addr(
            platform.userdata,
            "vkGetInstanceProcAddr",
        ) orelse return error.HostHandleMissing;
    const get_instance_proc_addr: std.meta.Child(vk.PFN_vkGetInstanceProcAddr) =
        @ptrCast(@alignCast(get_instance_proc_addr_raw));

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
    const enumerate_device_extension_properties =
        try il.load(vk.PFN_vkEnumerateDeviceExtensionProperties, "vkEnumerateDeviceExtensionProperties");
    const get_device_proc_addr =
        try il.load(vk.PFN_vkGetDeviceProcAddr, "vkGetDeviceProcAddr");

    // ---- 3. version check ----------------------------------------
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

    // ---- 4. extension check --------------------------------------
    var ext_count: u32 = 0;
    _ = enumerate_device_extension_properties(physical_device, null, &ext_count, null);
    const exts = try alloc.alloc(vk.VkExtensionProperties, ext_count);
    defer alloc.free(exts);
    _ = enumerate_device_extension_properties(physical_device, null, &ext_count, exts.ptr);

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

    // ---- 5. device-level dispatch --------------------------------
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
    const allocate_descriptor_sets =
        try dl.load(vk.PFN_vkAllocateDescriptorSets, "vkAllocateDescriptorSets");
    const update_descriptor_sets =
        try dl.load(vk.PFN_vkUpdateDescriptorSets, "vkUpdateDescriptorSets");
    const cmd_bind_descriptor_sets =
        try dl.load(vk.PFN_vkCmdBindDescriptorSets, "vkCmdBindDescriptorSets");

    return .{
        .platform = platform,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family_index = queue_family_index,
        .api_version = props.apiVersion,
        .dispatch = .{
            .getPhysicalDeviceProperties = get_physical_device_properties,
            .getPhysicalDeviceMemoryProperties = get_physical_device_memory_properties,
            .getPhysicalDeviceFormatProperties = get_physical_device_format_properties,
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
/// renderer resources to make sure no command buffers are in flight.
pub fn waitIdle(self: *const Device) void {
    _ = self.dispatch.deviceWaitIdle(self.device);
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
    var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    self.dispatch.getPhysicalDeviceMemoryProperties(self.physical_device, &props);
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
