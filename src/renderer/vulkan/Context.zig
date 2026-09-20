const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;

const log = std.log.scoped(.vulkan);

instance: c.VkInstance,
physical_device: c.VkPhysicalDevice,
device: c.VkDevice,
queue: c.VkQueue,
queue_family: u32,
command_pool: c.VkCommandPool,
descriptor_set_layout: c.VkDescriptorSetLayout,
pipeline_layout: c.VkPipelineLayout,
memory_properties: c.VkPhysicalDeviceMemoryProperties,
supports_dmabuf: bool,
get_memory_fd: c.PFN_vkGetMemoryFdKHR,
get_image_drm_format_modifier_properties: c.PFN_vkGetImageDrmFormatModifierPropertiesEXT,
alloc: std.mem.Allocator,
deferred_buffers: ?*DeferredBuffer = null,

pub const DeferredBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    next: ?*DeferredBuffer = null,
};

pub fn init(alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    var app_info = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "Ghostty";
    app_info.applicationVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0);
    app_info.pEngineName = "Ghostty";
    app_info.engineVersion = c.VK_MAKE_API_VERSION(0, 1, 0, 0);
    app_info.apiVersion = c.VK_API_VERSION_1_3;

    var instance_info = std.mem.zeroes(c.VkInstanceCreateInfo);
    instance_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.pApplicationInfo = &app_info;

    var instance: c.VkInstance = null;
    try result(c.vkCreateInstance(&instance_info, null, &instance));
    errdefer c.vkDestroyInstance(instance, null);

    var physical_count: u32 = 0;
    try result(c.vkEnumeratePhysicalDevices(instance, &physical_count, null));
    if (physical_count == 0) return error.NoVulkanDevice;

    const physical_devices = try alloc.alloc(c.VkPhysicalDevice, physical_count);
    defer alloc.free(physical_devices);
    try result(c.vkEnumeratePhysicalDevices(instance, &physical_count, physical_devices.ptr));

    var physical_device: c.VkPhysicalDevice = null;
    var queue_family: u32 = 0;
    var fallback_device: c.VkPhysicalDevice = null;
    var fallback_family: u32 = 0;

    for (physical_devices) |candidate| {
        const family = findGraphicsQueue(alloc, candidate) catch continue;
        var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        c.vkGetPhysicalDeviceProperties(candidate, &props);

        if (fallback_device == null) {
            fallback_device = candidate;
            fallback_family = family;
        }
        if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            physical_device = candidate;
            queue_family = family;
            break;
        }
    }
    if (physical_device == null) {
        physical_device = fallback_device;
        queue_family = fallback_family;
    }
    if (physical_device == null) return error.NoGraphicsQueue;

    var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    c.vkGetPhysicalDeviceProperties(physical_device, &props);
    log.info("device={s} api={d}.{d}.{d}", .{
        std.mem.sliceTo(&props.deviceName, 0),
        c.VK_API_VERSION_MAJOR(props.apiVersion),
        c.VK_API_VERSION_MINOR(props.apiVersion),
        c.VK_API_VERSION_PATCH(props.apiVersion),
    });
    if (props.apiVersion < c.VK_API_VERSION_1_3) return error.VulkanVersionTooOld;

    const extension_support = try queryDeviceExtensions(alloc, physical_device);
    var supports_dmabuf = extension_support.external_memory_fd and
        extension_support.external_memory_dma_buf and
        extension_support.image_drm_format_modifier;

    const priority: f32 = 1.0;
    var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;

    var dynamic_rendering = std.mem.zeroes(c.VkPhysicalDeviceDynamicRenderingFeatures);
    dynamic_rendering.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES;
    dynamic_rendering.dynamicRendering = c.VK_TRUE;

    const dmabuf_extensions = [_][*:0]const u8{
        c.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        c.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        c.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    };

    var device_info = std.mem.zeroes(c.VkDeviceCreateInfo);
    device_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.pNext = &dynamic_rendering;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    if (supports_dmabuf) {
        device_info.enabledExtensionCount = dmabuf_extensions.len;
        device_info.ppEnabledExtensionNames = &dmabuf_extensions;
    }

    var device: c.VkDevice = null;
    try result(c.vkCreateDevice(physical_device, &device_info, null, &device));
    errdefer c.vkDestroyDevice(device, null);

    var queue: c.VkQueue = null;
    c.vkGetDeviceQueue(device, queue_family, 0, &queue);

    const get_memory_fd: c.PFN_vkGetMemoryFdKHR = if (supports_dmabuf)
        @ptrCast(c.vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR"))
    else
        null;
    const get_image_drm_format_modifier_properties: c.PFN_vkGetImageDrmFormatModifierPropertiesEXT = if (supports_dmabuf)
        @ptrCast(c.vkGetDeviceProcAddr(device, "vkGetImageDrmFormatModifierPropertiesEXT"))
    else
        null;
    if (supports_dmabuf and (get_memory_fd == null or get_image_drm_format_modifier_properties == null)) {
        log.warn("DMA-BUF extensions are present but entry points are unavailable; using memory presentation", .{});
        supports_dmabuf = false;
    }
    log.info("DMA-BUF export={}", .{supports_dmabuf});

    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = queue_family;

    var command_pool: c.VkCommandPool = null;
    try result(c.vkCreateCommandPool(device, &pool_info, null, &command_pool));
    errdefer c.vkDestroyCommandPool(device, command_pool, null);

    const bindings = [_]c.VkDescriptorSetLayoutBinding{
        descriptorBinding(0, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, c.VK_SHADER_STAGE_ALL_GRAPHICS),
        descriptorBinding(1, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, c.VK_SHADER_STAGE_ALL_GRAPHICS),
        descriptorBinding(2, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, c.VK_SHADER_STAGE_ALL_GRAPHICS),
        descriptorBinding(3, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, c.VK_SHADER_STAGE_ALL_GRAPHICS),
    };
    var set_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    set_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    set_info.bindingCount = bindings.len;
    set_info.pBindings = &bindings;

    var descriptor_set_layout: c.VkDescriptorSetLayout = null;
    try result(c.vkCreateDescriptorSetLayout(device, &set_info, null, &descriptor_set_layout));
    errdefer c.vkDestroyDescriptorSetLayout(device, descriptor_set_layout, null);

    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &descriptor_set_layout;

    var pipeline_layout: c.VkPipelineLayout = null;
    try result(c.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout));
    errdefer c.vkDestroyPipelineLayout(device, pipeline_layout, null);

    var memory_properties = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);

    self.* = .{
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family = queue_family,
        .command_pool = command_pool,
        .descriptor_set_layout = descriptor_set_layout,
        .pipeline_layout = pipeline_layout,
        .memory_properties = memory_properties,
        .supports_dmabuf = supports_dmabuf,
        .get_memory_fd = get_memory_fd,
        .get_image_drm_format_modifier_properties = get_image_drm_format_modifier_properties,
        .alloc = alloc,
    };
    return self;
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    _ = c.vkDeviceWaitIdle(self.device);
    self.collectDeferredBuffers();
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    c.vkDestroyCommandPool(self.device, self.command_pool, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroyInstance(self.instance, null);
    alloc.destroy(self);
}

pub fn memoryType(self: *const Self, bits: u32, flags: c.VkMemoryPropertyFlags) !u32 {
    var i: u32 = 0;
    while (i < self.memory_properties.memoryTypeCount) : (i += 1) {
        if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and
            (self.memory_properties.memoryTypes[i].propertyFlags & flags) == flags)
        {
            return i;
        }
    }
    return error.NoSuitableMemoryType;
}

pub fn beginCommands(self: *Self) !c.VkCommandBuffer {
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandPool = self.command_pool;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;

    var command_buffer: c.VkCommandBuffer = null;
    try result(c.vkAllocateCommandBuffers(self.device, &alloc_info, &command_buffer));
    errdefer c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try result(c.vkBeginCommandBuffer(command_buffer, &begin_info));
    return command_buffer;
}

pub fn submitCommands(self: *Self, command_buffer: c.VkCommandBuffer) !void {
    errdefer c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);
    try result(c.vkEndCommandBuffer(command_buffer));

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    var fence: c.VkFence = null;
    try result(c.vkCreateFence(self.device, &fence_info, null, &fence));
    defer c.vkDestroyFence(self.device, fence, null);

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &command_buffer;
    try result(c.vkQueueSubmit(self.queue, 1, &submit_info, fence));
    try result(c.vkWaitForFences(self.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
    c.vkFreeCommandBuffers(self.device, self.command_pool, 1, &command_buffer);
    self.collectDeferredBuffers();
}

pub fn deferBuffer(self: *Self, node: *DeferredBuffer) void {
    node.next = self.deferred_buffers;
    self.deferred_buffers = node;
}

fn collectDeferredBuffers(self: *Self) void {
    var current = self.deferred_buffers;
    self.deferred_buffers = null;
    while (current) |node| {
        current = node.next;
        c.vkDestroyBuffer(self.device, node.buffer, null);
        c.vkFreeMemory(self.device, node.memory, null);
        self.alloc.destroy(node);
    }
}

fn descriptorBinding(binding: u32, descriptor_type: c.VkDescriptorType, stages: c.VkShaderStageFlags) c.VkDescriptorSetLayoutBinding {
    var value = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
    value.binding = binding;
    value.descriptorType = descriptor_type;
    value.descriptorCount = 1;
    value.stageFlags = stages;
    return value;
}

fn findGraphicsQueue(alloc: std.mem.Allocator, device: c.VkPhysicalDevice) !u32 {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0) return error.NoGraphicsQueue;
    const props = try alloc.alloc(c.VkQueueFamilyProperties, count);
    defer alloc.free(props);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, props.ptr);
    for (props, 0..) |prop, i| {
        if ((prop.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) return @intCast(i);
    }
    return error.NoGraphicsQueue;
}

const ExtensionSupport = struct {
    external_memory_fd: bool = false,
    external_memory_dma_buf: bool = false,
    image_drm_format_modifier: bool = false,
};

fn queryDeviceExtensions(alloc: std.mem.Allocator, device: c.VkPhysicalDevice) !ExtensionSupport {
    var count: u32 = 0;
    try result(c.vkEnumerateDeviceExtensionProperties(device, null, &count, null));
    const props = try alloc.alloc(c.VkExtensionProperties, count);
    defer alloc.free(props);
    try result(c.vkEnumerateDeviceExtensionProperties(device, null, &count, props.ptr));

    var support: ExtensionSupport = .{};
    for (props) |prop| {
        const name = std.mem.sliceTo(&prop.extensionName, 0);
        if (std.mem.eql(u8, name, c.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)) support.external_memory_fd = true;
        if (std.mem.eql(u8, name, c.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME)) support.external_memory_dma_buf = true;
        if (std.mem.eql(u8, name, c.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME)) support.image_drm_format_modifier = true;
    }
    return support;
}

pub fn result(value: c.VkResult) !void {
    if (value != c.VK_SUCCESS) {
        log.warn("Vulkan call failed result={d}", .{value});
        return error.VulkanFailed;
    }
}
