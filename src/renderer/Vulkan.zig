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
//!   - `Texture.zig`     — VkImage + memory + view + staging upload.
//!   - `Target.zig`      — dmabuf-exportable render target
//!                          (direct or legacy_copy mode).
//!   - `buffer.zig`      — Buffer(T) host-coherent + recycle pool.
//!   - `Pipeline.zig`    — VkPipeline + layout (dynamic rendering).
//!   - `RenderPass.zig`  — dynamic-rendering pass + step recorder.
//!   - `Frame.zig`       — per-draw context (fence-paced).
//!   - `shaders.zig`     — GLSL→SPIR-V→VkShaderModule + the
//!                          OpenGL-GLSL → Vulkan-GLSL rewriter.

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

/// Process-wide pool of `(VkBuffer, VkDeviceMemory)` pairs recycled
/// across frames on the renderer thread. Solves two problems
/// together:
///
///   1. Lifetime: `vulkan/buffer.zig`'s `Buffer.deinit` is called
///      mid-frame (by `renderer/image.zig:draw`'s `defer buf.deinit()`)
///      while the command buffer that references the buffer hasn't
///      been submitted yet. Naive immediate destroy → use-after-free.
///   2. Allocation thrash: a frame with N kitty-image placements
///      would otherwise allocate N tiny VkBuffers + VkDeviceMemories
///      per frame, every frame. NVIDIA driver SIGSEGVs after a few
///      seconds of that.
///
/// Multi-thread design: `pending` is THREADLOCAL (each renderer
/// thread accumulates the buffers IT released during the current
/// frame), while `ready` is process-wide and mutex-protected (any
/// thread can recycle from it). Splits/tabs run independent
/// renderer threads against the SAME shared VkDevice — a single
/// shared `pending` list would let thread A's `Frame.complete`
/// retire buffers thread B released but whose fence hasn't
/// signaled yet, handing B's still-GPU-in-flight buffer back to a
/// new `acquire`. Per-thread pending bounds the visibility of
/// each entry to the thread that knows when its fence signals.
///
/// Lifecycle:
///   - `release(dev, …)` (renderer thread) pushes to THAT thread's
///     `pending`.
///   - `cycle(dev)` (renderer thread, after `vkWaitForFences` on
///     the SAME thread's per-frame fence) moves THAT thread's
///     `pending` → shared `ready` under the mutex.
///   - `acquire(…)` (any thread) pops a matching entry from `ready`
///     under the mutex.
///
/// Caller responsibilities:
///   - Only call `release` from the renderer thread whose fence
///     the frame's GPU work signals; calling from a thread that
///     never reaches its own `Frame.complete` would leak entries
///     (they sit in that thread's `pending` forever). For one-shot
///     uploads from a non-renderer thread (atlas staging), use
///     `Buffer.destroyImmediate` instead, which bypasses this
///     pool entirely.
pub const buffer_pool = struct {
    const Entry = struct {
        buffer: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
        usage: vk.VkBufferUsageFlags,
        capacity: u64,
    };

    /// Mutex guards the process-wide `ready` list (and the
    /// drainAll iteration over `pending`s — see comment there).
    var mutex: std.Thread.Mutex = .{};

    /// Per-thread pending list. Entries here were released by THIS
    /// thread during the current frame and are bounded by the
    /// fence THIS thread will wait on in `Frame.complete`. Moved
    /// to the shared `ready` list by `cycle()` after that wait
    /// returns.
    threadlocal var pending: std.ArrayList(Entry) = .{};

    /// Process-wide ready list. Entries here are provably retired
    /// (the bounding fence has signaled) and any thread may
    /// `acquire` them.
    var ready: std.ArrayList(Entry) = .{};

    /// Queue a buffer for recycling. The buffer cannot be reused
    /// until the next fence-wait (handled by `cycle`); it sits in
    /// THIS thread's `pending` until then. Bounded by THIS thread's
    /// per-frame fence — see the per-thread pending rationale at
    /// the top of `buffer_pool`.
    pub fn release(
        dev: *const Device,
        buffer: vk.VkBuffer,
        memory: vk.VkDeviceMemory,
        usage: vk.VkBufferUsageFlags,
        capacity: u64,
    ) !void {
        _ = dev;
        // No mutex: `pending` is threadlocal, only THIS thread
        // touches it.
        try pending.append(std.heap.smp_allocator, .{
            .buffer = buffer,
            .memory = memory,
            .usage = usage,
            .capacity = capacity,
        });
    }

    /// Pop a `ready` entry whose usage matches and whose capacity is
    /// >= the requested size. Linear scan — pools tend to have a
    /// small number of distinct (usage, size) shapes (image: 48B
    /// VERTEX, bg_image: 8B VERTEX) so this stays cheap.
    pub fn acquire(
        usage: vk.VkBufferUsageFlags,
        min_capacity: u64,
    ) ?Entry {
        mutex.lock();
        defer mutex.unlock();
        var i: usize = 0;
        while (i < ready.items.len) : (i += 1) {
            const e = ready.items[i];
            if (e.usage == usage and e.capacity >= min_capacity) {
                _ = ready.swapRemove(i);
                return e;
            }
        }
        return null;
    }

    /// Move THIS thread's `pending` entries to the shared `ready` —
    /// THIS thread's fence has signaled, so the GPU is done with
    /// every buffer in `pending`. Call from `Frame.complete` after
    /// `vkWaitForFences`.
    ///
    /// `dev` is needed only on the OOM fallback path: if `ready`
    /// can't grow to absorb `pending`, we wait the device idle
    /// (OUTSIDE the mutex — see below) and then destroy the pending
    /// entries directly so the next frame doesn't double up on a
    /// pending list that can never drain.
    pub fn cycle(dev: *const Device) void {
        // Try the fast path first — append THIS thread's `pending`
        // to the shared `ready` under the lock, then clear pending.
        // On OOM we have to destroy the pending entries, but
        // `vkDeviceWaitIdle` is slow and holding the pool mutex
        // across it would block every other renderer thread's
        // release/acquire/cycle. Move the pending list into a
        // local outside the lock, then drain.
        var oom_pending: std.ArrayList(Entry) = .{};
        defer oom_pending.deinit(std.heap.smp_allocator);
        {
            mutex.lock();
            defer mutex.unlock();
            if (ready.appendSlice(std.heap.smp_allocator, pending.items)) {
                pending.clearRetainingCapacity();
                return;
            } else |_| {
                // OOM. Move THIS thread's `pending` into our local
                // so we can drain without holding the mutex.
                oom_pending = pending;
                pending = .{};
            }
        }
        // Mutex released. Other threads can release/acquire/cycle
        // while we wait the device idle and destroy our slice.
        _ = dev.dispatch.deviceWaitIdle(dev.device);
        for (oom_pending.items) |e| {
            dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
            dev.dispatch.freeMemory(dev.device, e.memory, null);
        }
    }

    /// Destroy THIS thread's `pending` entries directly. Call from
    /// the same thread's `Vulkan.deinit` AFTER `vkWaitForFences`
    /// on this thread's frame fence — the bounding fence has
    /// signaled so the GPU is provably done with these buffers.
    ///
    /// Each renderer thread is responsible for cleaning up its own
    /// pending list because Zig threadlocal storage is the calling
    /// thread's; the final-refcount tear-down (`drainShared`) only
    /// handles the process-wide `ready` list.
    pub fn drainSelf(dev: *const Device) void {
        for (pending.items) |e| {
            dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
            dev.dispatch.freeMemory(dev.device, e.memory, null);
        }
        pending.clearRetainingCapacity();
    }

    /// Destroy every entry in the shared `ready` list. Call only
    /// from the FINAL surface tear-down (the path that hits
    /// `device_refcount == 0`) and only after every other renderer
    /// thread has already run `drainSelf` on its own pending list.
    pub fn drainShared(dev: *const Device) void {
        mutex.lock();
        defer mutex.unlock();
        for (ready.items) |e| {
            dev.dispatch.destroyBuffer(dev.device, e.buffer, null);
            dev.dispatch.freeMemory(dev.device, e.memory, null);
        }
        ready.clearRetainingCapacity();
    }
};

/// Most recently presented target, used by `presentLastTarget` when
/// the renderer decides nothing new needs drawing. Stored as a
/// POINTER (not a value copy) into the FrameState's `target` slot
/// so it follows the target through a resize: `frame.resize` calls
/// `target.deinit()` on the old Target and overwrites the slot with
/// a new one — a value copy would now reference a closed fd and
/// freed VkImage/VkBuffer/VkDeviceMemory handles, and Qt's mmap on
/// the closed fd could read whatever a later open() recycled the fd
/// for. Following the pointer instead always re-presents the
/// currently-live target.
threadlocal var last_target: ?*Target = null;

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

/// Per-thread descriptor pool used by `RenderPass.step` to allocate
/// fresh descriptor sets when the same pipeline is bound more than
/// once in a single pass (vkCmdDraw reads descriptors at submit
/// time, so re-using the pipeline's static set would silently
/// corrupt prior draws). Reset at the start of every `beginFrame`
/// so this frame's allocations don't pile on the previous frame's;
/// the per-pass usage is bounded by a small constant — see the
/// `step_pool_*` caps below.
threadlocal var step_pool: ?DescriptorPool = null;

/// Caps for the per-frame `step_pool`. Sized for the worst pass
/// shape (kitty image with N placements + the post pipelines): one
/// set per (image_step × MAX_DESCRIPTOR_SETS) plus a handful of
/// the renderer's other pipelines stepped once each. 256 is generous
/// — actual frames stabilize well under that. If a frame ever
/// exhausts the pool, `RenderPass.step` falls back to the pipeline's
/// static set with a warning logged.
const STEP_POOL_MAX_SETS: u32 = 256;
const STEP_POOL_UNIFORM_BUFFERS: u32 = 256;
const STEP_POOL_COMBINED_IMAGE_SAMPLERS: u32 = 256;
const STEP_POOL_STORAGE_BUFFERS: u32 = 256;

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
    // Tear down THIS surface's per-thread state first: wait for any
    // in-flight submit, then destroy fence, free CB, destroy pool.
    // These are threadlocal (one set per renderer thread = one set
    // per surface), so it's always safe to clean them up regardless
    // of other surfaces' state.
    if (device) |*d| {
        // Per-surface teardown only needs THIS surface's submissions
        // to be done — block on this thread's frame fence (if it
        // exists) instead of `vkDeviceWaitIdle` on the shared device,
        // which would stall every other tab/split's in-flight GPU
        // work just to close one. The final-refcount path below does
        // the device-wide waitIdle.
        if (frame_fence != null) {
            const wait_r = d.dispatch.waitForFences(
                d.device,
                1,
                &frame_fence,
                vk.VK_TRUE,
                std.math.maxInt(u64),
            );
            if (wait_r != vk.VK_SUCCESS) {
                log.warn(
                    "Vulkan.deinit: vkWaitForFences returned {}, falling back to device-wide wait",
                    .{wait_r},
                );
                d.waitIdle();
            }
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
        if (step_pool) |*p| {
            p.deinit();
            step_pool = null;
        }
        // Drain THIS thread's pending buffer-pool entries. The
        // frame-fence wait above proved the GPU is done with them,
        // and we have to do this from THIS thread because the
        // pending list is in this thread's threadlocal storage —
        // the final-refcount drainShared below can't reach it.
        buffer_pool.drainSelf(d);
        // `last_target` is a borrow into this thread's FrameState
        // target slot. The SwapChain teardown destroys the target;
        // we just drop our reference.
        last_target = null;
    }

    // Decrement the shared-device refcount; only the last surface
    // to deinit gets to destroy the VkDevice. Closing one of N tabs
    // must NOT pull the device out from under the others — that
    // crashes (or invisibly silences) every other surface's
    // renderer thread.
    device_mutex.lock();
    defer device_mutex.unlock();
    std.debug.assert(device_refcount > 0);
    device_refcount -= 1;
    if (device_refcount == 0) {
        // Last surface: NOW we can safely drain the shared `ready`
        // list of the buffer pool and tear the device down. The
        // waitIdle is needed because non-final deinits skipped it.
        // Each surface's deinit already drained its own per-thread
        // `pending` (via buffer_pool.drainSelf above), so this
        // path only needs to handle the cross-thread `ready`.
        if (device) |*d| {
            d.waitIdle();
            buffer_pool.drainShared(d);
            d.deinit();
        }
        device = null;
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
    if (step_pool == null) {
        step_pool = try DescriptorPool.init(.{
            .device = dev,
            .max_sets = STEP_POOL_MAX_SETS,
            .uniform_buffers = STEP_POOL_UNIFORM_BUFFERS,
            .combined_image_samplers = STEP_POOL_COMBINED_IMAGE_SAMPLERS,
            .storage_buffers = STEP_POOL_STORAGE_BUFFERS,
        });
    }

    _ = self;
    // Reset this frame's per-frame state. The fence is the load-
    // bearing piece for tear-down correctness: any error path that
    // could leave the fence in an UNSIGNALED-with-no-pending-submit
    // state will hang the next `Vulkan.deinit` on
    // `waitForFences(UINT64_MAX)`.
    //
    // Defense: register the re-signal `errdefer` BEFORE the
    // `vkResetFences` call. Then if any of the resets below fail
    // (including resetFences itself, which the spec says leaves the
    // fence in an undefined state on failure), the errdefer fires
    // an empty submit with this fence as the signal target,
    // restoring the signaled state.
    if (dev.dispatch.resetCommandBuffer(frame_cb, 0) != vk.VK_SUCCESS)
        return error.VulkanFailed;
    if (step_pool) |*p| {
        if (dev.dispatch.resetDescriptorPool(dev.device, p.pool, 0) != vk.VK_SUCCESS)
            return error.VulkanFailed;
    }
    errdefer {
        // Empty submit with this fence as the signal target is the
        // simplest portable way to push it back to signaled without
        // recording any commands. We track the queueSubmit result
        // and fall back to `vkDeviceWaitIdle` if even the empty
        // submit fails — without one of those signaling paths
        // succeeding, deinit hangs forever.
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
        const sr = dev.queueSubmit(1, &empty, frame_fence);
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
    // `vkResetDescriptorPool` returns every set the previous frame
    // allocated to the pool — much cheaper than freeing them
    // individually, and removes any chance of last-frame's set
    // being bound by accident.
    if (dev.dispatch.resetFences(dev.device, 1, &frame_fence) != vk.VK_SUCCESS)
        return error.VulkanFailed;

    return try Frame.begin(
        .{
            .cb = frame_cb,
            .fence = frame_fence,
            .step_pool = if (step_pool) |*p| p else null,
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

    fn toVk(self: ImageTextureFormat, srgb: bool) vk.VkFormat {
        return switch (self) {
            // `gray` is a single-channel R8 (no color, no gamma).
            .gray => vk.VK_FORMAT_R8_UNORM,
            // Color channels honor `srgb`: when an image was
            // authored in sRGB (the common case for kitty graphics),
            // selecting the SRGB format lets the sampler auto-
            // linearize on read so `texture()` returns linear values
            // that the renderer's `unlinearize()` then re-encodes
            // for the sRGB framebuffer. UNORM here would skip the
            // sampler decode, leaving sRGB bytes for `unlinearize`
            // to encode-again, which is then encoded a third time
            // by the SRGB framebuffer — visible as washed-out kitty
            // graphics.
            .rgba => if (srgb) vk.VK_FORMAT_R8G8B8A8_SRGB else vk.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb) vk.VK_FORMAT_B8G8R8A8_SRGB else vk.VK_FORMAT_B8G8R8A8_UNORM,
        };
    }
};

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
