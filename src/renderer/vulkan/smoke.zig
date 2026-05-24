//! Runtime smoke test for the bottom half of the Vulkan renderer.
//!
//! Bootstraps a Vulkan instance + device through the standard
//! loader, wraps them in an `apprt.embedded.Platform.Vulkan`
//! callback set (the same shape libghostty receives from a real
//! apprt host like Qt RHI), and runs `Device` → `Texture` → `Target`
//! through their normal init paths.
//!
//! Skipped by default — gated on the `GHOSTTY_VULKAN_SMOKE` env var
//! so `zig build test` doesn't try to create real GPU resources on
//! every developer's machine (failure modes: no GPU, no Vulkan
//! loader, no extensions, headless CI...). To run it:
//!
//!   GHOSTTY_VULKAN_SMOKE=1 zig build test -Drenderer=vulkan \
//!     --test-filter "smoke" -Dapp-runtime=none
//!
//! What it verifies:
//!   1. `Device.init` resolves all required dispatch entries.
//!   2. Vulkan API version is >= 1.3.
//!   3. Required device extensions are present.
//!   4. `Texture.init` with data runs the staging-buffer →
//!      command-buffer upload pipeline end-to-end and lands the
//!      image in `SHADER_READ_ONLY_OPTIMAL`.
//!   5. `Target.init` builds an exportable VkImage and successfully
//!      extracts a non-negative dmabuf fd via `vkGetMemoryFdKHR`.
//!   6. Everything deinits cleanly (no validation errors on debug
//!      builds with VK_LAYER_KHRONOS_validation).

const std = @import("std");
const vk = @import("vulkan").c;
const apprt = @import("../../apprt.zig");

const Device = @import("Device.zig");
const Texture = @import("Texture.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.vulkan_smoke);

/// Minimal Vulkan host — builds a real VkInstance + VkPhysicalDevice +
/// VkDevice + VkQueue, then exposes them via callbacks shaped like
/// `apprt.embedded.Platform.Vulkan` for libghostty to consume.
const TestHost = struct {
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family_index: u32,

    pub const Error = error{
        NoVulkanLoader,
        NoSuitablePhysicalDevice,
        VulkanFailed,
    };

    fn init() Error!TestHost {
        // ---- instance --------------------------------------------
        const app_info: vk.VkApplicationInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "ghastty-vulkan-smoke",
            .applicationVersion = 1,
            .pEngineName = "ghastty",
            .engineVersion = 1,
            .apiVersion = vk.VK_API_VERSION_1_3,
        };
        const instance_info: vk.VkInstanceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };
        var instance: vk.VkInstance = undefined;
        {
            const r = vk.vkCreateInstance(&instance_info, null, &instance);
            if (r != vk.VK_SUCCESS) {
                log.err("vkCreateInstance failed: result={}", .{r});
                return error.NoVulkanLoader;
            }
        }
        errdefer vk.vkDestroyInstance(instance, null);

        // ---- physical device -------------------------------------
        var pd_count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(instance, &pd_count, null);
        if (pd_count == 0) return error.NoSuitablePhysicalDevice;
        var pds: [16]vk.VkPhysicalDevice = undefined;
        pd_count = @min(pd_count, pds.len);
        _ = vk.vkEnumeratePhysicalDevices(instance, &pd_count, &pds);

        // Pick the first one that supports Vulkan 1.3 + our extensions.
        const physical_device, const queue_family_index = picked: {
            for (pds[0..pd_count]) |pd| {
                var props: vk.VkPhysicalDeviceProperties = undefined;
                vk.vkGetPhysicalDeviceProperties(pd, &props);
                if (props.apiVersion < vk.VK_API_VERSION_1_3) continue;

                if (!hasRequiredExtensions(pd)) continue;
                if (findGraphicsQueueFamily(pd)) |qfi| {
                    break :picked .{ pd, qfi };
                }
            }
            return error.NoSuitablePhysicalDevice;
        };

        // ---- device + queue --------------------------------------
        const queue_priority: f32 = 1.0;
        const queue_info: vk.VkDeviceQueueCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family_index,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        const ext_names = [_][*:0]const u8{
            "VK_KHR_external_memory_fd",
            "VK_EXT_external_memory_dma_buf",
        };
        const device_info: vk.VkDeviceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = ext_names.len,
            .ppEnabledExtensionNames = &ext_names,
            .pEnabledFeatures = null,
        };
        var device: vk.VkDevice = undefined;
        {
            const r = vk.vkCreateDevice(physical_device, &device_info, null, &device);
            if (r != vk.VK_SUCCESS) {
                log.err("vkCreateDevice failed: result={}", .{r});
                return error.VulkanFailed;
            }
        }
        errdefer vk.vkDestroyDevice(device, null);

        var queue: vk.VkQueue = undefined;
        vk.vkGetDeviceQueue(device, queue_family_index, 0, &queue);

        return .{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue = queue,
            .queue_family_index = queue_family_index,
        };
    }

    fn deinit(self: *TestHost) void {
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }

    fn toPlatform(self: *TestHost) apprt.embedded.Platform.Vulkan {
        return .{
            .userdata = @ptrCast(self),
            .get_instance_proc_addr = cbGetInstanceProcAddr,
            .instance = cbInstance,
            .physical_device = cbPhysicalDevice,
            .device = cbDevice,
            .queue = cbQueue,
            .queue_family_index = cbQueueFamilyIndex,
            .present = cbPresent,
        };
    }

    // ---- C callbacks --------------------------------------------

    fn cbGetInstanceProcAddr(
        ud: ?*anyopaque,
        name: [*:0]const u8,
    ) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        const fp = vk.vkGetInstanceProcAddr(self.instance, name);
        // PFN_vkVoidFunction is `?*const fn () callconv(.c) void`;
        // we hand back as `?*anyopaque` (no const promise).
        return @constCast(@ptrCast(fp));
    }

    fn cbInstance(ud: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        return @ptrCast(self.instance);
    }

    fn cbPhysicalDevice(ud: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        return @ptrCast(self.physical_device);
    }

    fn cbDevice(ud: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        return @ptrCast(self.device);
    }

    fn cbQueue(ud: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        return @ptrCast(self.queue);
    }

    fn cbQueueFamilyIndex(ud: ?*anyopaque) callconv(.c) u32 {
        const self: *TestHost = @ptrCast(@alignCast(ud.?));
        return self.queue_family_index;
    }

    fn cbPresent(
        ud: ?*anyopaque,
        fd: i32,
        fourcc: u32,
        modifier: u64,
        width: u32,
        height: u32,
        stride: u32,
    ) callconv(.c) void {
        _ = ud;
        log.info(
            "present cb: fd={} fourcc=0x{x} mod=0x{x} {}x{} stride={}",
            .{ fd, fourcc, modifier, width, height, stride },
        );
    }

    // ---- helpers ------------------------------------------------

    fn hasRequiredExtensions(pd: vk.VkPhysicalDevice) bool {
        var n: u32 = 0;
        _ = vk.vkEnumerateDeviceExtensionProperties(pd, null, &n, null);
        if (n == 0) return false;
        var buf: [256]vk.VkExtensionProperties = undefined;
        n = @min(n, buf.len);
        _ = vk.vkEnumerateDeviceExtensionProperties(pd, null, &n, &buf);

        const required = [_][:0]const u8{
            "VK_KHR_external_memory_fd",
            "VK_EXT_external_memory_dma_buf",
        };
        for (required) |req| {
            var found = false;
            for (buf[0..n]) |e| {
                const name: [*:0]const u8 = @ptrCast(&e.extensionName);
                if (std.mem.eql(u8, std.mem.span(name), req)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn findGraphicsQueueFamily(pd: vk.VkPhysicalDevice) ?u32 {
        var n: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, null);
        if (n == 0) return null;
        var buf: [16]vk.VkQueueFamilyProperties = undefined;
        n = @min(n, buf.len);
        vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, &buf);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if ((buf[i].queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) return i;
        }
        return null;
    }
};

test "smoke" {
    // Skip unless explicitly enabled — creates real GPU resources
    // which we don't want in default `zig build test` runs.
    const env_map = std.process.getEnvMap(std.testing.allocator) catch
        return error.SkipZigTest;
    defer {
        var em = env_map;
        em.deinit();
    }
    if (env_map.get("GHOSTTY_VULKAN_SMOKE") == null) return error.SkipZigTest;

    var host = TestHost.init() catch |err| switch (err) {
        // No Vulkan / no suitable device on this machine — skip
        // rather than fail. Smoke tests should be optional.
        error.NoVulkanLoader,
        error.NoSuitablePhysicalDevice,
        => return error.SkipZigTest,
        else => return err,
    };
    defer host.deinit();

    const platform = host.toPlatform();

    // ---- 1. Device.init -----------------------------------------
    var device = try Device.init(std.testing.allocator, platform);
    defer device.deinit();

    std.debug.print(
        "\n  Device: Vulkan {}.{}.{}, queue_family={}\n",
        .{
            vk.VK_API_VERSION_MAJOR(device.api_version),
            vk.VK_API_VERSION_MINOR(device.api_version),
            vk.VK_API_VERSION_PATCH(device.api_version),
            device.queue_family_index,
        },
    );

    // ---- 2. Texture.init with upload ----------------------------
    // 4x4 RGBA test pattern — 64 bytes.
    const pixels = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };
    var tex = try Texture.init(
        .{
            .device = &device,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        },
        4,
        4,
        &pixels,
    );
    defer tex.deinit();

    try std.testing.expectEqual(
        @as(vk.VkImageLayout, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL),
        tex.layout,
    );
    std.debug.print(
        "  Texture upload: {}x{}, layout=SHADER_READ_ONLY_OPTIMAL\n",
        .{ tex.width, tex.height },
    );

    // ---- 3. Target.init with dmabuf export ----------------------
    var target = try Target.init(.{
        .device = &device,
        .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .width = 64,
        .height = 64,
    });
    defer target.deinit();

    try std.testing.expect(target.fd >= 0);
    try std.testing.expect(target.stride >= 64 * 4); // at least tightly packed
    try std.testing.expectEqual(@as(u64, 0), target.drm_modifier); // LINEAR

    std.debug.print(
        "  Target dmabuf: fd={} fourcc=0x{x} stride={} ({}x{})\n",
        .{ target.fd, target.drm_format, target.stride, target.width, target.height },
    );

    std.debug.print("\n  All Vulkan smoke checks passed.\n", .{});
}
