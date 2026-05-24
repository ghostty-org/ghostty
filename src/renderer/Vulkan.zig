//! Vulkan graphics API for libghostty's `GenericRenderer`.
//!
//! Status: this is the **build-unblocking** version. The comptime
//! contract `GenericRenderer(Vulkan)` requires is fully wired so
//! `-Drenderer=vulkan` compiles cleanly; the per-frame rendering
//! bodies (`beginFrame`, `present`, `presentLastTarget`, and the
//! `RenderPass.step` body recording draws) are `@panic` stubs that
//! land in follow-up commits alongside the integration smoke test
//! on real hardware.
//!
//! What does work today:
//!   - Module type contract resolves at comptime.
//!   - The `Renderer = GenericRenderer(Vulkan)` switch arm in
//!     `src/renderer.zig:42` goes live.
//!   - `init` / `deinit` succeed, all option getters return sensible
//!     defaults.
//!   - The submodule resource wrappers (`Device`, `Texture`, `Buffer`,
//!     `Sampler`, `Target`, `Pipeline`, `CommandPool`, `Frame`,
//!     `shaders.Module`) all work in isolation.
//!
//! What doesn't work yet:
//!   - The per-frame draw loop. The renderer's actual `beginFrame` ↔
//!     `complete` sequence + `RenderPass.step` body don't record
//!     real commands yet. Calling them at runtime hits an explicit
//!     `@panic` with a pointer to the follow-up.
//!   - Frame target presentation: `Vulkan.initTarget` exists but
//!     the device handoff between `init` (per-surface) and
//!     `initTarget` (per-frame) isn't wired up.
//!
//! Approach for the follow-up: a runtime smoke test that
//! bootstraps Vulkan through the standard loader, constructs each
//! resource wrapper in turn against real hardware, validates the
//! dmabuf fd from `Target` is importable as an external `VkImage`
//! by a second test consumer. Once that passes, we know the bottom
//! half of the renderer is correct end-to-end and we can wire the
//! actual draw path through `Vulkan.zig` without flying blind.
//!
//! Submodules:
//!   - `vulkan/Device.zig` — host-handle wrapper, dispatch table.
//!   - `vulkan/Sampler.zig` — VkSampler.
//!   - `vulkan/Texture.zig` — VkImage + memory + view + staging upload.
//!   - `vulkan/Target.zig` — dmabuf-exportable render target.
//!   - `vulkan/buffer.zig` — Buffer(T) host-coherent.
//!   - `vulkan/CommandPool.zig` — VkCommandPool + one-shot helper.
//!   - `vulkan/Pipeline.zig` — VkPipeline + layout (dynamic rendering).
//!   - `vulkan/RenderPass.zig` — pass + step recording (currently stub).
//!   - `vulkan/Frame.zig` — per-draw context (fence-paced).
//!   - `vulkan/shaders.zig` — GLSL→SPIR-V→VkShaderModule.

pub const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan").c;

const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

pub const GraphicsAPI = Vulkan;
pub const Device = @import("vulkan/Device.zig");
pub const Sampler = @import("vulkan/Sampler.zig");
pub const Texture = @import("vulkan/Texture.zig");
pub const Target = @import("vulkan/Target.zig");
pub const CommandPool = @import("vulkan/CommandPool.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Frame = @import("vulkan/Frame.zig");
pub const DescriptorPool = @import("vulkan/DescriptorPool.zig");
pub const shaders = @import("vulkan/shaders.zig");

const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;

// ---- comptime contract --------------------------------------------------

/// Custom user shaders (`shadertoy.zig`) target GLSL — same as OpenGL.
pub const custom_shader_target: shadertoy.Target = .glsl;

/// Custom shaders are not yet supported on the Vulkan backend. The
/// renderer's first pass draws into `CustomShaderState.back_texture`
/// when custom shaders are configured, and a second "post" pass is
/// expected to composite back_texture → frame.target through the
/// user's shader. We haven't built that second pass for Vulkan yet,
/// so enabling custom shaders here would leave `frame.target` empty
/// and the window blank. Until the post pipeline lands, the generic
/// renderer skips loading custom shaders for Vulkan and warns once.
pub const supports_custom_shaders: bool = false;

/// Vulkan's clip-space Y axis points down (unlike OpenGL).
pub const custom_shader_y_is_down = true;

/// Single-buffered for v1; fence-paced submit-then-wait means there's
/// only ever one frame in flight.
pub const swap_chain_count = 1;

const log = std.log.scoped(.vulkan);

// ---- per-surface state --------------------------------------------------

alloc: Allocator,
blending: configpkg.Config.AlphaBlending,
rt_surface: *apprt.Surface,

/// Process-wide Vulkan device. The host owns one VkDevice shared
/// across every surface, so we mirror that as a single global slot
/// (not threadlocal — the renderer thread is distinct from the main
/// thread that constructs the surface, and threadlocal doesn't
/// survive that boundary).
///
/// Initialized in `Vulkan.init` on the surface-construction thread;
/// read by every other thread via `devicePtr` after that. The renderer
/// holds `*const Vulkan` from `generic.zig` so we can't mutate fields
/// on the value — same reason OpenGL uses a `threadlocal var gl_host`
/// (though OpenGL gets away with threadlocal because the OpenGL
/// platform callbacks are read on the same thread that set them).
var device: ?Device = null;

/// Most recently presented target, in case `presentLastTarget` is
/// called between frames (resize / redraw). Threadlocal for the same
/// reason as `device`.
threadlocal var last_target: ?Target = null;

/// Per-surface (per-thread) command pool used for the frame's
/// command buffer. Lazily created in `beginFrame` on the first call;
/// destroyed in `deinit`.
threadlocal var frame_pool: ?CommandPool = null;

/// The single command buffer allocated from `frame_pool` and reused
/// across frames. `vkResetCommandBuffer` is called at the start of
/// each `beginFrame` to clear prior recording.
threadlocal var frame_cb: vk.VkCommandBuffer = null;

/// Fence signaled when each frame's submit completes. We wait on it
/// in `Frame.complete` before handing the target dmabuf to the host.
threadlocal var frame_fence: vk.VkFence = null;

// ---- lifecycle ----------------------------------------------------------

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    // Vulkan needs the device populated before the renderer's
    // `FrameState.init` starts asking for buffer/texture options.
    // Process-wide (not threadlocal): the renderer thread is
    // distinct from the main thread that constructs the surface.
    if (device == null) {
        switch (apprt.runtime) {
            else => return error.UnsupportedRuntime,
            apprt.embedded => switch (opts.rt_surface.platform) {
                .vulkan => |platform| {
                    device = try Device.init(alloc, platform);
                    log.info(
                        "Vulkan device ready (api=0x{x})",
                        .{device.?.api_version},
                    );
                },
                .opengl, .macos, .ios => return error.UnsupportedPlatform,
            },
        }
    }
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *Vulkan) void {
    // Tear down per-frame state in the right order: wait for any
    // in-flight submit, then destroy fence, free CB, destroy pool.
    if (device) |*d| {
        d.waitIdle();
        if (frame_fence != null) {
            d.dispatch.destroyFence(d.device, frame_fence, null);
            frame_fence = null;
        }
        if (frame_pool != null and frame_cb != null) {
            d.dispatch.freeCommandBuffers(d.device, frame_pool.?.pool, 1, &frame_cb);
            frame_cb = null;
        }
        if (frame_pool) |*p| {
            p.deinit();
            frame_pool = null;
        }
    }
    if (last_target) |*t| t.deinit();
    last_target = null;
    if (device) |*d| d.deinit();
    device = null;
    self.* = undefined;
}

/// Early per-surface setup. Stub — Vulkan needs nothing here because
/// the host hasn't finished installing the platform callbacks yet.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
}

/// Main-thread setup just before the renderer thread spins up. This is
/// where we have valid platform callbacks, so this is where the
/// `Device` lives.
pub fn finalizeSurfaceInit(self: *const Vulkan, surface: *apprt.Surface) !void {
    // The renderer holds a `*const Vulkan`, so we can't actually
    // mutate self here. The renderer threads its own pointer to us
    // via opts, so this is a no-op for now — the device construction
    // moves into `threadEnter` where `self: *Vulkan`.
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const Vulkan, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
    // Device is brought up in `init` (the renderer's FrameState init
    // path calls options getters before threadEnter, and our options
    // need the device — so it has to be ready earlier than OpenGL
    // wants). Nothing to do here; left in place so
    // `@hasDecl(GraphicsAPI, "threadEnter")` keeps returning true in
    // `generic.zig`.
}

pub fn threadExit(self: *const Vulkan) void {
    _ = self;
    if (device) |*d| {
        d.waitIdle();
    }
}

pub fn displayRealized(self: *Vulkan) void {
    _ = self;
}

pub fn displayUnrealized(self: *Vulkan) void {
    _ = self;
}

pub fn drawFrameStart(self: *Vulkan) void {
    _ = self;
}

pub fn drawFrameEnd(self: *Vulkan) void {
    _ = self;
}

pub fn initShaders(
    self: *const Vulkan,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    return try shaders.Shaders.init(alloc, devicePtr(), custom_shaders);
}

pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    _ = self;
    // SRGB format so the hardware gamma-encodes the linear premultiplied
    // shader output at framebuffer-write time. The renderer's shaders
    // produce linear premultiplied alpha; without an sRGB format the
    // bytes in memory would be linear and Qt (which expects sRGB
    // premultiplied) would render them as if they were already gamma
    // encoded — colors would look way too dark. The DRM fourcc the
    // host sees is still ARGB8888; SRGB encoding is a Vulkan-side
    // concern only.
    return try Target.init(.{
        .device = devicePtr(),
        .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
        .width = @intCast(width),
        .height = @intCast(height),
    });
}

pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    const size = self.rt_surface.size;
    return .{ .width = size.width, .height = size.height };
}

pub fn present(self: *Vulkan, target: Target) !void {
    _ = self;
    // The target is already populated by the time we get here:
    // `Frame.complete` ended the command buffer, submitted with the
    // fence, and waited for the GPU to finish before returning. So
    // the dmabuf fd is safe to hand off.
    target.present();
    // Stash for `presentLastTarget`. We copy by value — `Target`'s
    // handles are POD pointers/ids, so a value copy is fine and the
    // original `Target` ownership stays with the caller.
    last_target = target;
}

pub fn presentLastTarget(self: *Vulkan) !void {
    if (last_target) |t| try self.present(t);
}

pub fn beginFrame(
    self: *const Vulkan,
    renderer: *rendererpkg.Renderer,
    target: *Target,
) !Frame {
    const dev = devicePtr();

    // Lazy per-thread resource init. The first call to `beginFrame`
    // on a renderer thread sets up the command pool + buffer + fence
    // that get reused for every subsequent frame.
    if (frame_pool == null) {
        frame_pool = try CommandPool.init(dev);
        const alloc_info: vk.VkCommandBufferAllocateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = frame_pool.?.pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (dev.dispatch.allocateCommandBuffers(dev.device, &alloc_info, &frame_cb) != vk.VK_SUCCESS)
            return error.VulkanFailed;

        const fence_info: vk.VkFenceCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            // Created signaled so the very first `Frame.complete`
            // doesn't try to reset an unsignaled fence.
            .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        if (dev.dispatch.createFence(dev.device, &fence_info, null, &frame_fence) != vk.VK_SUCCESS)
            return error.VulkanFailed;
    }

    _ = self;
    // Reset the command buffer + fence so this frame starts clean.
    if (dev.dispatch.resetCommandBuffer(frame_cb, 0) != vk.VK_SUCCESS)
        return error.VulkanFailed;
    if (dev.dispatch.resetFences(dev.device, 1, &frame_fence) != vk.VK_SUCCESS)
        return error.VulkanFailed;

    return try Frame.begin(
        .{ .cb = frame_cb, .fence = frame_fence },
        dev,
        renderer,
        target,
    );
}

// ---- buffer / texture / sampler option getters --------------------------
//
// `GenericRenderer` calls these without knowing or caring about Vulkan
// specifics; the returned `Options` structs are what each backend's
// resource wrapper expects to be passed back to its `init`. The
// Vulkan-flavored ones embed a `*const Device` reference plus
// backend-specific usage flags.

inline fn devicePtr() *const Device {
    // Indirected through a getter so future refactors (e.g. allocating
    // `Device` on the heap) don't ripple. Today the device lives in
    // a threadlocal slot, populated by `threadEnter`.
    return &(device orelse {
        // `Options` getters can be called from `FrameState.init` which
        // runs before `threadEnter`. Hitting this means the renderer
        // is asking for resource options too early — should never
        // reach this in practice once the full bring-up lands.
        @panic("Vulkan.devicePtr: device not yet initialized");
    });
}

/// Default buffer options. Vulkan needs an explicit usage bitmask;
/// callers that want a specific kind override via the per-kind getters
/// below. (Self is unused — the device comes from the threadlocal.)
pub fn bufferOptions(_: *const Vulkan) bufferpkg.Options {
    return .{
        .device = devicePtr(),
        .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    };
}

pub fn instanceBufferOptions(_: *const Vulkan) bufferpkg.Options {
    return .{
        .device = devicePtr(),
        .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    };
}

pub fn uniformBufferOptions(_: *const Vulkan) bufferpkg.Options {
    return .{
        .device = devicePtr(),
        .usage = vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    };
}

pub fn fgBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn bgBufferOptions(_: *const Vulkan) bufferpkg.Options {
    // The bg cells buffer is consumed as a STORAGE BUFFER by the
    // cell_bg fragment shader (binding `bg_cells`) and the cell_text
    // vertex shader (same binding). The OpenGL backend doesn't
    // distinguish — every buffer is reusable across roles — but
    // Vulkan validates usage flags at descriptor-write time.
    return .{
        .device = devicePtr(),
        .usage = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
    };
}

pub fn imageBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn bgImageBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn textureOptions(_: *const Vulkan) Texture.Options {
    // The renderer uses `textureOptions()`-shaped textures both for
    // glyph atlases (sampled-only) AND for the custom-shader
    // back_texture (which is BOTH sampled AND a render target).
    // We hand back the wider usage set so both work. The format
    // matches the renderer's `initTarget` choice
    // (`B8G8R8A8_SRGB`) so a render → sample → render chain
    // through the custom-shader pass keeps the same color format.
    return .{
        .device = devicePtr(),
        .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
        .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT |
            vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
            vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    };
}

pub fn samplerOptions(_: *const Vulkan) Sampler.Options {
    return .{
        .device = devicePtr(),
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format hint matching `opengl/OpenGL.zig`'s `ImageTextureFormat`.
pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,

    fn toVk(self: ImageTextureFormat) vk.VkFormat {
        return switch (self) {
            .gray => vk.VK_FORMAT_R8_UNORM,
            .rgba => vk.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra => vk.VK_FORMAT_B8G8R8A8_UNORM,
        };
    }
};

pub fn imageTextureOptions(
    _: *const Vulkan,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = srgb;
    return .{
        .device = devicePtr(),
        .format = format.toVk(),
        .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT |
            vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    };
}

pub fn initAtlasTexture(
    _: *const Vulkan,
    atlas: *const font.Atlas,
) !Texture {
    const fmt: vk.VkFormat = switch (atlas.format) {
        .grayscale => vk.VK_FORMAT_R8_UNORM,
        .bgra => vk.VK_FORMAT_B8G8R8A8_UNORM,
        else => return error.UnsupportedAtlasFormat,
    };
    return try Texture.init(
        .{
            .device = devicePtr(),
            .format = fmt,
            .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT |
                vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

test {
    // Don't `refAllDecls` here — some methods (like `surfaceSize`)
    // @compileError when `apprt.runtime` is `.none`, which is the
    // runtime used by `zig build test`. Force-resolving every decl
    // would trip those errors before tests can run. The OpenGL and
    // Metal backends sidestep this by not having a `test {}` block
    // at all.
    //
    // We DO want to pull in the smoke test (gated on
    // `GHOSTTY_VULKAN_SMOKE` env var so it doesn't run resource-
    // creating tests by default).
    _ = @import("vulkan/smoke.zig");
}
