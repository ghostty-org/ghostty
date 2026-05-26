//! Vulkan graphics API for libghostty's `GenericRenderer`. Active
//! on `-Drenderer=vulkan` builds; the host (e.g. the Qt frontend)
//! supplies a VkInstance / VkDevice / VkQueue via the
//! `ghostty_platform_vulkan_s` C ABI, libghostty drives all
//! pipeline / image / command-buffer work against those handles,
//! and rendered frames go back to the host as dmabuf fds for
//! zero-copy compositing.
//!
//! Per-frame model: fence-paced submit-then-wait (one frame in
//! flight), `Target` is the dmabuf-exportable render image,
//! `Frame.complete` waits on the fence before handing the fd to
//! the platform `present` callback.
//!
//! Submodules — pure Vulkan-API wrappers live in `pkg/vulkan/`
//! (mirror of `pkg/opengl/`); renderer-policy modules live alongside
//! this file under `vulkan/`.
//!
//! In `pkg/vulkan/` (re-exported from this file as
//! `Vulkan.{Device,Sampler,CommandPool,DescriptorPool}`):
//!   - `Device.zig`        — host-handle wrapper + dispatch table.
//!   - `Sampler.zig`       — VkSampler.
//!   - `CommandPool.zig`   — VkCommandPool + one-shot helper.
//!   - `DescriptorPool.zig`— per-frame descriptor pool.
//!
//! In `src/renderer/vulkan/`:
//!   - `Texture.zig`      — VkImage + memory + view + staging upload.
//!   - `Target.zig`       — dmabuf-exportable render target
//!                           (direct or legacy_copy mode).
//!   - `buffer.zig`       — Buffer(T) host-coherent.
//!   - `buffer_pool.zig`  — cross-frame VkBuffer recycle pool
//!                           (per-thread pending, shared ready).
//!   - `ThreadState.zig`  — per-renderer-thread frame fence /
//!                           command buffer / step pool / last-target.
//!   - `Pipeline.zig`     — VkPipeline + layout (dynamic rendering).
//!   - `RenderPass.zig`   — dynamic-rendering pass + step recorder.
//!   - `Frame.zig`        — per-draw context (fence-paced).
//!   - `shaders.zig`      — GLSL→SPIR-V→VkShaderModule + the
//!                           OpenGL-GLSL → Vulkan-GLSL rewriter.

pub const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vulkan = @import("vulkan");
const vk = vulkan.c;

const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");

pub const GraphicsAPI = Vulkan;
// Device-dispatch primitives live in `pkg/vulkan/` so they can be
// reused by anything that needs a typed Vulkan binding (mirrors how
// `pkg/opengl/` houses Buffer/Program/Texture/etc.). The renderer
// re-exports them from this top-level so call sites continue to write
// `Vulkan.Device`, `Vulkan.Sampler`, etc.
pub const Device = vulkan.Device;
pub const Sampler = vulkan.Sampler;
pub const CommandPool = vulkan.CommandPool;
pub const DescriptorPool = vulkan.DescriptorPool;

// Renderer-policy primitives stay in `src/renderer/vulkan/` (dmabuf
// export, our pipeline + render-pass wiring, frame fence pacing, the
// GLSL→SPIR-V loader).
pub const Texture = @import("vulkan/Texture.zig");
pub const Target = @import("vulkan/Target.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Frame = @import("vulkan/Frame.zig");
pub const shaders = @import("vulkan/shaders.zig");

const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;

// ---- comptime contract --------------------------------------------------

/// Custom user shaders compile to SPIR-V directly — skip the
/// GLSL → SPIR-V → GLSL roundtrip that `.glsl` would do. The
/// roundtrip exists for backends that consume GLSL (OpenGL, Metal
/// via MSL), but Vulkan ingests SPIR-V natively and we already have
/// a glslang shim for the renderer's built-in shaders. Bypassing
/// the roundtrip halves the per-shader compile cost AND avoids the
/// spirv-cross-emitted main() losing the upstream `gl_FragCoord.xy`
/// pattern we hook for the Y-flip fix.
pub const custom_shader_target: shadertoy.Target = .spv;

/// Custom shaders ARE now supported on the Vulkan backend.
/// `shaders.Shaders.init` builds one post pipeline per user shader
/// (UBO at set 0 binding 1, iChannel0 sampler at set 1 binding 0,
/// matching `shadertoy_prefix.glsl` after `vulkanizeGlsl` rewrites
/// the layouts). The renderer's post pass at the end of `drawFrame`
/// chains them — first pipeline samples `back_texture` and writes
/// `front_texture`, swap, repeat; the last one writes
/// `frame.target` instead.
pub const supports_custom_shaders: bool = true;

/// Vulkan's clip-space Y axis points down (unlike OpenGL).
pub const custom_shader_y_is_down = true;

/// Extra `#define` lines `shadertoy.loadFromFile` injects into the
/// prefix between `#version` and the rest. `GHASTTY_VULKAN`
/// activates the Vulkan-side `gl_FragCoord` flip + `texture()`
/// upper-left wrap so `mainImage` sees shadertoy-convention coords
/// even though Vulkan rasterizes Y-down. OpenGL/MSL backends omit
/// this decl entirely and pass `&.{}` from `generic.zig`.
pub const custom_shader_extra_defines: []const []const u8 = &.{"GHASTTY_VULKAN 1"};

/// GLSL → GLSL rewriter `shadertoy.loadFromFile` runs after the
/// prefix splice and before the SPIR-V compile. Plugs the
/// `vulkanizeGlsl` pass that rewrites `layout(binding = N)` into
/// `layout(set = S, binding = N)` so the resulting SPIR-V matches
/// the renderer's multi-set descriptor layout. Without this, the
/// shader's `iChannel0` lands at set 0 binding 0 while the post
/// pipeline binds it at set 1 binding 0 → sampler returns garbage.
pub const rewriteCustomShaderSource = shaders.vulkanizeGlsl;

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

/// Refcount of live `Vulkan` renderer instances that share `device`.
/// Each `init` increments; each `deinit` decrements. The device is
/// only torn down when the count returns to 0, so closing one tab
/// (or one split) doesn't yank the VkDevice out from under the
/// surfaces still running in other tabs. Process-wide (matches
/// `device`'s scope). Mutated under `device_mutex` because
/// surfaces' renderer threads run independently and may init/deinit
/// concurrently.
var device_refcount: usize = 0;
var device_mutex: std.Thread.Mutex = .{};

/// Cross-frame buffer recycle pool. See `vulkan/buffer_pool.zig`
/// for the full lifecycle / multi-thread contract. Re-exported so
/// existing callers (`Vulkan.buffer_pool.cycle` etc.) keep working
/// unchanged.
pub const buffer_pool = @import("vulkan/buffer_pool.zig");

/// Per-renderer-thread state (frame command buffer, fence, descriptor
/// pool, last-target pointer). See `vulkan/ThreadState.zig` for the
/// lifecycle.
const ThreadState = @import("vulkan/ThreadState.zig");

// ---- lifecycle ----------------------------------------------------------

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    // Vulkan needs the device populated before the renderer's
    // `FrameState.init` starts asking for buffer/texture options.
    // Process-wide (not threadlocal): the renderer thread is
    // distinct from the main thread that constructs the surface.
    device_mutex.lock();
    defer device_mutex.unlock();
    if (device == null) {
        switch (apprt.runtime) {
            // The Vulkan renderer is embedded-only by design: the
            // host owns the VkInstance/Device/Queue and hands them
            // to libghostty via `ghostty_platform_vulkan_s`. There
            // is no Vulkan path through the GTK apprt and never
            // will be from this side. Compile-error any other
            // runtime so a misconfigured `-Drenderer=vulkan
            // -Dapp-runtime=gtk` build fails loudly at compile time
            // instead of crashing at first surface init. Mirrors
            // OpenGL.zig's `@compileError("unsupported app
            // runtime for OpenGL")` pattern.
            else => @compileError("unsupported app runtime for Vulkan (embedded-only)"),
            apprt.embedded => switch (opts.rt_surface.platform) {
                .vulkan => |platform| {
                    device = try Device.init(alloc, try bootstrapFromPlatform(platform));
                    log.info(
                        "Vulkan device ready (api=0x{x})",
                        .{device.?.api_version},
                    );
                },
                // The Platform union is decided at host-call time
                // (the C ABI lets the host pick), so this arm
                // really is a runtime check — the host plugged us
                // into a non-Vulkan surface.
                .opengl, .macos, .ios => return error.UnsupportedPlatform,
            },
        }
    }
    device_refcount += 1;
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
    };
}

pub fn deinit(self: *Vulkan) void {
    // Tear down THIS surface's per-thread state first (fence wait,
    // CB free, pool destroy, buffer-pool pending drain, last_target
    // clear). All of that is per-renderer-thread = per-surface, so
    // it's always safe to clean up regardless of other surfaces'
    // state.
    if (device) |*d| ThreadState.cleanup(d);

    // Decrement the shared-device refcount; only the last surface
    // to deinit gets to destroy the VkDevice. Closing one of N tabs
    // must NOT pull the device out from under the others — that
    // crashes (or invisibly silences) every other surface's
    // renderer thread.
    {
        device_mutex.lock();
        defer device_mutex.unlock();
        // Refcount-underflow guard. Was `std.debug.assert(refcount > 0)`,
        // but assertions compile out in ReleaseFast / ReleaseSmall — a
        // double-deinit would silently underflow the unsigned counter
        // to a huge value, blocking the device tear-down forever (the
        // refcount==0 branch below would never trigger). Hard-log
        // even in release: a stale deinit is a contract violation
        // we'd rather surface than mask. We still poison `self` at
        // function exit so the caller sees consistent UB on either
        // path.
        if (device_refcount == 0) {
            log.err("Vulkan.deinit: refcount underflow — double-deinit?", .{});
        } else {
            device_refcount -= 1;
            if (device_refcount == 0) {
                // Last surface: NOW we can safely drain the shared
                // `ready` list of the buffer pool and tear the device
                // down. The waitIdle is needed because non-final
                // deinits skipped it. Each surface's deinit already
                // drained its own per-thread `pending` (via
                // buffer_pool.drainSelf above), so this path only
                // needs to handle the cross-thread `ready`.
                if (device) |*d| {
                    d.waitIdle();
                    buffer_pool.drainShared(d);
                    d.deinit();
                }
                device = null;
            }
        }
    }
    self.* = undefined;
}

/// Early per-surface setup hook. No-op for Vulkan: the host
/// hasn't finished installing the platform callbacks at this
/// point, so all device wiring waits until `Vulkan.init` (which
/// runs after the platform is plumbed through `opts`).
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
}

/// Main-thread setup just before the renderer thread spins up.
/// No-op: device construction happens in `Vulkan.init` (the
/// renderer's FrameState init path calls option getters before
/// `threadEnter`, and those getters need the device — so it has
/// to be ready earlier than OpenGL needs it to be).
pub fn finalizeSurfaceInit(self: *const Vulkan, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const Vulkan, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
    // No-op: device is brought up in `init` (the renderer's
    // FrameState init path calls option getters before threadEnter
    // and those need the device). Decl kept so
    // `@hasDecl(GraphicsAPI, "threadEnter")` still resolves true in
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
    /// For Vulkan these are SPIR-V binaries (loaded with
    /// `shadertoy.Target = .spv`), not GLSL strings — see
    /// `custom_shader_target` above.
    custom_shaders: []const []const u8,
) !shaders.Shaders {
    _ = self;
    return try shaders.Shaders.init(alloc, devicePtr(), custom_shaders);
}

pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    // SRGB format so the hardware gamma-encodes the linear premultiplied
    // shader output at framebuffer-write time. The renderer's shaders
    // produce linear premultiplied alpha; without an sRGB format the
    // bytes in memory would be linear and Qt (which expects sRGB
    // premultiplied) would render them as if they were already gamma
    // encoded — colors would look way too dark. The DRM fourcc the
    // host sees is still ARGB8888; SRGB encoding is a Vulkan-side
    // concern only.
    //
    // Per-surface platform: pulled from rt_surface so the `present`
    // callback's `userdata` points at THIS surface's window. Splits
    // and tabs share the process-wide Device but each owns its own
    // platform copy — without per-surface routing here, all dmabuf
    // frames would funnel through whichever surface initialized the
    // device first.
    const platform = surfacePlatform(self.rt_surface) orelse
        return error.UnsupportedPlatform;
    return try Target.init(.{
        .device = devicePtr(),
        .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
        .width = @intCast(width),
        .height = @intCast(height),
        .platform = platform,
    });
}

/// Translate the apprt's `Platform.Vulkan` callback struct into the
/// neutral `Device.HostBootstrap` the binding expects. Resolves the
/// host's handles + the root proc-addr resolver up-front so the
/// binding stays free of any apprt type. Any null host handle ->
/// `error.HostHandleMissing`.
fn bootstrapFromPlatform(
    platform: apprt.embedded.Platform.Vulkan,
) Device.Error!Device.HostBootstrap {
    const instance_handle = platform.instance(platform.userdata) orelse
        return error.HostHandleMissing;
    const physical_device_handle = platform.physical_device(platform.userdata) orelse
        return error.HostHandleMissing;
    const device_handle = platform.device(platform.userdata) orelse
        return error.HostHandleMissing;
    const queue_handle = platform.queue(platform.userdata) orelse
        return error.HostHandleMissing;
    const get_instance_proc_addr_raw = platform.get_instance_proc_addr(
        platform.userdata,
        "vkGetInstanceProcAddr",
    ) orelse return error.HostHandleMissing;

    return .{
        .instance = @ptrCast(instance_handle),
        .physical_device = @ptrCast(physical_device_handle),
        .device = @ptrCast(device_handle),
        .queue = @ptrCast(queue_handle),
        .queue_family_index = platform.queue_family_index(platform.userdata),
        .get_instance_proc_addr_raw = get_instance_proc_addr_raw,
    };
}

/// Extract the Vulkan platform callbacks from a surface, when the
/// surface was created with the Vulkan platform tag. Returns null
/// when the surface was tagged with a non-Vulkan platform — the
/// caller is expected to reject the surface with
/// `error.UnsupportedPlatform`. (`Vulkan.init` already does the same
/// reject up-front, so reaching this function with a non-Vulkan
/// platform implies a surface plumbed through after that gate.)
fn surfacePlatform(rt_surface: *apprt.Surface) ?apprt.embedded.Platform.Vulkan {
    // `init()` already gates non-embedded runtimes with a
    // `@compileError`, so reaching this function on anything other
    // than `apprt.embedded` is impossible. Direct embedded match
    // here keeps the function single-arm.
    if (apprt.runtime != apprt.embedded)
        @compileError("unsupported app runtime for Vulkan (embedded-only)");
    return switch (rt_surface.platform) {
        .vulkan => |p| p,
        else => null,
    };
}

pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    const size = self.rt_surface.size;
    return .{ .width = size.width, .height = size.height };
}

pub fn present(self: *Vulkan, target: *Target) !void {
    _ = self;
    // The target is already populated by the time we get here:
    // `Frame.complete` ended the command buffer, submitted with the
    // fence, and waited for the GPU to finish before returning. So
    // the dmabuf fd is safe to hand off.
    target.present();
    // Remember the target's address so `presentLastTarget` can
    // re-present it on no-op frames. We store the pointer — not a
    // value copy — so a subsequent `frame.resize` (which destroys
    // the old Target and overwrites the FrameState's slot with a
    // new one) is transparently followed. A value copy would leave
    // us holding a closed fd and freed VkImage handles.
    ThreadState.last_target = target;
}

pub fn presentLastTarget(self: *Vulkan) !void {
    if (ThreadState.last_target) |t| try self.present(t);
}

pub fn beginFrame(
    self: *const Vulkan,
    renderer: *rendererpkg.Renderer,
    target: *Target,
) !Frame {
    _ = self;
    const dev = devicePtr();

    // Lazy per-thread resource init (no-op after the first frame on
    // this thread). Sets up the command pool + buffer + fence +
    // descriptor pool that get reused for every subsequent frame.
    try ThreadState.ensureInit(dev);

    // Reset this frame's per-frame state. The fence is the load-
    // bearing piece for tear-down correctness: any error path that
    // could leave the fence in an UNSIGNALED-with-no-pending-submit
    // state will hang the next `Vulkan.deinit` on
    // `waitForFences(UINT64_MAX)`.
    //
    // Defense: register the re-signal `errdefer` BEFORE the
    // `beginFrameReset` call (which is the one that calls
    // `vkResetFences`). If any reset fails, the errdefer fires
    // an empty submit with this fence as the signal target,
    // restoring the signaled state.
    errdefer {
        // Empty submit with this fence as the signal target is the
        // simplest portable way to push it back to signaled without
        // recording any commands. The fence in this errdefer can
        // be in any of three states:
        //   1. Reset by `beginFrameReset` (the failing path). The
        //      empty submit signals it cleanly.
        //   2. Still in its prior-frame state (the resetFences call
        //      failed — spec says the fence is in an undefined
        //      state). The empty submit re-signals once any prior
        //      pending submit on the queue retires; queueSubmit
        //      spec semantics guarantee the fence is signaled
        //      after all earlier submits complete.
        //   3. Driver-lost on DEVICE_LOST. queueSubmit returns
        //      DEVICE_LOST too; we fall back to deviceWaitIdle.
        // The fallback `vkDeviceWaitIdle` is the actual safety net
        // — without one of those signaling paths succeeding, the
        // next `Vulkan.deinit` hangs on `waitForFences(UINT64_MAX)`.
        const empty: vk.VkSubmitInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 0,
            .pCommandBuffers = null,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        const sr = dev.queueSubmit(1, &empty, ThreadState.frame_fence);
        if (sr != vk.VK_SUCCESS) {
            log.warn(
                "beginFrame errdefer: empty queueSubmit failed " ++
                    "(result={}); waiting device idle to ensure the fence " ++
                    "doesn't hang the next deinit",
                .{sr},
            );
            _ = dev.dispatch.deviceWaitIdle(dev.device);
        }
    }
    try ThreadState.beginFrameReset(dev);

    return try Frame.begin(
        .{
            .cb = ThreadState.frame_cb,
            .fence = ThreadState.frame_fence,
            .step_pool = if (ThreadState.step_pool) |*p| p else null,
        },
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
    // `Device` on the heap) don't ripple. Today the device is a
    // process-wide `?Device` populated in `Vulkan.init` BEFORE the
    // renderer's `FrameState.init` calls any of the option getters.
    // A null here means the device construction failed AND someone
    // called an option getter anyway — a programming error, not a
    // runtime condition we can recover from.
    return &(device orelse {
        @panic("Vulkan.devicePtr: device not initialized — option getter called before Vulkan.init succeeded");
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

/// Re-export so callers can write `Vulkan.ImageTextureFormat` —
/// matches the `OpenGL.ImageTextureFormat` shape on the OpenGL side.
/// Definition lives in `vulkan/Texture.zig` next to `Texture`
/// itself.
pub const ImageTextureFormat = Texture.ImageTextureFormat;

pub fn imageTextureOptions(
    _: *const Vulkan,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = devicePtr(),
        .format = format.toVk(srgb),
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
