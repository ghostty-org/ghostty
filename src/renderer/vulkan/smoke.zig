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
const Pipeline = @import("Pipeline.zig");
const CommandPool = @import("CommandPool.zig");
const DescriptorPool = @import("DescriptorPool.zig");
const Sampler = @import("Sampler.zig");
const shaders = @import("shaders.zig");
const bufferpkg = @import("buffer.zig");

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

    // ---- 4. End-to-end render (compile shaders → pipeline →
    //         vkCmdBeginRendering → draw → readback → verify) -----
    try renderAndVerify(&device, &target);

    // ---- 5. Render a bigger image to a file for visual review --
    //
    // The pixel readback in step 4 already verifies correctness
    // numerically, but it's nice to be able to actually *see* what
    // the GPU drew. Render a 256x256 gradient and save as PPM (the
    // simplest image format — any viewer opens it: `xdg-open`,
    // `feh`, `eog`, `gimp`, etc.).
    try renderToFile(&device, "/tmp/ghastty-vulkan-smoke.ppm");

    // ---- 6. Textured-quad render to file ------------------------
    // Proves the descriptor-set lifecycle works end-to-end: create
    // a texture, upload data, allocate a descriptor set bound to
    // it + a sampler, render a quad sampling from it, save as PPM.
    try renderTexturedToFile(&device, "/tmp/ghastty-vulkan-smoke-textured.ppm");

    std.debug.print("\n  All Vulkan smoke checks passed.\n", .{});
    std.debug.print(
        "  Visual (gradient): /tmp/ghastty-vulkan-smoke.ppm\n",
        .{},
    );
    std.debug.print(
        "  Visual (textured): /tmp/ghastty-vulkan-smoke-textured.ppm\n",
        .{},
    );
}

/// The full GPU pipeline test: compile a tiny vertex+fragment shader
/// pair that draws a fullscreen triangle of solid color, set up a
/// pipeline, render into `target`, copy the result to a host-visible
/// buffer, and verify the readback pixel matches the expected color.
fn renderAndVerify(device: *const Device, target: *Target) !void {
    // Shaders: hard-coded GLSL strings. Vertex synthesizes a
    // fullscreen triangle from gl_VertexIndex (no vertex input);
    // fragment outputs a fixed RGBA. Keeps the test independent of
    // the renderer's actual shader set + descriptor / uniform infra.
    const vs_src: [:0]const u8 =
        \\#version 450
        \\void main() {
        \\    vec2 pos = vec2(
        \\        float((gl_VertexIndex << 1) & 2),
        \\        float(gl_VertexIndex & 2)
        \\    );
        \\    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
        \\}
    ;
    const fs_src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 frag_color;
        \\void main() {
        \\    // Distinct color: red=255 green=128 blue=64 alpha=255.
        \\    frag_color = vec4(1.0, 128.0 / 255.0, 64.0 / 255.0, 1.0);
        \\}
    ;

    var vs = try shaders.Module.init(device, vs_src, .vertex);
    defer vs.deinit();
    var fs = try shaders.Module.init(device, fs_src, .fragment);
    defer fs.deinit();

    // Pipeline: dynamic rendering, no vertex input, no descriptors.
    // Color attachment format must match the target's format.
    var pipeline = try Pipeline.init(.{
        .device = device,
        .vertex_module = vs.handle,
        .fragment_module = fs.handle,
        .vertex_input = null,
        .color_format = target.format,
        .blending_enabled = false,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    });
    defer pipeline.deinit();

    // Host-visible readback buffer sized to the target's dmabuf.
    // The target uses linear tiling, but copyImageToBuffer writes a
    // tightly-packed image, so the buffer size is just `width * height
    // * 4`.
    const readback_size: usize = @as(usize, target.width) * target.height * 4;
    var readback = try bufferpkg.Buffer(u8).init(
        .{
            .device = device,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        },
        readback_size,
    );
    defer readback.deinit();

    var pool = try CommandPool.init(device);
    defer pool.deinit();

    const session = try pool.beginOneShot();

    // Barrier: UNDEFINED → COLOR_ATTACHMENT_OPTIMAL
    {
        const barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = target.image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        device.dispatch.cmdPipelineBarrier(
            session.cb,
            vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            0, null,
            0, null,
            1, &barrier,
        );
    }

    // vkCmdBeginRendering — Vulkan 1.3 dynamic rendering, no
    // VkRenderPass object.
    {
        const clear_value: vk.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const color_attachment: vk.VkRenderingAttachmentInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = target.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = vk.VK_RESOLVE_MODE_NONE,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear_value,
        };
        const rendering_info: vk.VkRenderingInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = target.width, .height = target.height },
            },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment,
            .pDepthAttachment = null,
            .pStencilAttachment = null,
        };
        device.dispatch.cmdBeginRendering(session.cb, &rendering_info);
    }

    // Set dynamic state (we declared viewport + scissor dynamic in
    // Pipeline.zig).
    {
        const viewport: vk.VkViewport = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(target.width),
            .height = @floatFromInt(target.height),
            .minDepth = 0,
            .maxDepth = 1,
        };
        device.dispatch.cmdSetViewport(session.cb, 0, 1, &viewport);
        const scissor: vk.VkRect2D = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target.width, .height = target.height },
        };
        device.dispatch.cmdSetScissor(session.cb, 0, 1, &scissor);
    }

    // Bind pipeline + draw 3 vertices.
    device.dispatch.cmdBindPipeline(
        session.cb,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline.pipeline,
    );
    device.dispatch.cmdDraw(session.cb, 3, 1, 0, 0);

    device.dispatch.cmdEndRendering(session.cb);

    // Barrier: COLOR_ATTACHMENT → TRANSFER_SRC for the readback.
    {
        const barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = target.image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        device.dispatch.cmdPipelineBarrier(
            session.cb,
            vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0, null,
            0, null,
            1, &barrier,
        );
    }

    // Copy image → buffer.
    {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{
                .width = target.width,
                .height = target.height,
                .depth = 1,
            },
        };
        device.dispatch.cmdCopyImageToBuffer(
            session.cb,
            target.image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            readback.buffer,
            1,
            &region,
        );
    }

    try session.endAndSubmit();

    // Map + verify. The target uses VK_FORMAT_B8G8R8A8_UNORM, so the
    // bytes in memory are [B, G, R, A] per pixel.
    var mapped: ?*anyopaque = null;
    {
        const r = device.dispatch.mapMemory(
            device.device,
            readback.memory,
            0,
            readback_size,
            0,
            &mapped,
        );
        if (r != vk.VK_SUCCESS) {
            std.debug.print("vkMapMemory(readback) failed: result={}\n", .{r});
            return error.VulkanFailed;
        }
    }
    defer device.dispatch.unmapMemory(device.device, readback.memory);

    const pixels: [*]const u8 = @ptrCast(mapped.?);
    // Pixel (0,0): B=64, G=128, R=255, A=255 (matches the fragment
    // shader output). Allow ±1 to absorb any nearest-byte rounding.
    const b = pixels[0];
    const g = pixels[1];
    const r = pixels[2];
    const a = pixels[3];

    std.debug.print(
        "  Rendered pixel (0,0): BGRA=({},{},{},{}) expected≈(64,128,255,255)\n",
        .{ b, g, r, a },
    );
    try std.testing.expect(@abs(@as(i32, b) - 64) <= 1);
    try std.testing.expect(@abs(@as(i32, g) - 128) <= 1);
    try std.testing.expect(@abs(@as(i32, r) - 255) <= 1);
    try std.testing.expectEqual(@as(u8, 255), a);
}

/// Render a 256x256 gradient image and save it as a PPM file for
/// visual inspection. Same pipeline shape as `renderAndVerify` but
/// with a UV-driven fragment shader so the output has visible spatial
/// variation, and at a size you can actually look at.
fn renderToFile(device: *const Device, path: []const u8) !void {
    const width: u32 = 256;
    const height: u32 = 256;

    // A pretty gradient: R follows X, G follows Y, B is the inverse
    // diagonal, A is opaque. Gives an unambiguous "yes the GPU
    // sampled my fragment coordinates" image.
    const vs_src: [:0]const u8 =
        \\#version 450
        \\void main() {
        \\    vec2 pos = vec2(
        \\        float((gl_VertexIndex << 1) & 2),
        \\        float(gl_VertexIndex & 2)
        \\    );
        \\    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
        \\}
    ;
    const fs_src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec4 frag_color;
        \\layout(push_constant) uniform PC { vec2 size; } pc;
        \\void main() {
        \\    vec2 uv = gl_FragCoord.xy / pc.size;
        \\    frag_color = vec4(uv.x, uv.y, 1.0 - (uv.x + uv.y) * 0.5, 1.0);
        \\}
    ;

    var vs = try shaders.Module.init(device, vs_src, .vertex);
    defer vs.deinit();
    var fs = try shaders.Module.init(device, fs_src, .fragment);
    defer fs.deinit();

    const push_range: vk.VkPushConstantRange = .{
        .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf([2]f32),
    };
    var pipeline = try Pipeline.init(.{
        .device = device,
        .vertex_module = vs.handle,
        .fragment_module = fs.handle,
        .vertex_input = null,
        .push_constant_ranges = &[_]vk.VkPushConstantRange{push_range},
        .color_format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .blending_enabled = false,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    });
    defer pipeline.deinit();

    var target = try Target.init(.{
        .device = device,
        .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .width = width,
        .height = height,
    });
    defer target.deinit();

    const pixel_count: usize = @as(usize, width) * height * 4;
    var readback = try bufferpkg.Buffer(u8).init(
        .{
            .device = device,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        },
        pixel_count,
    );
    defer readback.deinit();

    var pool = try CommandPool.init(device);
    defer pool.deinit();
    const session = try pool.beginOneShot();

    // Barrier in.
    imageBarrier(
        device,
        session.cb,
        target.image,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    // Begin rendering.
    {
        const clear: vk.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const attach: vk.VkRenderingAttachmentInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = target.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = vk.VK_RESOLVE_MODE_NONE,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear,
        };
        const info: vk.VkRenderingInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attach,
            .pDepthAttachment = null,
            .pStencilAttachment = null,
        };
        device.dispatch.cmdBeginRendering(session.cb, &info);
    }
    {
        const vp: vk.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
        device.dispatch.cmdSetViewport(session.cb, 0, 1, &vp);
        const sc: vk.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
        device.dispatch.cmdSetScissor(session.cb, 0, 1, &sc);
    }
    device.dispatch.cmdBindPipeline(session.cb, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
    // Push the target size for UV normalization.
    const size_pc: [2]f32 = .{ @floatFromInt(width), @floatFromInt(height) };
    vk.vkCmdPushConstants(
        session.cb,
        pipeline.layout,
        vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf([2]f32),
        &size_pc,
    );
    device.dispatch.cmdDraw(session.cb, 3, 1, 0, 0);
    device.dispatch.cmdEndRendering(session.cb);

    // Barrier out → TRANSFER_SRC for the copy.
    imageBarrier(
        device,
        session.cb,
        target.image,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_ACCESS_TRANSFER_READ_BIT,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    );

    // Copy.
    {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        device.dispatch.cmdCopyImageToBuffer(
            session.cb,
            target.image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            readback.buffer,
            1,
            &region,
        );
    }

    try session.endAndSubmit();

    // Write PPM. Format: "P6\n<w> <h>\n255\n" + raw RGB bytes.
    var mapped: ?*anyopaque = null;
    if (device.dispatch.mapMemory(device.device, readback.memory, 0, pixel_count, 0, &mapped) != vk.VK_SUCCESS) {
        return error.VulkanFailed;
    }
    defer device.dispatch.unmapMemory(device.device, readback.memory);

    const bgra: [*]const u8 = @ptrCast(mapped.?);
    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    var buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P6\n{} {}\n255\n", .{ width, height });
    try file.writeAll(header);

    // Swizzle BGRA -> RGB into a stack buffer + flush per row.
    var row: [256 * 3]u8 = undefined;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const src = (y * @as(usize, width) + x) * 4;
            row[x * 3 + 0] = bgra[src + 2]; // R
            row[x * 3 + 1] = bgra[src + 1]; // G
            row[x * 3 + 2] = bgra[src + 0]; // B
        }
        try file.writeAll(row[0 .. @as(usize, width) * 3]);
    }
    std.debug.print("  Wrote {}x{} PPM to {s}\n", .{ width, height, path });
}

/// Render a quad sampling from a small uploaded checkerboard texture
/// — proves the descriptor-set + combined-image-sampler binding path
/// works end-to-end. The fragment shader samples the bound texture
/// at its fragment UV and writes the result to the color attachment.
fn renderTexturedToFile(device: *const Device, path: []const u8) !void {
    const out_w: u32 = 256;
    const out_h: u32 = 256;

    // Source texture: 8x8 RGBA checkerboard. Even cells red, odd cells cyan.
    const tex_size: u32 = 8;
    var checker: [tex_size * tex_size * 4]u8 = undefined;
    {
        var y: u32 = 0;
        while (y < tex_size) : (y += 1) {
            var x: u32 = 0;
            while (x < tex_size) : (x += 1) {
                const i = (y * tex_size + x) * 4;
                const odd = ((x + y) & 1) == 1;
                if (odd) {
                    checker[i + 0] = 0; // R
                    checker[i + 1] = 200; // G
                    checker[i + 2] = 200; // B
                } else {
                    checker[i + 0] = 220; // R
                    checker[i + 1] = 30; // G
                    checker[i + 2] = 30; // B
                }
                checker[i + 3] = 255;
            }
        }
    }

    var tex = try Texture.init(
        .{
            .device = device,
            .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
            .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT,
        },
        tex_size,
        tex_size,
        &checker,
    );
    defer tex.deinit();

    var sampler = try Sampler.init(.{
        .device = device,
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .repeat,
        .wrap_t = .repeat,
    });
    defer sampler.deinit();

    // Vertex shader: fullscreen triangle + pass UV.
    const vs_src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) out vec2 v_uv;
        \\void main() {
        \\    vec2 pos = vec2(
        \\        float((gl_VertexIndex << 1) & 2),
        \\        float(gl_VertexIndex & 2)
        \\    );
        \\    v_uv = pos;
        \\    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
        \\}
    ;
    // Fragment shader: sample the bound texture at UV * 4 so the
    // 8x8 checkerboard tiles 4x across the output.
    const fs_src: [:0]const u8 =
        \\#version 450
        \\layout(location = 0) in vec2 v_uv;
        \\layout(location = 0) out vec4 frag_color;
        \\layout(set = 0, binding = 0) uniform sampler2D tex;
        \\void main() {
        \\    frag_color = texture(tex, v_uv * 4.0);
        \\}
    ;

    var vs = try shaders.Module.init(device, vs_src, .vertex);
    defer vs.deinit();
    var fs = try shaders.Module.init(device, fs_src, .fragment);
    defer fs.deinit();

    // Descriptor set layout: one combined image sampler at binding 0.
    const layout_bindings = [_]vk.VkDescriptorSetLayoutBinding{.{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    }};
    const dsl_info: vk.VkDescriptorSetLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = layout_bindings.len,
        .pBindings = &layout_bindings,
    };
    var dsl: vk.VkDescriptorSetLayout = undefined;
    if (device.dispatch.createDescriptorSetLayout(device.device, &dsl_info, null, &dsl) != vk.VK_SUCCESS)
        return error.VulkanFailed;
    defer device.dispatch.destroyDescriptorSetLayout(device.device, dsl, null);

    // Descriptor pool: capacity for one combined-image-sampler descriptor.
    var pool = try DescriptorPool.init(.{
        .device = device,
        .max_sets = 1,
        .combined_image_samplers = 1,
    });
    defer pool.deinit();

    // Allocate and populate the descriptor set.
    const set = try pool.allocate(dsl);
    {
        const image_info: vk.VkDescriptorImageInfo = .{
            .sampler = sampler.sampler,
            .imageView = tex.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write: vk.VkWriteDescriptorSet = .{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        device.dispatch.updateDescriptorSets(device.device, 1, &write, 0, null);
    }

    // Pipeline with this descriptor set layout.
    const dsls = [_]vk.VkDescriptorSetLayout{dsl};
    var pipeline = try Pipeline.init(.{
        .device = device,
        .vertex_module = vs.handle,
        .fragment_module = fs.handle,
        .vertex_input = null,
        .descriptor_set_layouts = &dsls,
        .color_format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .blending_enabled = false,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    });
    defer pipeline.deinit();

    var target = try Target.init(.{
        .device = device,
        .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .width = out_w,
        .height = out_h,
    });
    defer target.deinit();

    const px: usize = @as(usize, out_w) * out_h * 4;
    var readback = try bufferpkg.Buffer(u8).init(
        .{
            .device = device,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        },
        px,
    );
    defer readback.deinit();

    var cb_pool = try CommandPool.init(device);
    defer cb_pool.deinit();
    const session = try cb_pool.beginOneShot();

    imageBarrier(
        device,
        session.cb,
        target.image,
        vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        0,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
    );

    {
        const clear: vk.VkClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
        const attach: vk.VkRenderingAttachmentInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .pNext = null,
            .imageView = target.view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .resolveMode = vk.VK_RESOLVE_MODE_NONE,
            .resolveImageView = null,
            .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear,
        };
        const info: vk.VkRenderingInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pNext = null,
            .flags = 0,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = out_w, .height = out_h } },
            .layerCount = 1,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attach,
            .pDepthAttachment = null,
            .pStencilAttachment = null,
        };
        device.dispatch.cmdBeginRendering(session.cb, &info);
    }
    {
        const vp: vk.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(out_w), .height = @floatFromInt(out_h), .minDepth = 0, .maxDepth = 1 };
        device.dispatch.cmdSetViewport(session.cb, 0, 1, &vp);
        const sc: vk.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = out_w, .height = out_h } };
        device.dispatch.cmdSetScissor(session.cb, 0, 1, &sc);
    }
    device.dispatch.cmdBindPipeline(session.cb, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline);
    var sets = [_]vk.VkDescriptorSet{set};
    device.dispatch.cmdBindDescriptorSets(
        session.cb,
        vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        pipeline.layout,
        0, // first set
        1, // set count
        &sets,
        0, // dynamic offset count
        null,
    );
    device.dispatch.cmdDraw(session.cb, 3, 1, 0, 0);
    device.dispatch.cmdEndRendering(session.cb);

    imageBarrier(
        device,
        session.cb,
        target.image,
        vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.VK_ACCESS_TRANSFER_READ_BIT,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
    );

    {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = out_w, .height = out_h, .depth = 1 },
        };
        device.dispatch.cmdCopyImageToBuffer(
            session.cb,
            target.image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            readback.buffer,
            1,
            &region,
        );
    }

    try session.endAndSubmit();

    // Map + write PPM.
    var mapped: ?*anyopaque = null;
    if (device.dispatch.mapMemory(device.device, readback.memory, 0, px, 0, &mapped) != vk.VK_SUCCESS)
        return error.VulkanFailed;
    defer device.dispatch.unmapMemory(device.device, readback.memory);

    const bgra: [*]const u8 = @ptrCast(mapped.?);
    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    var hdr_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&hdr_buf, "P6\n{} {}\n255\n", .{ out_w, out_h });
    try file.writeAll(header);

    var row: [256 * 3]u8 = undefined;
    var y: usize = 0;
    while (y < out_h) : (y += 1) {
        var x: usize = 0;
        while (x < out_w) : (x += 1) {
            const src = (y * @as(usize, out_w) + x) * 4;
            row[x * 3 + 0] = bgra[src + 2]; // R
            row[x * 3 + 1] = bgra[src + 1]; // G
            row[x * 3 + 2] = bgra[src + 0]; // B
        }
        try file.writeAll(row[0 .. @as(usize, out_w) * 3]);
    }
    std.debug.print("  Textured: wrote {}x{} PPM to {s}\n", .{ out_w, out_h, path });
}

fn imageBarrier(
    device: *const Device,
    cb: vk.VkCommandBuffer,
    image: vk.VkImage,
    old_layout: vk.VkImageLayout,
    new_layout: vk.VkImageLayout,
    src_access: vk.VkAccessFlags,
    dst_access: vk.VkAccessFlags,
    src_stage: vk.VkPipelineStageFlags,
    dst_stage: vk.VkPipelineStageFlags,
) void {
    const barrier: vk.VkImageMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    device.dispatch.cmdPipelineBarrier(
        cb,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}
