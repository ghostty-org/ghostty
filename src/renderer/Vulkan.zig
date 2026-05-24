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
pub const shaders = @import("vulkan/shaders.zig");

const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;

// ---- comptime contract --------------------------------------------------

/// Custom user shaders (`shadertoy.zig`) target GLSL — same as OpenGL.
pub const custom_shader_target: shadertoy.Target = .glsl;

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

/// Per-thread Vulkan device state. The renderer holds `*const Vulkan`
/// from `generic.zig` and so can't mutate fields on the value — same
/// constraint OpenGL works around with `threadlocal var gl_host`.
/// `Device` is host-shared across all surfaces in the process, and
/// each renderer runs on its own thread, so a per-thread slot is the
/// natural fit: `threadEnter` populates it, the rest of the renderer
/// reads through `devicePtr`.
threadlocal var device: ?Device = null;

/// Most recently presented target, in case `presentLastTarget` is
/// called between frames (resize / redraw). Threadlocal for the same
/// reason as `device`.
threadlocal var last_target: ?Target = null;

// ---- lifecycle ----------------------------------------------------------

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!Vulkan {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *Vulkan) void {
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
    if (device != null) return;

    switch (apprt.runtime) {
        else => return error.UnsupportedRuntime,
        apprt.embedded => switch (surface.platform) {
            .vulkan => |platform| {
                device = try Device.init(self.alloc, platform);
            },
            .opengl, .macos, .ios => return error.UnsupportedPlatform,
        },
    }
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
    return try shaders.Shaders.init(alloc, custom_shaders);
}

pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    const size = self.rt_surface.size;
    return .{ .width = size.width, .height = size.height };
}

pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    _ = self;
    // The renderer requests `initTarget(1, 1)` at FrameState.init and
    // resizes later — that's fine, the dmabuf is just very small.
    return try Target.init(.{
        .device = devicePtr(),
        .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
        .width = @intCast(width),
        .height = @intCast(height),
    });
}

pub fn present(self: *Vulkan, target: Target) !void {
    _ = self;
    _ = target;
    @panic("Vulkan.present: not yet implemented — the per-frame " ++
        "draw recording in `RenderPass.step` has to land first. " ++
        "See `qt-vulkan-renderer` branch follow-ups.");
}

pub fn presentLastTarget(self: *Vulkan) !void {
    if (last_target) |t| try self.present(t);
}

pub fn beginFrame(
    self: *const Vulkan,
    renderer: *rendererpkg.Renderer,
    target: *Target,
) !Frame {
    _ = self;
    _ = renderer;
    _ = target;
    @panic("Vulkan.beginFrame: not yet implemented — the per-surface " ++
        "command pool / command buffer / fence aren't wired in yet. " ++
        "See `qt-vulkan-renderer` branch follow-ups.");
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

pub fn bgBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn imageBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn bgImageBufferOptions(self: *const Vulkan) bufferpkg.Options {
    return self.instanceBufferOptions();
}

pub fn textureOptions(_: *const Vulkan) Texture.Options {
    return .{
        .device = devicePtr(),
        .format = vk.VK_FORMAT_R8G8B8A8_UNORM,
        .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT |
            vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
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
    std.testing.refAllDecls(@This());
}
