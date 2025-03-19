//! Renderer implementation for Metal.
//!
//! Open questions:
//!
pub const Metal = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const objc = @import("objc");
const macos = @import("macos");
const imgui = @import("imgui");
const glslang = @import("glslang");
const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const graphics = macos.graphics;
const fgMode = @import("cell.zig").fgMode;
const isCovering = @import("cell.zig").isCovering;
const shadertoy = @import("shadertoy.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const CFReleaseThread = os.CFReleaseThread;
const Terminal = terminal.Terminal;
const Health = renderer.Health;

const mtl = @import("metal/api.zig");
const mtl_buffer = @import("metal/buffer.zig");
const mtl_cell = @import("metal/cell.zig");
const mtl_image = @import("metal/image.zig");
const mtl_sampler = @import("metal/sampler.zig");
const mtl_shaders = @import("metal/shaders.zig");
const Image = mtl_image.Image;
const ImageMap = mtl_image.ImageMap;
const Shaders = mtl_shaders.Shaders;

const ImageBuffer = mtl_buffer.Buffer(mtl_shaders.Image);
const InstanceBuffer = mtl_buffer.Buffer(u16);

const ImagePlacementList = std.ArrayListUnmanaged(mtl_image.Placement);

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.os.tag == .macos,
});

const log = std.log.scoped(.metal);

/// Allocator that can be used
alloc: std.mem.Allocator,

/// The configuration we need derived from the main config.
config: DerivedConfig,

/// The mailbox for communicating with the window.
surface_mailbox: apprt.surface.Mailbox,

/// Current font metrics defining our grid.
grid_metrics: font.Metrics,

/// The size of everything.
size: renderer.Size,

/// True if the window is focused
focused: bool,

/// The foreground color set by an OSC 10 sequence. If unset then
/// default_foreground_color is used.
foreground_color: ?terminal.color.RGB,

/// Foreground color set in the user's config file.
default_foreground_color: terminal.color.RGB,

/// The background color set by an OSC 11 sequence. If unset then
/// default_background_color is used.
background_color: ?terminal.color.RGB,

/// Background color set in the user's config file.
default_background_color: terminal.color.RGB,

/// The cursor color set by an OSC 12 sequence. If unset then
/// default_cursor_color is used.
cursor_color: ?terminal.color.RGB,

/// Default cursor color when no color is set explicitly by an OSC 12 command.
/// This is cursor color as set in the user's config, if any. If no cursor color
/// is set in the user's config, then the cursor color is determined by the
/// current foreground color.
default_cursor_color: ?terminal.color.RGB,

/// When `cursor_color` is null, swap the foreground and background colors of
/// the cell under the cursor for the cursor color. Otherwise, use the default
/// foreground color as the cursor color.
cursor_invert: bool,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate. Each set of
/// cells goes into a separate shader.
cells: mtl_cell.Contents,

/// The last viewport that we based our rebuild off of. If this changes,
/// then we do a full rebuild of the cells. The pointer values in this pin
/// are NOT SAFE to read because they may be modified, freed, etc from the
/// termio thread. We treat the pointers as integers for comparison only.
cells_viewport: ?terminal.Pin = null,

/// Set to true after rebuildCells is called. This can be used
/// to determine if any possible changes have been made to the
/// cells for the draw call.
cells_rebuilt: bool = false,

/// The current GPU uniform values.
uniforms: mtl_shaders.Uniforms,

/// The font structures.
font_grid: *font.SharedGrid,
font_shaper: font.Shaper,
font_shaper_cache: font.ShaperCache,

/// The images that we may render.
images: ImageMap = .{},
image_placements: ImagePlacementList = .{},
image_bg_end: u32 = 0,
image_text_end: u32 = 0,
image_virtual: bool = false,

/// Metal state
shaders: Shaders, // Compiled shaders

/// Metal objects
layer: objc.Object, // CAMetalLayer

/// The CVDisplayLink used to drive the rendering loop in sync
/// with the display. This is void on platforms that don't support
/// a display link.
display_link: ?DisplayLink = null,

/// The `CGColorSpace` that represents our current terminal color space
terminal_colorspace: *graphics.ColorSpace,

/// Custom shader state. This is only set if we have custom shaders.
custom_shader_state: ?CustomShaderState = null,

/// Health of the last frame. Note that when we do double/triple buffering
/// this will have to be part of the frame state.
health: std.atomic.Value(Health) = .{ .raw = .healthy },

/// Our GPU state
gpu_state: GPUState,

/// State we need for the GPU that is shared between all frames.
pub const GPUState = struct {
    // The count of buffers we use for double/triple buffering. If
    // this is one then we don't do any double+ buffering at all. This
    // is comptime because there isn't a good reason to change this at
    // runtime and there is a lot of complexity to support it. For comptime,
    // this is useful for debugging.
    const BufferCount = 3;

    /// The frame data, the current frame index, and the semaphore protecting
    /// the frame data. This is used to implement double/triple/etc. buffering.
    frames: [BufferCount]FrameState,
    frame_index: std.math.IntFittingRange(0, BufferCount) = 0,
    frame_sema: std.Thread.Semaphore = .{ .permits = BufferCount },

    device: objc.Object, // MTLDevice
    queue: objc.Object, // MTLCommandQueue

    /// This buffer is written exactly once so we can use it globally.
    instance: InstanceBuffer, // MTLBuffer

    /// The default storage mode to use for resources created with our device.
    ///
    /// This is based on whether the device is a discrete GPU or not, since
    /// discrete GPUs do not have unified memory and therefore do not support
    /// the "shared" storage mode, instead we have to use the "managed" mode.
    default_storage_mode: mtl.MTLResourceOptions.StorageMode,

    pub fn init() !GPUState {
        const device = try chooseDevice();
        const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
        errdefer queue.release();

        // We determine whether our device is a discrete GPU based on these:
        // - We're on macOS (iOS, iPadOS, etc. are guaranteed to be integrated).
        // - We're not on aarch64 (Apple Silicon, therefore integrated).
        // - The device reports that it does not have unified memory.
        const is_discrete =
            builtin.target.os.tag == .macos and
            builtin.target.cpu.arch != .aarch64 and
            !device.getProperty(bool, "hasUnifiedMemory");

        const default_storage_mode: mtl.MTLResourceOptions.StorageMode =
            if (is_discrete) .managed else .shared;

        var instance = try InstanceBuffer.initFill(device, &.{
            0, 1, 3, // Top-left triangle
            1, 2, 3, // Bottom-right triangle
        }, .{ .storage_mode = default_storage_mode });
        errdefer instance.deinit();

        var result: GPUState = .{
            .device = device,
            .queue = queue,
            .instance = instance,
            .frames = undefined,
            .default_storage_mode = default_storage_mode,
        };

        // Initialize all of our frame state.
        for (&result.frames) |*frame| {
            frame.* = try FrameState.init(result.device, default_storage_mode);
        }

        return result;
    }

    fn chooseDevice() error{NoMetalDevice}!objc.Object {
        var chosen_device: ?objc.Object = null;

        switch (comptime builtin.os.tag) {
            .macos => {
                const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
                defer devices.release();

                var iter = devices.iterate();
                while (iter.next()) |device| {
                    // We want a GPU that’s connected to a display.
                    if (device.getProperty(bool, "isHeadless")) continue;
                    chosen_device = device;
                    // If the user has an eGPU plugged in, they probably want
                    // to use it. Otherwise, integrated GPUs are better for
                    // battery life and thermals.
                    if (device.getProperty(bool, "isRemovable") or
                        device.getProperty(bool, "isLowPower")) break;
                }
            },
            .ios => {
                chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
            },
            else => @compileError("unsupported target for Metal"),
        }

        const device = chosen_device orelse return error.NoMetalDevice;
        return device.retain();
    }

    pub fn deinit(self: *GPUState) void {
        // Wait for all of our inflight draws to complete so that
        // we can cleanly deinit our GPU state.
        for (0..BufferCount) |_| self.frame_sema.wait();
        for (&self.frames) |*frame| frame.deinit();
        self.instance.deinit();
        self.queue.release();
        self.device.release();
    }

    /// Get the next frame state to draw to. This will wait on the
    /// semaphore to ensure that the frame is available. This must
    /// always be paired with a call to releaseFrame.
    pub fn nextFrame(self: *GPUState) *FrameState {
        self.frame_sema.wait();
        errdefer self.frame_sema.post();
        self.frame_index = (self.frame_index + 1) % BufferCount;
        return &self.frames[self.frame_index];
    }

    /// This should be called when the frame has completed drawing.
    pub fn releaseFrame(self: *GPUState) void {
        self.frame_sema.post();
    }
};

/// State we need duplicated for every frame. Any state that could be
/// in a data race between the GPU and CPU while a frame is being
/// drawn should be in this struct.
///
/// While a draw is in-process, we "lock" the state (via a semaphore)
/// and prevent the CPU from updating the state until Metal reports
/// that the frame is complete.
///
/// This is used to implement double/triple buffering.
pub const FrameState = struct {
    uniforms: UniformBuffer,
    cells: CellTextBuffer,
    cells_bg: CellBgBuffer,

    grayscale: objc.Object, // MTLTexture
    grayscale_modified: usize = 0,
    color: objc.Object, // MTLTexture
    color_modified: usize = 0,

    /// A buffer containing the uniform data.
    const UniformBuffer = mtl_buffer.Buffer(mtl_shaders.Uniforms);
    const CellBgBuffer = mtl_buffer.Buffer(mtl_shaders.CellBg);
    const CellTextBuffer = mtl_buffer.Buffer(mtl_shaders.CellText);

    pub fn init(
        device: objc.Object,
        /// Storage mode for buffers and textures.
        storage_mode: mtl.MTLResourceOptions.StorageMode,
    ) !FrameState {
        // Uniform buffer contains exactly 1 uniform struct. The
        // uniform data will be undefined so this must be set before
        // a frame is drawn.
        var uniforms = try UniformBuffer.init(
            device,
            1,
            .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = storage_mode,
            },
        );
        errdefer uniforms.deinit();

        // Create the buffers for our vertex data. The preallocation size
        // is likely too small but our first frame update will resize it.
        var cells = try CellTextBuffer.init(
            device,
            10 * 10,
            .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = storage_mode,
            },
        );
        errdefer cells.deinit();
        var cells_bg = try CellBgBuffer.init(
            device,
            10 * 10,
            .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = storage_mode,
            },
        );

        errdefer cells_bg.deinit();

        // Initialize our textures for our font atlas.
        const grayscale = try initAtlasTexture(device, &.{
            .data = undefined,
            .size = 8,
            .format = .grayscale,
        }, storage_mode);
        errdefer grayscale.release();
        const color = try initAtlasTexture(device, &.{
            .data = undefined,
            .size = 8,
            .format = .rgba,
        }, storage_mode);
        errdefer color.release();

        return .{
            .uniforms = uniforms,
            .cells = cells,
            .cells_bg = cells_bg,
            .grayscale = grayscale,
            .color = color,
        };
    }

    pub fn deinit(self: *FrameState) void {
        self.uniforms.deinit();
        self.cells.deinit();
        self.cells_bg.deinit();
        self.grayscale.release();
        self.color.release();
    }
};

pub const CustomShaderState = struct {
    /// When we have a custom shader state, we maintain a front
    /// and back texture which we use as a swap chain to render
    /// between when multiple custom shaders are defined.
    front_texture: objc.Object, // MTLTexture
    back_texture: objc.Object, // MTLTexture

    sampler: mtl_sampler.Sampler,
    uniforms: mtl_shaders.PostUniforms,

    /// The first time a frame was drawn.
    /// This is used to update the time uniform.
    first_frame_time: std.time.Instant,

    /// The last time a frame was drawn.
    /// This is used to update the time uniform.
    last_frame_time: std.time.Instant,

    /// Swap the front and back textures.
    pub fn swap(self: *CustomShaderState) void {
        std.mem.swap(objc.Object, &self.front_texture, &self.back_texture);
    }

    pub fn deinit(self: *CustomShaderState) void {
        self.front_texture.release();
        self.back_texture.release();
        self.sampler.deinit();
    }
};

/// The configuration for this renderer that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    font_thicken: bool,
    font_thicken_strength: u8,
    font_features: std.ArrayListUnmanaged([:0]const u8),
    font_styles: font.CodepointResolver.StyleStatus,
    cursor_color: ?terminal.color.RGB,
    cursor_invert: bool,
    cursor_opacity: f64,
    cursor_text: ?terminal.color.RGB,
    background: terminal.color.RGB,
    background_opacity: f64,
    foreground: terminal.color.RGB,
    selection_background: ?terminal.color.RGB,
    selection_foreground: ?terminal.color.RGB,
    invert_selection_fg_bg: bool,
    bold_is_bright: bool,
    min_contrast: f32,
    padding_color: configpkg.WindowPaddingColor,
    custom_shaders: configpkg.RepeatablePath,
    links: link.Set,
    vsync: bool,
    colorspace: configpkg.Config.WindowColorspace,
    blending: configpkg.Config.AlphaBlending,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Copy our shaders
        const custom_shaders = try config.@"custom-shader".clone(alloc);

        // Copy our font features
        const font_features = try config.@"font-feature".clone(alloc);

        // Get our font styles
        var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
        font_styles.set(.bold, config.@"font-style-bold" != .false);
        font_styles.set(.italic, config.@"font-style-italic" != .false);
        font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Our link configs
        const links = try link.Set.fromConfig(
            alloc,
            config.link.links.items,
        );

        const cursor_invert = config.@"cursor-invert-fg-bg";

        return .{
            .background_opacity = @max(0, @min(1, config.@"background-opacity")),
            .font_thicken = config.@"font-thicken",
            .font_thicken_strength = config.@"font-thicken-strength",
            .font_features = font_features.list,
            .font_styles = font_styles,

            .cursor_color = if (!cursor_invert and config.@"cursor-color" != null)
                config.@"cursor-color".?.toTerminalRGB()
            else
                null,

            .cursor_invert = cursor_invert,

            .cursor_text = if (config.@"cursor-text") |txt|
                txt.toTerminalRGB()
            else
                null,

            .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),
            .invert_selection_fg_bg = config.@"selection-invert-fg-bg",
            .bold_is_bright = config.@"bold-is-bright",
            .min_contrast = @floatCast(config.@"minimum-contrast"),
            .padding_color = config.@"window-padding-color",

            .selection_background = if (config.@"selection-background") |bg|
                bg.toTerminalRGB()
            else
                null,

            .selection_foreground = if (config.@"selection-foreground") |bg|
                bg.toTerminalRGB()
            else
                null,

            .custom_shaders = custom_shaders,
            .links = links,
            .vsync = config.@"window-vsync",
            .colorspace = config.@"window-colorspace",
            .blending = config.@"alpha-blending",
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        const alloc = self.arena.allocator();
        self.links.deinit(alloc);
        self.arena.deinit();
    }
};

/// Returns the hints that we want for this
pub fn glfwWindowHints(config: *const configpkg.Config) glfw.Window.Hints {
    return .{
        .client_api = .no_api,
        .transparent_framebuffer = config.@"background-opacity" < 1,
    };
}

/// This is called early right after window creation to setup our
/// window surface as necessary.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;

    // We don't do anything else here because we want to set everything
    // else up during actual initialization.
}

pub fn init(alloc: Allocator, options: renderer.Options) !Metal {
    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.glfw => info: {
            // Everything in glfw is window-oriented so we grab the backing
            // window, then derive everything from that.
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(
                options.rt_surface.window,
            ).?);

            const contentView = objc.Object.fromId(
                nswindow.getProperty(?*anyopaque, "contentView").?,
            );
            const scaleFactor = nswindow.getProperty(
                graphics.c.CGFloat,
                "backingScaleFactor",
            );

            break :info .{
                .view = contentView,
                .scaleFactor = scaleFactor,
            };
        },

        apprt.embedded => .{
            .scaleFactor = @floatCast(options.rt_surface.content_scale.x),
            .view = switch (options.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Initialize our metal stuff
    var gpu_state = try GPUState.init();
    errdefer gpu_state.deinit();

    // Get our CAMetalLayer
    const layer: objc.Object = switch (builtin.os.tag) {
        .macos => layer: {
            const CAMetalLayer = objc.getClass("CAMetalLayer").?;
            break :layer CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{});
        },

        // iOS is always layer-backed so we don't need to do anything here.
        .ios => info.view.getProperty(objc.Object, "layer"),

        else => @compileError("unsupported target for Metal"),
    };
    layer.setProperty("device", gpu_state.device.value);
    layer.setProperty("opaque", options.config.background_opacity >= 1);
    layer.setProperty("displaySyncEnabled", options.config.vsync);

    // Set our layer's pixel format appropriately.
    layer.setProperty(
        "pixelFormat",
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (options.config.blending.isLinear())
            @intFromEnum(mtl.MTLPixelFormat.bgra8unorm_srgb)
        else
            @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
    );

    // Set our layer's color space to Display P3.
    // This allows us to have "Apple-style" alpha blending,
    // since it seems to be the case that Apple apps like
    // Terminal and TextEdit render text in the display's
    // color space using converted colors, which reduces,
    // but does not fully eliminate blending artifacts.
    const colorspace = try graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();
    layer.setProperty("colorspace", colorspace);

    // Create a colorspace the represents our terminal colors
    // this will allow us to create e.g. `CGColor`s for things
    // like the current background color.
    const terminal_colorspace = try graphics.ColorSpace.createNamed(
        switch (options.config.colorspace) {
            .@"display-p3" => .displayP3,
            .srgb => .sRGB,
        },
    );
    errdefer terminal_colorspace.release();

    // Make our view layer-backed with our Metal layer. On iOS views are
    // always layer backed so we don't need to do this. But on iOS the
    // caller MUST be sure to set the layerClass to CAMetalLayer.
    if (comptime builtin.os.tag == .macos) {
        info.view.setProperty("layer", layer.value);
        info.view.setProperty("wantsLayer", true);

        // The layer gravity is set to top-left so that when we resize
        // the view, the contents aren't stretched before a redraw.
        layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);
    }

    // Ensure that our metal layer has a content scale set to match the
    // scale factor of the window. This avoids magnification issues leading
    // to blurry rendering.
    layer.setProperty("contentsScale", info.scaleFactor);

    // Create the font shaper. We initially create a shaper that can support
    // a width of 160 which is a common width for modern screens to help
    // avoid allocations later.
    var font_shaper = try font.Shaper.init(alloc, .{
        .features = options.config.font_features.items,
    });
    errdefer font_shaper.deinit();

    // Initialize all the data that requires a critical font section.
    const font_critical: struct {
        metrics: font.Metrics,
    } = font_critical: {
        const grid = options.font_grid;
        grid.lock.lockShared();
        defer grid.lock.unlockShared();
        break :font_critical .{
            .metrics = grid.metrics,
        };
    };

    const display_link: ?DisplayLink = switch (builtin.os.tag) {
        .macos => if (options.config.vsync)
            try macos.video.DisplayLink.createWithActiveCGDisplays()
        else
            null,
        else => null,
    };
    errdefer if (display_link) |v| v.release();

    var result: Metal = .{
        .alloc = alloc,
        .config = options.config,
        .surface_mailbox = options.surface_mailbox,
        .grid_metrics = font_critical.metrics,
        .size = options.size,
        .focused = true,
        .foreground_color = null,
        .default_foreground_color = options.config.foreground,
        .background_color = null,
        .default_background_color = options.config.background,
        .cursor_color = null,
        .default_cursor_color = options.config.cursor_color,
        .cursor_invert = options.config.cursor_invert,

        // Render state
        .cells = .{},
        .uniforms = .{
            .projection_matrix = undefined,
            .cell_size = undefined,
            .grid_size = undefined,
            .grid_padding = undefined,
            .padding_extend = .{},
            .min_contrast = options.config.min_contrast,
            .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
            .cursor_color = undefined,
            .bg_color = .{
                options.config.background.r,
                options.config.background.g,
                options.config.background.b,
                @intFromFloat(@round(options.config.background_opacity * 255.0)),
            },
            .cursor_wide = false,
            .use_display_p3 = options.config.colorspace == .@"display-p3",
            .use_linear_blending = options.config.blending.isLinear(),
            .use_linear_correction = options.config.blending == .@"linear-corrected",
        },

        // Fonts
        .font_grid = options.font_grid,
        .font_shaper = font_shaper,
        .font_shaper_cache = font.ShaperCache.init(),

        // Shaders (initialized below)
        .shaders = undefined,

        // Metal stuff
        .layer = layer,
        .display_link = display_link,
        .terminal_colorspace = terminal_colorspace,
        .custom_shader_state = null,
        .gpu_state = gpu_state,
    };

    try result.initShaders();

    // Do an initialize screen size setup to ensure our undefined values
    // above are initialized.
    try result.setScreenSize(result.size);

    return result;
}

pub fn deinit(self: *Metal) void {
    self.gpu_state.deinit();

    if (DisplayLink != void) {
        if (self.display_link) |display_link| {
            display_link.stop() catch {};
            display_link.release();
        }
    }

    self.terminal_colorspace.release();

    self.cells.deinit(self.alloc);

    self.font_shaper.deinit();
    self.font_shaper_cache.deinit(self.alloc);

    self.config.deinit();

    {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.image.deinit(self.alloc);
        self.images.deinit(self.alloc);
    }
    self.image_placements.deinit(self.alloc);

    self.deinitShaders();

    self.* = undefined;
}

fn deinitShaders(self: *Metal) void {
    if (self.custom_shader_state) |*state| state.deinit();

    self.shaders.deinit(self.alloc);
}

fn initShaders(self: *Metal) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Load our custom shaders
    const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
        arena_alloc,
        self.config.custom_shaders,
        .msl,
    ) catch |err| err: {
        log.warn("error loading custom shaders err={}", .{err});
        break :err &.{};
    };

    var custom_shader_state: ?CustomShaderState = state: {
        if (custom_shaders.len == 0) break :state null;

        // Build our sampler for our texture
        var sampler = try mtl_sampler.Sampler.init(self.gpu_state.device);
        errdefer sampler.deinit();

        break :state .{
            // Resolution and screen textures will be fixed up by first
            // call to setScreenSize. Draw calls will bail out early if
            // the screen size hasn't been set yet, so it won't error.
            .front_texture = undefined,
            .back_texture = undefined,
            .sampler = sampler,
            .uniforms = .{
                .resolution = .{ 0, 0, 1 },
                .time = 1,
                .time_delta = 1,
                .frame_rate = 1,
                .frame = 1,
                .channel_time = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .channel_resolution = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
                .mouse = .{ 0, 0, 0, 0 },
                .date = .{ 0, 0, 0, 0 },
                .sample_rate = 1,
            },

            .first_frame_time = try std.time.Instant.now(),
            .last_frame_time = try std.time.Instant.now(),
        };
    };
    errdefer if (custom_shader_state) |*state| state.deinit();

    var shaders = try Shaders.init(
        self.alloc,
        self.gpu_state.device,
        custom_shaders,
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (self.config.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
    errdefer shaders.deinit(self.alloc);

    self.shaders = shaders;
    self.custom_shader_state = custom_shader_state;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *Metal, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // Metal doesn't have to do anything here. OpenGL has to do things
    // like release the context but Metal doesn't have anything like that.
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const Metal, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // Metal requires no per-thread state.
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const Metal) void {
    _ = self;

    // Metal requires no per-thread state.
}

/// Called by renderer.Thread when it starts the main loop.
pub fn loopEnter(self: *Metal, thr: *renderer.Thread) !void {
    // If we don't support a display link we have no work to do.
    if (comptime DisplayLink == void) return;

    // This is when we know our "self" pointer is stable so we can
    // setup the display link. To setup the display link we set our
    // callback and we can start it immediately.
    const display_link = self.display_link orelse return;
    try display_link.setOutputCallback(
        xev.Async,
        &displayLinkCallback,
        &thr.draw_now,
    );
    display_link.start() catch {};
}

/// Called by renderer.Thread when it exits the main loop.
pub fn loopExit(self: *Metal) void {
    // If we don't support a display link we have no work to do.
    if (comptime DisplayLink == void) return;

    // Stop our display link. If this fails its okay it just means
    // that we either never started it or the view its attached to
    // is gone which is fine.
    const display_link = self.display_link orelse return;
    display_link.stop() catch {};
}

fn displayLinkCallback(
    _: *macos.video.DisplayLink,
    ud: ?*xev.Async,
) void {
    const draw_now = ud orelse return;
    draw_now.notify() catch |err| {
        log.err("error notifying draw_now err={}", .{err});
    };
}

/// Mark the full screen as dirty so that we redraw everything.
pub fn markDirty(self: *Metal) void {
    // This is how we force a full rebuild with metal.
    self.cells_viewport = null;
}

/// Called when we get an updated display ID for our display link.
pub fn setMacOSDisplayID(self: *Metal, id: u32) !void {
    if (comptime DisplayLink == void) return;
    const display_link = self.display_link orelse return;
    log.info("updating display link display id={}", .{id});
    display_link.setCurrentCGDisplay(id) catch |err| {
        log.warn("error setting display link display id err={}", .{err});
    };
}

/// True if our renderer has animations so that a higher frequency
/// timer is used.
pub fn hasAnimations(self: *const Metal) bool {
    return self.custom_shader_state != null;
}

/// True if our renderer is using vsync. If true, the renderer or apprt
/// is responsible for triggering draw_now calls to the render thread. That
/// is the only way to trigger a drawFrame.
pub fn hasVsync(self: *const Metal) bool {
    if (comptime DisplayLink == void) return false;
    const display_link = self.display_link orelse return false;
    return display_link.isRunning();
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *Metal, focus: bool) !void {
    self.focused = focus;

    // If we're not focused, then we want to stop the display link
    // because it is a waste of resources and we can move to pure
    // change-driven updates.
    if (comptime DisplayLink != void) link: {
        const display_link = self.display_link orelse break :link;
        if (focus) {
            display_link.start() catch {};
        } else {
            display_link.stop() catch {};
        }
    }
}

/// Callback when the window is visible or occluded.
///
/// Must be called on the render thread.
pub fn setVisible(self: *Metal, visible: bool) void {
    // If we're not visible, then we want to stop the display link
    // because it is a waste of resources and we can move to pure
    // change-driven updates.
    if (comptime DisplayLink != void) link: {
        const display_link = self.display_link orelse break :link;
        if (visible and self.focused) {
            display_link.start() catch {};
        } else {
            display_link.stop() catch {};
        }
    }
}

/// Set the new font grid.
///
/// Must be called on the render thread.
pub fn setFontGrid(self: *Metal, grid: *font.SharedGrid) void {
    // Update our grid
    self.font_grid = grid;

    // Update all our textures so that they sync on the next frame.
    // We can modify this without a lock because the GPU does not
    // touch this data.
    for (&self.gpu_state.frames) |*frame| {
        frame.grayscale_modified = 0;
        frame.color_modified = 0;
    }

    // Get our metrics from the grid. This doesn't require a lock because
    // the metrics are never recalculated.
    const metrics = grid.metrics;
    self.grid_metrics = metrics;

    // Reset our shaper cache. If our font changed (not just the size) then
    // the data in the shaper cache may be invalid and cannot be used, so we
    // always clear the cache just in case.
    const font_shaper_cache = font.ShaperCache.init();
    self.font_shaper_cache.deinit(self.alloc);
    self.font_shaper_cache = font_shaper_cache;

    // Run a screen size update since this handles a lot of our uniforms
    // that are grid size dependent and changing the font grid can change
    // the grid size.
    //
    // If the screen size isn't set, it will be eventually so that'll call
    // the setScreenSize automatically.
    self.setScreenSize(self.size) catch |err| {
        // The setFontGrid function can't fail but resizing our cell
        // buffer definitely can fail. If it does, our renderer is probably
        // screwed but let's just log it and continue until we can figure
        // out a better way to handle this.
        log.err("error resizing cells buffer err={}", .{err});
    };

    // Reset our viewport to force a rebuild, since `setScreenSize` only
    // does this when the number of cells changes, which isn't guaranteed.
    self.cells_viewport = null;
}

/// Update the frame data.
pub fn updateFrame(
    self: *Metal,
    surface: *apprt.Surface,
    state: *renderer.State,
    cursor_blink_visible: bool,
) !void {
    _ = surface;

    // Data we extract out of the critical area.
    const Critical = struct {
        bg: terminal.color.RGB,
        screen: terminal.Screen,
        screen_type: terminal.ScreenType,
        mouse: renderer.State.Mouse,
        preedit: ?renderer.State.Preedit,
        cursor_style: ?renderer.CursorStyle,
        color_palette: terminal.color.Palette,
        viewport_pin: terminal.Pin,

        /// If true, rebuild the full screen.
        full_rebuild: bool,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        // const start = try std.time.Instant.now();
        // const start_micro = std.time.microTimestamp();
        // defer {
        //     const end = std.time.Instant.now() catch unreachable;
        //     // "[updateFrame critical time] <START us>\t<TIME_TAKEN us>"
        //     std.log.err("[updateFrame critical time] {}\t{}", .{start_micro, end.since(start) / std.time.ns_per_us});
        // }

        state.mutex.lock();
        defer state.mutex.unlock();

        // If we're in a synchronized output state, we pause all rendering.
        if (state.terminal.modes.get(.synchronized_output)) {
            log.debug("synchronized output started, skipping render", .{});
            return;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.background_color orelse self.default_background_color;
        const fg = self.foreground_color orelse self.default_foreground_color;
        defer {
            if (self.background_color) |*c| {
                c.* = bg;
            } else {
                self.default_background_color = bg;
            }

            if (self.foreground_color) |*c| {
                c.* = fg;
            } else {
                self.default_foreground_color = fg;
            }
        }

        if (state.terminal.modes.get(.reverse_colors)) {
            if (self.background_color) |*c| {
                c.* = fg;
            } else {
                self.default_background_color = fg;
            }

            if (self.foreground_color) |*c| {
                c.* = bg;
            } else {
                self.default_foreground_color = bg;
            }
        }

        // Get the viewport pin so that we can compare it to the current.
        const viewport_pin = state.terminal.screen.pages.pin(.{ .viewport = .{} }).?;

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock while rebuilding GPU cells.
        var screen_copy = try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = .{} },
            null,
        );
        errdefer screen_copy.deinit();

        // Whether to draw our cursor or not.
        const cursor_style = if (state.terminal.flags.password_input)
            .lock
        else
            renderer.cursorStyle(
                state,
                self.focused,
                cursor_blink_visible,
            );

        // Get our preedit state
        const preedit: ?renderer.State.Preedit = preedit: {
            if (cursor_style == null) break :preedit null;
            const p = state.preedit orelse break :preedit null;
            break :preedit try p.clone(self.alloc);
        };
        errdefer if (preedit) |p| p.deinit(self.alloc);

        // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
        // We only do this if the Kitty image state is dirty meaning only if
        // it changes.
        //
        // If we have any virtual references, we must also rebuild our
        // kitty state on every frame because any cell change can move
        // an image.
        if (state.terminal.screen.kitty_images.dirty or
            self.image_virtual)
        {
            try self.prepKittyGraphics(state.terminal);
        }

        // If we have any terminal dirty flags set then we need to rebuild
        // the entire screen. This can be optimized in the future.
        const full_rebuild: bool = rebuild: {
            {
                const Int = @typeInfo(terminal.Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(state.terminal.flags.dirty);
                if (v > 0) break :rebuild true;
            }
            {
                const Int = @typeInfo(terminal.Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(state.terminal.screen.dirty);
                if (v > 0) break :rebuild true;
            }

            // If our viewport changed then we need to rebuild the entire
            // screen because it means we scrolled. If we have no previous
            // viewport then we must rebuild.
            const prev_viewport = self.cells_viewport orelse break :rebuild true;
            if (!prev_viewport.eql(viewport_pin)) break :rebuild true;

            break :rebuild false;
        };

        // Reset the dirty flags in the terminal and screen. We assume
        // that our rebuild will be successful since so we optimize for
        // success and reset while we hold the lock. This is much easier
        // than coordinating row by row or as changes are persisted.
        state.terminal.flags.dirty = .{};
        state.terminal.screen.dirty = .{};
        {
            var it = state.terminal.screen.pages.pageIterator(
                .right_down,
                .{ .screen = .{} },
                null,
            );
            while (it.next()) |chunk| {
                var dirty_set = chunk.node.data.dirtyBitSet();
                dirty_set.unsetAll();
            }
        }

        break :critical .{
            .bg = self.background_color orelse self.default_background_color,
            .screen = screen_copy,
            .screen_type = state.terminal.active_screen,
            .mouse = state.mouse,
            .preedit = preedit,
            .cursor_style = cursor_style,
            .color_palette = state.terminal.color_palette.colors,
            .viewport_pin = viewport_pin,
            .full_rebuild = full_rebuild,
        };
    };
    defer {
        critical.screen.deinit();
        if (critical.preedit) |p| p.deinit(self.alloc);
    }

    // Build our GPU cells
    try self.rebuildCells(
        critical.full_rebuild,
        &critical.screen,
        critical.screen_type,
        critical.mouse,
        critical.preedit,
        critical.cursor_style,
        &critical.color_palette,
    );

    // Notify our shaper we're done for the frame. For some shapers like
    // CoreText this triggers off-thread cleanup logic.
    self.font_shaper.endFrame();

    // Update our viewport pin
    self.cells_viewport = critical.viewport_pin;

    // Update our background color
    self.uniforms.bg_color = .{
        critical.bg.r,
        critical.bg.g,
        critical.bg.b,
        @intFromFloat(@round(self.config.background_opacity * 255.0)),
    };

    // Update the background color on our layer
    //
    // TODO: Is this expensive? Should we be checking if our
    //       bg color has changed first before doing this work?
    {
        const color = graphics.c.CGColorCreate(
            @ptrCast(self.terminal_colorspace),
            &[4]f64{
                @as(f64, @floatFromInt(critical.bg.r)) / 255.0,
                @as(f64, @floatFromInt(critical.bg.g)) / 255.0,
                @as(f64, @floatFromInt(critical.bg.b)) / 255.0,
                self.config.background_opacity,
            },
        );
        defer graphics.c.CGColorRelease(color);

        // We use a CATransaction so that Core Animation knows that we
        // updated the background color property. Otherwise it behaves
        // weird, not updating the color until we resize.
        const CATransaction = objc.getClass("CATransaction").?;
        CATransaction.msgSend(void, "begin", .{});
        defer CATransaction.msgSend(void, "commit", .{});

        self.layer.setProperty("backgroundColor", color);
    }

    // Go through our images and see if we need to setup any textures.
    {
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            switch (kv.value_ptr.image) {
                .ready => {},

                .pending_gray,
                .pending_gray_alpha,
                .pending_rgb,
                .pending_rgba,
                .replace_gray,
                .replace_gray_alpha,
                .replace_rgb,
                .replace_rgba,
                => try kv.value_ptr.image.upload(
                    self.alloc,
                    self.gpu_state.device,
                    self.gpu_state.default_storage_mode,
                ),

                .unload_pending,
                .unload_replace,
                .unload_ready,
                => {
                    kv.value_ptr.image.deinit(self.alloc);
                    self.images.removeByPtr(kv.key_ptr);
                },
            }
        }
    }
}

/// Draw the frame to the screen.
pub fn drawFrame(self: *Metal, surface: *apprt.Surface) !void {
    _ = surface;

    // If we have no cells rebuilt we can usually skip drawing since there
    // is no changed data. However, if we have active animations we still
    // need to draw so that we can update the time uniform and render the
    // changes.
    if (!self.cells_rebuilt and !self.hasAnimations()) return;
    self.cells_rebuilt = false;

    // Wait for a frame to be available.
    const frame = self.gpu_state.nextFrame();
    errdefer self.gpu_state.releaseFrame();
    // log.debug("drawing frame index={}", .{self.gpu_state.frame_index});

    // Setup our frame data
    try frame.uniforms.sync(self.gpu_state.device, &.{self.uniforms});
    try frame.cells_bg.sync(self.gpu_state.device, self.cells.bg_cells);
    const fg_count = try frame.cells.syncFromArrayLists(self.gpu_state.device, self.cells.fg_rows.lists);

    // If we have custom shaders, update the animation time.
    if (self.custom_shader_state) |*state| {
        const now = std.time.Instant.now() catch state.first_frame_time;
        const since_ns: f32 = @floatFromInt(now.since(state.first_frame_time));
        const delta_ns: f32 = @floatFromInt(now.since(state.last_frame_time));
        state.uniforms.time = since_ns / std.time.ns_per_s;
        state.uniforms.time_delta = delta_ns / std.time.ns_per_s;
        state.last_frame_time = now;
    }

    // @autoreleasepool {}
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Get our drawable (CAMetalDrawable)
    const drawable = self.layer.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // Get our screen texture. If we don't have a dedicated screen texture
    // then we just use the drawable texture.
    const screen_texture = if (self.custom_shader_state) |state|
        state.back_texture
    else tex: {
        const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
        break :tex objc.Object.fromId(texture);
    };

    // If our font atlas changed, sync the texture data
    texture: {
        const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
        if (modified <= frame.grayscale_modified) break :texture;
        self.font_grid.lock.lockShared();
        defer self.font_grid.lock.unlockShared();
        frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
        try syncAtlasTexture(
            self.gpu_state.device,
            &self.font_grid.atlas_grayscale,
            &frame.grayscale,
            self.gpu_state.default_storage_mode,
        );
    }
    texture: {
        const modified = self.font_grid.atlas_color.modified.load(.monotonic);
        if (modified <= frame.color_modified) break :texture;
        self.font_grid.lock.lockShared();
        defer self.font_grid.lock.unlockShared();
        frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
        try syncAtlasTexture(
            self.gpu_state.device,
            &self.font_grid.atlas_color,
            &frame.color,
            self.gpu_state.default_storage_mode,
        );
    }

    // Command buffer (MTLCommandBuffer)
    const buffer = self.gpu_state.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});

    {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
            const desc = MTLRenderPassDescriptor.msgSend(
                objc.Object,
                objc.sel("renderPassDescriptor"),
                .{},
            );

            // Set our color attachment to be our drawable surface.
            const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
            {
                const attachment = attachments.msgSend(
                    objc.Object,
                    objc.sel("objectAtIndexedSubscript:"),
                    .{@as(c_ulong, 0)},
                );

                attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
                attachment.setProperty("texture", screen_texture.value);
                attachment.setProperty("clearColor", mtl.MTLClearColor{
                    .red = 0.0,
                    .green = 0.0,
                    .blue = 0.0,
                    .alpha = 0.0,
                });
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

        // Draw background images first
        try self.drawImagePlacements(encoder, frame, self.image_placements.items[0..self.image_bg_end]);

        // Then draw background cells
        try self.drawCellBgs(encoder, frame);

        // Then draw images under text
        try self.drawImagePlacements(encoder, frame, self.image_placements.items[self.image_bg_end..self.image_text_end]);

        // Then draw fg cells
        try self.drawCellFgs(encoder, frame, fg_count);

        // Then draw remaining images
        try self.drawImagePlacements(encoder, frame, self.image_placements.items[self.image_text_end..]);
    }

    // If we have custom shaders, then we render them.
    if (self.custom_shader_state) |*state| {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
            const desc = MTLRenderPassDescriptor.msgSend(
                objc.Object,
                objc.sel("renderPassDescriptor"),
                .{},
            );

            break :desc desc;
        };

        // Prepare our color attachment (output).
        const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );
        attachment.setProperty("loadAction", @intFromEnum(mtl.MTLLoadAction.clear));
        attachment.setProperty("storeAction", @intFromEnum(mtl.MTLStoreAction.store));
        attachment.setProperty("clearColor", mtl.MTLClearColor{
            .red = 0,
            .green = 0,
            .blue = 0,
            .alpha = 1,
        });

        const post_len = self.shaders.post_pipelines.len;

        for (self.shaders.post_pipelines[0 .. post_len - 1]) |pipeline| {
            // Set our color attachment to be our front texture.
            attachment.setProperty("texture", state.front_texture.value);

            // MTLRenderCommandEncoder
            const encoder = buffer.msgSend(
                objc.Object,
                objc.sel("renderCommandEncoderWithDescriptor:"),
                .{desc.value},
            );
            defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

            // Draw shader
            try self.drawPostShader(encoder, pipeline, state);
            // Swap the front and back textures.
            state.swap();
        }

        // Draw the final shader directly to the drawable.
        {
            // Set our color attachment to be our drawable.
            //
            // Texture is a property of CAMetalDrawable but if you run
            // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
            // which ironically doesn't implement CAMetalDrawable as a
            // property so we just send a message.
            const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
            attachment.setProperty("texture", texture);

            // MTLRenderCommandEncoder
            const encoder = buffer.msgSend(
                objc.Object,
                objc.sel("renderCommandEncoderWithDescriptor:"),
                .{desc.value},
            );
            defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

            try self.drawPostShader(
                encoder,
                self.shaders.post_pipelines[post_len - 1],
                state,
            );
        }
    }

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable.value});

    // Create our block to register for completion updates. This is used
    // so we can detect failures. The block is deallocated by the objC
    // runtime on success.
    const block = try CompletionBlock.init(.{ .self = self }, &bufferCompleted);
    errdefer block.deinit();
    buffer.msgSend(void, objc.sel("addCompletedHandler:"), .{block.context});

    buffer.msgSend(void, objc.sel("commit"), .{});
}

/// This is the block type used for the addCompletedHandler call.back.
const CompletionBlock = objc.Block(struct { self: *Metal }, .{
    objc.c.id, // MTLCommandBuffer
}, void);

/// This is the callback called by the CompletionBlock invocation for
/// addCompletedHandler.
///
/// Note: this is USUALLY called on a separate thread because the renderer
/// thread and the Apple event loop threads are usually different. Therefore,
/// we need to be mindful of thread safety here.
fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.C) void {
    const self = block.self;
    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status. If it is anything other than error
    // then we don't care and just return right away. We're looking for
    // errors so that we can log them.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    // If our health value hasn't changed, then we do nothing. We don't
    // do a cmpxchg here because strict atomicity isn't important.
    if (self.health.load(.seq_cst) != health) {
        self.health.store(health, .seq_cst);

        // Our health value changed, so we notify the surface so that it
        // can do something about it.
        _ = self.surface_mailbox.push(.{
            .renderer_health = health,
        }, .{ .forever = {} });
    }

    // Always release our semaphore
    self.gpu_state.releaseFrame();
}

fn drawPostShader(
    self: *Metal,
    encoder: objc.Object,
    pipeline: objc.Object,
    state: *const CustomShaderState,
) !void {
    _ = self;

    // Use our custom shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{pipeline.value},
    );

    // Set our sampler
    encoder.msgSend(
        void,
        objc.sel("setFragmentSamplerState:atIndex:"),
        .{ state.sampler.sampler.value, @as(c_ulong, 0) },
    );

    // Set our uniforms
    encoder.msgSend(
        void,
        objc.sel("setFragmentBytes:length:atIndex:"),
        .{
            @as(*const anyopaque, @ptrCast(&state.uniforms)),
            @as(c_ulong, @sizeOf(@TypeOf(state.uniforms))),
            @as(c_ulong, 0),
        },
    );

    // Screen texture
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            state.back_texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 3),
        },
    );
}

fn drawImagePlacements(
    self: *Metal,
    encoder: objc.Object,
    frame: *const FrameState,
    placements: []const mtl_image.Placement,
) !void {
    if (placements.len == 0) return;

    // Use our image shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.image_pipeline.value},
    );

    // Set our uniforms
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );

    for (placements) |placement| {
        try self.drawImagePlacement(encoder, placement);
    }
}

fn drawImagePlacement(
    self: *Metal,
    encoder: objc.Object,
    p: mtl_image.Placement,
) !void {
    // Look up the image
    const image = self.images.get(p.image_id) orelse {
        log.warn("image not found for placement image_id={}", .{p.image_id});
        return;
    };

    // Get the texture
    const texture = switch (image.image) {
        .ready => |t| t,
        else => {
            log.warn("image not ready for placement image_id={}", .{p.image_id});
            return;
        },
    };

    // Create our vertex buffer, which is always exactly one item.
    // future(mitchellh): we can group rendering multiple instances of a single image
    const Buffer = mtl_buffer.Buffer(mtl_shaders.Image);
    var buf = try Buffer.initFill(self.gpu_state.device, &.{.{
        .grid_pos = .{
            @as(f32, @floatFromInt(p.x)),
            @as(f32, @floatFromInt(p.y)),
        },

        .cell_offset = .{
            @as(f32, @floatFromInt(p.cell_offset_x)),
            @as(f32, @floatFromInt(p.cell_offset_y)),
        },

        .source_rect = .{
            @as(f32, @floatFromInt(p.source_x)),
            @as(f32, @floatFromInt(p.source_y)),
            @as(f32, @floatFromInt(p.source_width)),
            @as(f32, @floatFromInt(p.source_height)),
        },

        .dest_size = .{
            @as(f32, @floatFromInt(p.width)),
            @as(f32, @floatFromInt(p.height)),
        },
    }}, .{
        // Indicate that the CPU writes to this resource but never reads it.
        .cpu_cache_mode = .write_combined,
        .storage_mode = self.gpu_state.default_storage_mode,
    });
    defer buf.deinit();

    // Set our buffer
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ buf.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );

    // Set our texture
    encoder.msgSend(
        void,
        objc.sel("setVertexTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{
            texture.value,
            @as(c_ulong, 0),
        },
    );

    // Draw!
    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.gpu_state.instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, 1),
        },
    );

    // log.debug("drawImagePlacement: {}", .{p});
}

/// Draw the cell backgrounds.
fn drawCellBgs(
    self: *Metal,
    encoder: objc.Object,
    frame: *const FrameState,
) !void {
    // Use our shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.cell_bg_pipeline.value},
    );

    // Set our buffers
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentBuffer:offset:atIndex:"),
        .{ frame.cells_bg.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );

    encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 0),
            @as(c_ulong, 3),
        },
    );
}

/// Draw the cell foregrounds using the text shader.
fn drawCellFgs(
    self: *Metal,
    encoder: objc.Object,
    frame: *const FrameState,
    len: usize,
) !void {
    // This triggers an assertion in the Metal API if we try to draw
    // with an instance count of 0 so just bail.
    if (len == 0) return;

    // Use our shader pipeline
    encoder.msgSend(
        void,
        objc.sel("setRenderPipelineState:"),
        .{self.shaders.cell_text_pipeline.value},
    );

    // Set our buffers
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.cells.buffer.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 1) },
    );
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ frame.cells_bg.buffer.value, @as(c_ulong, 0), @as(c_ulong, 2) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{ frame.grayscale.value, @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{ frame.color.value, @as(c_ulong, 1) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentBuffer:offset:atIndex:"),
        .{ frame.uniforms.buffer.value, @as(c_ulong, 0), @as(c_ulong, 2) },
    );

    encoder.msgSend(
        void,
        objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
        .{
            @intFromEnum(mtl.MTLPrimitiveType.triangle),
            @as(c_ulong, 6),
            @intFromEnum(mtl.MTLIndexType.uint16),
            self.gpu_state.instance.buffer.value,
            @as(c_ulong, 0),
            @as(c_ulong, len),
        },
    );
}

/// This goes through the Kitty graphic placements and accumulates the
/// placements we need to render on our viewport. It also ensures that
/// the visible images are loaded on the GPU.
fn prepKittyGraphics(
    self: *Metal,
    t: *terminal.Terminal,
) !void {
    const storage = &t.screen.kitty_images;
    defer storage.dirty = false;

    // We always clear our previous placements no matter what because
    // we rebuild them from scratch.
    self.image_placements.clearRetainingCapacity();
    self.image_virtual = false;

    // Go through our known images and if there are any that are no longer
    // in use then mark them to be freed.
    //
    // This never conflicts with the below because a placement can't
    // reference an image that doesn't exist.
    {
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (storage.imageById(kv.key_ptr.*) == null) {
                kv.value_ptr.image.markForUnload();
            }
        }
    }

    // The top-left and bottom-right corners of our viewport in screen
    // points. This lets us determine offsets and containment of placements.
    const top = t.screen.pages.getTopLeft(.viewport);
    const bot = t.screen.pages.getBottomRight(.viewport).?;

    // Go through the placements and ensure the image is loaded on the GPU.
    var it = storage.placements.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr;

        // Special logic based on location
        switch (p.location) {
            .pin => {},
            .virtual => {
                // We need to mark virtual placements on our renderer so that
                // we know to rebuild in more scenarios since cell changes can
                // now trigger placement changes.
                self.image_virtual = true;

                // We also continue out because virtual placements are
                // only triggered by the unicode placeholder, not by the
                // placement itself.
                continue;
            },
        }

        // Get the image for the placement
        const image = storage.imageById(kv.key_ptr.image_id) orelse {
            log.warn(
                "missing image for placement, ignoring image_id={}",
                .{kv.key_ptr.image_id},
            );
            continue;
        };

        try self.prepKittyPlacement(t, &top, &bot, &image, p);
    }

    // If we have virtual placements then we need to scan for placeholders.
    if (self.image_virtual) {
        var v_it = terminal.kitty.graphics.unicode.placementIterator(top, bot);
        while (v_it.next()) |virtual_p| try self.prepKittyVirtualPlacement(
            t,
            &virtual_p,
        );
    }

    // Sort the placements by their Z value.
    std.mem.sortUnstable(
        mtl_image.Placement,
        self.image_placements.items,
        {},
        struct {
            fn lessThan(
                ctx: void,
                lhs: mtl_image.Placement,
                rhs: mtl_image.Placement,
            ) bool {
                _ = ctx;
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan,
    );

    // Find our indices. The values are sorted by z so we can find the
    // first placement out of bounds to find the limits.
    var bg_end: ?u32 = null;
    var text_end: ?u32 = null;
    const bg_limit = std.math.minInt(i32) / 2;
    for (self.image_placements.items, 0..) |p, i| {
        if (bg_end == null and p.z >= bg_limit) {
            bg_end = @intCast(i);
        }
        if (text_end == null and p.z >= 0) {
            text_end = @intCast(i);
        }
    }

    self.image_bg_end = bg_end orelse 0;
    self.image_text_end = text_end orelse self.image_bg_end;
}

fn prepKittyVirtualPlacement(
    self: *Metal,
    t: *terminal.Terminal,
    p: *const terminal.kitty.graphics.unicode.Placement,
) !void {
    const storage = &t.screen.kitty_images;
    const image = storage.imageById(p.image_id) orelse {
        log.warn(
            "missing image for virtual placement, ignoring image_id={}",
            .{p.image_id},
        );
        return;
    };

    const rp = p.renderPlacement(
        storage,
        &image,
        self.grid_metrics.cell_width,
        self.grid_metrics.cell_height,
    ) catch |err| {
        log.warn("error rendering virtual placement err={}", .{err});
        return;
    };

    // If our placement is zero sized then we don't do anything.
    if (rp.dest_width == 0 or rp.dest_height == 0) return;

    const viewport: terminal.point.Point = t.screen.pages.pointFromPin(
        .viewport,
        rp.top_left,
    ) orelse {
        // This is unreachable with virtual placements because we should
        // only ever be looking at virtual placements that are in our
        // viewport in the renderer and virtual placements only ever take
        // up one row.
        unreachable;
    };

    // Send our image to the GPU and store the placement for rendering.
    try self.prepKittyImage(&image);
    try self.image_placements.append(self.alloc, .{
        .image_id = image.id,
        .x = @intCast(rp.top_left.x),
        .y = @intCast(viewport.viewport.y),
        .z = -1,
        .width = rp.dest_width,
        .height = rp.dest_height,
        .cell_offset_x = rp.offset_x,
        .cell_offset_y = rp.offset_y,
        .source_x = rp.source_x,
        .source_y = rp.source_y,
        .source_width = rp.source_width,
        .source_height = rp.source_height,
    });
}

fn prepKittyPlacement(
    self: *Metal,
    t: *terminal.Terminal,
    top: *const terminal.Pin,
    bot: *const terminal.Pin,
    image: *const terminal.kitty.graphics.Image,
    p: *const terminal.kitty.graphics.ImageStorage.Placement,
) !void {
    // Get the rect for the placement. If this placement doesn't have
    // a rect then its virtual or something so skip it.
    const rect = p.rect(image.*, t) orelse return;

    // If the selection isn't within our viewport then skip it.
    if (bot.before(rect.top_left)) return;
    if (rect.bottom_right.before(top.*)) return;

    // If the top left is outside the viewport we need to calc an offset
    // so that we render (0, 0) with some offset for the texture.
    const offset_y: u32 = if (rect.top_left.before(top.*)) offset_y: {
        const vp_y = t.screen.pages.pointFromPin(.screen, top.*).?.screen.y;
        const img_y = t.screen.pages.pointFromPin(.screen, rect.top_left).?.screen.y;
        const offset_cells = vp_y - img_y;
        const offset_pixels = offset_cells * self.grid_metrics.cell_height;
        break :offset_y @intCast(offset_pixels);
    } else 0;

    // Get the grid size that respects aspect ratio
    const grid_size = p.gridSize(image.*, t);

    // If we specify `rows` then our offset above is in viewport space
    // and not in the coordinate space of the source image. Without `rows`
    // that's one and the same.
    const source_offset_y: u32 = if (grid_size.rows > 0) source_offset_y: {
        // Determine the scale factor to apply for this row height.
        const image_height: f64 = @floatFromInt(image.height);
        const viewport_height: f64 = @floatFromInt(grid_size.rows * self.grid_metrics.cell_height);
        const scale: f64 = image_height / viewport_height;

        // Apply the scale to the offset
        const offset_y_f64: f64 = @floatFromInt(offset_y);
        const source_offset_y_f64: f64 = offset_y_f64 * scale;
        break :source_offset_y @intFromFloat(@round(source_offset_y_f64));
    } else offset_y;

    // We need to prep this image for upload if it isn't in the cache OR
    // it is in the cache but the transmit time doesn't match meaning this
    // image is different.
    try self.prepKittyImage(image);

    // Convert our screen point to a viewport point
    const viewport: terminal.point.Point = t.screen.pages.pointFromPin(
        .viewport,
        rect.top_left,
    ) orelse .{ .viewport = .{} };

    // Calculate the source rectangle
    const source_x = @min(image.width, p.source_x);
    const source_y = @min(image.height, p.source_y + source_offset_y);
    const source_width = if (p.source_width > 0)
        @min(image.width - source_x, p.source_width)
    else
        image.width;
    const source_height = if (p.source_height > 0)
        @min(image.height, p.source_height)
    else
        image.height -| source_y;

    // Calculate the width/height of our image.
    const dest_width = grid_size.cols * self.grid_metrics.cell_width;
    const dest_height = if (grid_size.rows > 0) rows: {
        // Clip to the viewport to handle scrolling. offset_y is already in
        // viewport scale so we can subtract it directly.
        break :rows (grid_size.rows * self.grid_metrics.cell_height) - offset_y;
    } else source_height;

    // Accumulate the placement
    if (image.width > 0 and image.height > 0) {
        try self.image_placements.append(self.alloc, .{
            .image_id = image.id,
            .x = @intCast(rect.top_left.x),
            .y = @intCast(viewport.viewport.y),
            .z = p.z,
            .width = dest_width,
            .height = dest_height,
            .cell_offset_x = p.x_offset,
            .cell_offset_y = p.y_offset,
            .source_x = source_x,
            .source_y = source_y,
            .source_width = source_width,
            .source_height = source_height,
        });
    }
}

fn prepKittyImage(
    self: *Metal,
    image: *const terminal.kitty.graphics.Image,
) !void {
    // If this image exists and its transmit time is the same we assume
    // it is the identical image so we don't need to send it to the GPU.
    const gop = try self.images.getOrPut(self.alloc, image.id);
    if (gop.found_existing and
        gop.value_ptr.transmit_time.order(image.transmit_time) == .eq)
    {
        return;
    }

    // Copy the data into the pending state.
    const data = try self.alloc.dupe(u8, image.data);
    errdefer self.alloc.free(data);

    // Store it in the map
    const pending: Image.Pending = .{
        .width = image.width,
        .height = image.height,
        .data = data.ptr,
    };

    const new_image: Image = switch (image.format) {
        .gray => .{ .pending_gray = pending },
        .gray_alpha => .{ .pending_gray_alpha = pending },
        .rgb => .{ .pending_rgb = pending },
        .rgba => .{ .pending_rgba = pending },
        .png => unreachable, // should be decoded by now
    };

    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .image = new_image,
            .transmit_time = undefined,
        };
    } else {
        try gop.value_ptr.image.markForReplace(
            self.alloc,
            new_image,
        );
    }

    gop.value_ptr.transmit_time = image.transmit_time;
}

/// Update the configuration.
pub fn changeConfig(self: *Metal, config: *DerivedConfig) !void {
    // We always redo the font shaper in case font features changed. We
    // could check to see if there was an actual config change but this is
    // easier and rare enough to not cause performance issues.
    {
        var font_shaper = try font.Shaper.init(self.alloc, .{
            .features = config.font_features.items,
        });
        errdefer font_shaper.deinit();
        self.font_shaper.deinit();
        self.font_shaper = font_shaper;
    }

    // We also need to reset the shaper cache so shaper info
    // from the previous font isn't re-used for the new font.
    const font_shaper_cache = font.ShaperCache.init();
    self.font_shaper_cache.deinit(self.alloc);
    self.font_shaper_cache = font_shaper_cache;

    // Set our new minimum contrast
    self.uniforms.min_contrast = config.min_contrast;

    // Set our new color space and blending
    self.uniforms.use_display_p3 = config.colorspace == .@"display-p3";
    self.uniforms.use_linear_blending = config.blending.isLinear();
    self.uniforms.use_linear_correction = config.blending == .@"linear-corrected";

    // Set our new colors
    self.default_background_color = config.background;
    self.default_foreground_color = config.foreground;
    self.default_cursor_color = if (!config.cursor_invert) config.cursor_color else null;
    self.cursor_invert = config.cursor_invert;

    // Update our layer's opaqueness and display sync in case they changed.
    {
        // We use a CATransaction so that Core Animation knows that we
        // updated the opaque property. Otherwise it behaves weird, not
        // properly going from opaque to transparent unless we resize.
        const CATransaction = objc.getClass("CATransaction").?;
        CATransaction.msgSend(void, "begin", .{});
        defer CATransaction.msgSend(void, "commit", .{});

        self.layer.setProperty("opaque", config.background_opacity >= 1);
        self.layer.setProperty("displaySyncEnabled", config.vsync);
    }

    // Update our terminal colorspace if it changed
    if (self.config.colorspace != config.colorspace) {
        const terminal_colorspace = try graphics.ColorSpace.createNamed(
            switch (config.colorspace) {
                .@"display-p3" => .displayP3,
                .srgb => .sRGB,
            },
        );
        errdefer terminal_colorspace.release();
        self.terminal_colorspace.release();
        self.terminal_colorspace = terminal_colorspace;
    }

    const old_blending = self.config.blending;
    const old_custom_shaders = self.config.custom_shaders;

    self.config.deinit();
    self.config = config.*;

    // Reset our viewport to force a rebuild, in case of a font change.
    self.cells_viewport = null;

    // We reinitialize our shaders if our
    // blending or custom shaders changed.
    if (old_blending != config.blending or
        !old_custom_shaders.equal(config.custom_shaders))
    {
        self.deinitShaders();
        try self.initShaders();
        // We call setScreenSize to reinitialize
        // the textures used for custom shaders.
        if (self.custom_shader_state != null) {
            try self.setScreenSize(self.size);
        }
        // And we update our layer's pixel format appropriately.
        self.layer.setProperty(
            "pixelFormat",
            if (config.blending.isLinear())
                @intFromEnum(mtl.MTLPixelFormat.bgra8unorm_srgb)
            else
                @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
        );
    }
}

/// Resize the screen.
pub fn setScreenSize(
    self: *Metal,
    size: renderer.Size,
) !void {
    // Store our sizes
    self.size = size;
    const grid_size = size.grid();
    const terminal_size = size.terminal();

    // Blank space around the grid.
    const blank: renderer.Padding = size.screen.blankPadding(
        size.padding,
        grid_size,
        size.cell,
    ).add(size.padding);

    var padding_extend = self.uniforms.padding_extend;
    switch (self.config.padding_color) {
        .extend => {
            // If padding extension is enabled, we extend left and right always
            // because there is no downside to this. Up/down is dependent
            // on some heuristics (see rebuildCells).
            padding_extend.left = true;
            padding_extend.right = true;
        },

        .@"extend-always" => {
            padding_extend.up = true;
            padding_extend.down = true;
            padding_extend.left = true;
            padding_extend.right = true;
        },

        .background => {
            // Otherwise, disable all padding extension.
            padding_extend = .{};
        },
    }

    // Set the size of the drawable surface to the bounds
    self.layer.setProperty("drawableSize", graphics.Size{
        .width = @floatFromInt(size.screen.width),
        .height = @floatFromInt(size.screen.height),
    });

    // Setup our uniforms
    const old = self.uniforms;
    self.uniforms = .{
        .projection_matrix = math.ortho2d(
            -1 * @as(f32, @floatFromInt(size.padding.left)),
            @floatFromInt(terminal_size.width + size.padding.right),
            @floatFromInt(terminal_size.height + size.padding.bottom),
            -1 * @as(f32, @floatFromInt(size.padding.top)),
        ),
        .cell_size = .{
            @floatFromInt(self.grid_metrics.cell_width),
            @floatFromInt(self.grid_metrics.cell_height),
        },
        .grid_size = .{
            grid_size.columns,
            grid_size.rows,
        },
        .grid_padding = .{
            @floatFromInt(blank.top),
            @floatFromInt(blank.right),
            @floatFromInt(blank.bottom),
            @floatFromInt(blank.left),
        },
        .padding_extend = padding_extend,
        .min_contrast = old.min_contrast,
        .cursor_pos = old.cursor_pos,
        .cursor_color = old.cursor_color,
        .bg_color = old.bg_color,
        .cursor_wide = old.cursor_wide,
        .use_display_p3 = old.use_display_p3,
        .use_linear_blending = old.use_linear_blending,
        .use_linear_correction = old.use_linear_correction,
    };

    // Reset our cell contents if our grid size has changed.
    if (!self.cells.size.equals(grid_size)) {
        try self.cells.resize(self.alloc, grid_size);

        // Reset our viewport to force a rebuild
        self.cells_viewport = null;
    }

    // If we have custom shaders then we update the state
    if (self.custom_shader_state) |*state| {
        // Only free our previous texture if this isn't our first
        // time setting the custom shader state.
        if (state.uniforms.resolution[0] > 0) {
            state.front_texture.release();
            state.back_texture.release();
        }

        state.uniforms.resolution = .{
            @floatFromInt(size.screen.width),
            @floatFromInt(size.screen.height),
            1,
        };

        state.front_texture = texture: {
            // This texture is the size of our drawable but supports being a
            // render target AND reading so that the custom shaders can read from it.
            const desc = init: {
                const Class = objc.getClass("MTLTextureDescriptor").?;
                const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
                const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
                break :init id_init;
            };
            desc.setProperty(
                "pixelFormat",
                // Using an `*_srgb` pixel format makes Metal gamma encode
                // the pixels written to it *after* blending, which means
                // we get linear alpha blending rather than gamma-incorrect
                // blending.
                if (self.config.blending.isLinear())
                    @intFromEnum(mtl.MTLPixelFormat.bgra8unorm_srgb)
                else
                    @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
            );
            desc.setProperty("width", @as(c_ulong, @intCast(size.screen.width)));
            desc.setProperty("height", @as(c_ulong, @intCast(size.screen.height)));
            desc.setProperty(
                "usage",
                @intFromEnum(mtl.MTLTextureUsage.render_target) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_read) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_write),
            );

            // If we fail to create the texture, then we just don't have a screen
            // texture and our custom shaders won't run.
            const id = self.gpu_state.device.msgSend(
                ?*anyopaque,
                objc.sel("newTextureWithDescriptor:"),
                .{desc},
            ) orelse return error.MetalFailed;

            break :texture objc.Object.fromId(id);
        };

        state.back_texture = texture: {
            // This texture is the size of our drawable but supports being a
            // render target AND reading so that the custom shaders can read from it.
            const desc = init: {
                const Class = objc.getClass("MTLTextureDescriptor").?;
                const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
                const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
                break :init id_init;
            };
            desc.setProperty(
                "pixelFormat",
                // Using an `*_srgb` pixel format makes Metal gamma encode
                // the pixels written to it *after* blending, which means
                // we get linear alpha blending rather than gamma-incorrect
                // blending.
                if (self.config.blending.isLinear())
                    @intFromEnum(mtl.MTLPixelFormat.bgra8unorm_srgb)
                else
                    @intFromEnum(mtl.MTLPixelFormat.bgra8unorm),
            );
            desc.setProperty("width", @as(c_ulong, @intCast(size.screen.width)));
            desc.setProperty("height", @as(c_ulong, @intCast(size.screen.height)));
            desc.setProperty(
                "usage",
                @intFromEnum(mtl.MTLTextureUsage.render_target) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_read) |
                    @intFromEnum(mtl.MTLTextureUsage.shader_write),
            );

            // If we fail to create the texture, then we just don't have a screen
            // texture and our custom shaders won't run.
            const id = self.gpu_state.device.msgSend(
                ?*anyopaque,
                objc.sel("newTextureWithDescriptor:"),
                .{desc},
            ) orelse return error.MetalFailed;

            break :texture objc.Object.fromId(id);
        };
    }

    log.debug("screen size size={}", .{size});
}

/// Convert the terminal state to GPU cells stored in CPU memory. These
/// are then synced to the GPU in the next frame. This only updates CPU
/// memory and doesn't touch the GPU.
fn rebuildCells(
    self: *Metal,
    rebuild: bool,
    screen: *terminal.Screen,
    screen_type: terminal.ScreenType,
    mouse: renderer.State.Mouse,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
    color_palette: *const terminal.color.Palette,
) !void {
    // const start = try std.time.Instant.now();
    // const start_micro = std.time.microTimestamp();
    // defer {
    //     const end = std.time.Instant.now() catch unreachable;
    //     // "[rebuildCells time] <START us>\t<TIME_TAKEN us>"
    //     std.log.warn("[rebuildCells time] {}\t{}", .{start_micro, end.since(start) / std.time.ns_per_us});
    // }

    _ = screen_type; // we might use this again later so not deleting it yet

    // Create an arena for all our temporary allocations while rebuilding
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Create our match set for the links.
    var link_match_set: link.MatchSet = if (mouse.point) |mouse_pt| try self.config.links.matchSet(
        arena_alloc,
        screen,
        mouse_pt,
        mouse.mods,
    ) else .{};

    // Determine our x/y range for preedit. We don't want to render anything
    // here because we will render the preedit separately.
    const preedit_range: ?struct {
        y: terminal.size.CellCountInt,
        x: [2]terminal.size.CellCountInt,
        cp_offset: usize,
    } = if (preedit) |preedit_v| preedit: {
        const range = preedit_v.range(screen.cursor.x, screen.pages.cols - 1);
        break :preedit .{
            .y = screen.cursor.y,
            .x = .{ range.start, range.end },
            .cp_offset = range.cp_offset,
        };
    } else null;

    if (rebuild) {
        // If we are doing a full rebuild, then we clear the entire cell buffer.
        self.cells.reset();

        // We also reset our padding extension depending on the screen type
        switch (self.config.padding_color) {
            .background => {},

            // For extension, assume we are extending in all directions.
            // For "extend" this may be disabled due to heuristics below.
            .extend, .@"extend-always" => {
                self.uniforms.padding_extend = .{
                    .up = true,
                    .down = true,
                    .left = true,
                    .right = true,
                };
            },
        }
    }

    // We rebuild the cells row-by-row because we
    // do font shaping and dirty tracking by row.
    var row_it = screen.pages.rowIterator(.left_up, .{ .viewport = .{} }, null);
    // If our cell contents buffer is shorter than the screen viewport,
    // we render the rows that fit, starting from the bottom. If instead
    // the viewport is shorter than the cell contents buffer, we align
    // the top of the viewport with the top of the contents buffer.
    var y: terminal.size.CellCountInt = @min(
        screen.pages.rows,
        self.cells.size.rows,
    );
    while (row_it.next()) |row| {
        // The viewport may have more rows than our cell contents,
        // so we need to break from the loop early if we hit y = 0.
        if (y == 0) break;

        y -= 1;

        if (!rebuild) {
            // Only rebuild if we are doing a full rebuild or this row is dirty.
            if (!row.isDirty()) continue;

            // Clear the cells if the row is dirty
            self.cells.clear(y);
        }

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // We need to get this row's selection if there is one for proper
        // run splitting.
        const row_selection = sel: {
            const sel = screen.selection orelse break :sel null;
            const pin = screen.pages.pin(.{ .viewport = .{ .y = y } }) orelse
                break :sel null;
            break :sel sel.containedRow(screen, pin) orelse null;
        };

        // On primary screen, we still apply vertical padding extension
        // under certain conditions we feel are safe. This helps make some
        // scenarios look better while avoiding scenarios we know do NOT look
        // good.
        switch (self.config.padding_color) {
            // These already have the correct values set above.
            .background, .@"extend-always" => {},

            // Apply heuristics for padding extension.
            .extend => if (y == 0) {
                self.uniforms.padding_extend.up = !row.neverExtendBg(
                    color_palette,
                    self.background_color orelse self.default_background_color,
                );
            } else if (y == self.cells.size.rows - 1) {
                self.uniforms.padding_extend.down = !row.neverExtendBg(
                    color_palette,
                    self.background_color orelse self.default_background_color,
                );
            },
        }

        // Iterator of runs for shaping.
        var run_iter = self.font_shaper.runIterator(
            self.font_grid,
            screen,
            row,
            row_selection,
            if (shape_cursor) screen.cursor.x else null,
        );
        var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
        var shaper_cells: ?[]const font.shape.Cell = null;
        var shaper_cells_i: usize = 0;

        const row_cells_all = row.cells(.all);

        // If our viewport is wider than our cell contents buffer,
        // we still only process cells up to the width of the buffer.
        const row_cells = row_cells_all[0..@min(row_cells_all.len, self.cells.size.columns)];

        for (row_cells, 0..) |*cell, x| {
            // If this cell falls within our preedit range then we
            // skip this because preedits are setup separately.
            if (preedit_range) |range| preedit: {
                // We're not on the preedit line, no actions necessary.
                if (range.y != y) break :preedit;
                // We're before the preedit range, no actions necessary.
                if (x < range.x[0]) break :preedit;
                // We're in the preedit range, skip this cell.
                if (x <= range.x[1]) continue;
                // After exiting the preedit range we need to catch
                // the run position up because of the missed cells.
                // In all other cases, no action is necessary.
                if (x != range.x[1] + 1) break :preedit;

                // Step the run iterator until we find a run that ends
                // after the current cell, which will be the soonest run
                // that might contain glyphs for our cell.
                while (shaper_run) |run| {
                    if (run.offset + run.cells > x) break;
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }

                const run = shaper_run orelse break :preedit;

                // If we haven't shaped this run, do so now.
                shaper_cells = shaper_cells orelse
                    // Try to read the cells from the shaping cache if we can.
                    self.font_shaper_cache.get(run) orelse
                    cache: {
                        // Otherwise we have to shape them.
                        const cells = try self.font_shaper.shape(run);

                        // Try to cache them. If caching fails for any reason we
                        // continue because it is just a performance optimization,
                        // not a correctness issue.
                        self.font_shaper_cache.put(
                            self.alloc,
                            run,
                            cells,
                        ) catch |err| {
                            log.warn(
                                "error caching font shaping results err={}",
                                .{err},
                            );
                        };

                        // The cells we get from direct shaping are always owned
                        // by the shaper and valid until the next shaping call so
                        // we can safely use them.
                        break :cache cells;
                    };

                // Advance our index until we reach or pass
                // our current x position in the shaper cells.
                while (shaper_cells.?[shaper_cells_i].x < x) {
                    shaper_cells_i += 1;
                }
            }

            const wide = cell.wide;

            const style = row.style(cell);

            const cell_pin: terminal.Pin = cell: {
                var copy = row;
                copy.x = @intCast(x);
                break :cell copy;
            };

            // True if this cell is selected
            const selected: bool = if (screen.selection) |sel|
                sel.contains(screen, .{
                    .node = row.node,
                    .y = row.y,
                    .x = @intCast(
                        // Spacer tails should show the selection
                        // state of the wide cell they belong to.
                        if (wide == .spacer_tail)
                            x -| 1
                        else
                            x,
                    ),
                })
            else
                false;

            const bg_style = style.bg(cell, color_palette);
            const fg_style = style.fg(color_palette, self.config.bold_is_bright) orelse self.foreground_color orelse self.default_foreground_color;

            // The final background color for the cell.
            const bg = bg: {
                if (selected) {
                    break :bg if (self.config.invert_selection_fg_bg)
                        if (style.flags.inverse)
                            // Cell is selected with invert selection fg/bg
                            // enabled, and the cell has the inverse style
                            // flag, so they cancel out and we get the normal
                            // bg color.
                            bg_style
                        else
                            // If it doesn't have the inverse style
                            // flag then we use the fg color instead.
                            fg_style
                    else
                        // If we don't have invert selection fg/bg set then we
                        // just use the selection background if set, otherwise
                        // the default fg color.
                        break :bg self.config.selection_background orelse self.foreground_color orelse self.default_foreground_color;
                }

                // Not selected
                break :bg if (style.flags.inverse != isCovering(cell.codepoint()))
                    // Two cases cause us to invert (use the fg color as the bg)
                    // - The "inverse" style flag.
                    // - A "covering" glyph; we use fg for bg in that case to
                    //   help make sure that padding extension works correctly.
                    // If one of these is true (but not the other)
                    // then we use the fg style color for the bg.
                    fg_style
                else
                    // Otherwise they cancel out.
                    bg_style;
            };

            const fg = fg: {
                if (selected and !self.config.invert_selection_fg_bg) {
                    // If we don't have invert selection fg/bg set
                    // then we just use the selection foreground if
                    // set, otherwise the default bg color.
                    break :fg self.config.selection_foreground orelse self.background_color orelse self.default_background_color;
                }

                // Whether we need to use the bg color as our fg color:
                // - Cell is inverted and not selected
                // - Cell is selected and not inverted
                //    Note: if selected then invert sel fg / bg must be
                //    false since we separately handle it if true above.
                break :fg if (style.flags.inverse != selected)
                    bg_style orelse self.background_color orelse self.default_background_color
                else
                    fg_style;
            };

            // Foreground alpha for this cell.
            const alpha: u8 = if (style.flags.faint) 175 else 255;

            // Set the cell's background color.
            {
                const rgb = bg orelse self.background_color orelse self.default_background_color;

                // Determine our background alpha. If we have transparency configured
                // then this is dynamic depending on some situations. This is all
                // in an attempt to make transparency look the best for various
                // situations. See inline comments.
                const bg_alpha: u8 = bg_alpha: {
                    const default: u8 = 255;

                    if (self.config.background_opacity >= 1) break :bg_alpha default;

                    // Cells that are selected should be fully opaque.
                    if (selected) break :bg_alpha default;

                    // Cells that are reversed should be fully opaque.
                    if (style.flags.inverse) break :bg_alpha default;

                    // Cells that have an explicit bg color should be fully opaque.
                    if (bg_style != null) {
                        break :bg_alpha default;
                    }

                    // Otherwise, we use the configured background opacity.
                    break :bg_alpha @intFromFloat(@round(self.config.background_opacity * 255.0));
                };

                self.cells.bgCell(y, x).* = .{
                    rgb.r, rgb.g, rgb.b, bg_alpha,
                };
            }

            // If the invisible flag is set on this cell then we
            // don't need to render any foreground elements, so
            // we just skip all glyphs with this x coordinate.
            //
            // NOTE: This behavior matches xterm. Some other terminal
            // emulators, e.g. Alacritty, still render text decorations
            // and only make the text itself invisible. The decision
            // has been made here to match xterm's behavior for this.
            if (style.flags.invisible) {
                continue;
            }

            // Give links a single underline, unless they already have
            // an underline, in which case use a double underline to
            // distinguish them.
            const underline: terminal.Attribute.Underline = if (link_match_set.contains(screen, cell_pin))
                if (style.flags.underline == .single)
                    .double
                else
                    .single
            else
                style.flags.underline;

            // We draw underlines first so that they layer underneath text.
            // This improves readability when a colored underline is used
            // which intersects parts of the text (descenders).
            if (underline != .none) self.addUnderline(
                @intCast(x),
                @intCast(y),
                underline,
                style.underlineColor(color_palette) orelse fg,
                alpha,
            ) catch |err| {
                log.warn(
                    "error adding underline to cell, will be invalid x={} y={}, err={}",
                    .{ x, y, err },
                );
            };

            if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                log.warn(
                    "error adding overline to cell, will be invalid x={} y={}, err={}",
                    .{ x, y, err },
                );
            };

            // If we're at or past the end of our shaper run then
            // we need to get the next run from the run iterator.
            if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                shaper_run = try run_iter.next(self.alloc);
                shaper_cells = null;
                shaper_cells_i = 0;
            }

            if (shaper_run) |run| glyphs: {
                // If we haven't shaped this run yet, do so.
                shaper_cells = shaper_cells orelse
                    // Try to read the cells from the shaping cache if we can.
                    self.font_shaper_cache.get(run) orelse
                    cache: {
                        // Otherwise we have to shape them.
                        const cells = try self.font_shaper.shape(run);

                        // Try to cache them. If caching fails for any reason we
                        // continue because it is just a performance optimization,
                        // not a correctness issue.
                        self.font_shaper_cache.put(
                            self.alloc,
                            run,
                            cells,
                        ) catch |err| {
                            log.warn(
                                "error caching font shaping results err={}",
                                .{err},
                            );
                        };

                        // The cells we get from direct shaping are always owned
                        // by the shaper and valid until the next shaping call so
                        // we can safely use them.
                        break :cache cells;
                    };

                const cells = shaper_cells orelse break :glyphs;

                // If there are no shaper cells for this run, ignore it.
                // This can occur for runs of empty cells, and is fine.
                if (cells.len == 0) break :glyphs;

                // If we encounter a shaper cell to the left of the current
                // cell then we have some problems. This logic relies on x
                // position monotonically increasing.
                assert(cells[shaper_cells_i].x >= x);

                // NOTE: An assumption is made here that a single cell will never
                // be present in more than one shaper run. If that assumption is
                // violated, this logic breaks.

                while (shaper_cells_i < cells.len and cells[shaper_cells_i].x == x) : ({
                    shaper_cells_i += 1;
                }) {
                    self.addGlyph(
                        @intCast(x),
                        @intCast(y),
                        cell_pin,
                        cells[shaper_cells_i],
                        shaper_run.?,
                        fg,
                        alpha,
                    ) catch |err| {
                        log.warn(
                            "error adding glyph to cell, will be invalid x={} y={}, err={}",
                            .{ x, y, err },
                        );
                    };
                }
            }

            // Finally, draw a strikethrough if necessary.
            if (style.flags.strikethrough) self.addStrikethrough(
                @intCast(x),
                @intCast(y),
                fg,
                alpha,
            ) catch |err| {
                log.warn(
                    "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                    .{ x, y, err },
                );
            };
        }
    }

    // Setup our cursor rendering information.
    cursor: {
        // By default, we don't handle cursor inversion on the shader.
        self.cells.setCursor(null);
        self.uniforms.cursor_pos = .{
            std.math.maxInt(u16),
            std.math.maxInt(u16),
        };

        // If we have preedit text, we don't setup a cursor
        if (preedit != null) break :cursor;

        // Prepare the cursor cell contents.
        const style = cursor_style_ orelse break :cursor;
        const cursor_color = self.cursor_color orelse self.default_cursor_color orelse color: {
            if (self.cursor_invert) {
                // Use the foreground color from the cell under the cursor, if any.
                const sty = screen.cursor.page_pin.style(screen.cursor.page_cell);
                break :color if (sty.flags.inverse)
                    // If the cell is reversed, use background color instead.
                    (sty.bg(screen.cursor.page_cell, color_palette) orelse self.background_color orelse self.default_background_color)
                else
                    (sty.fg(color_palette, self.config.bold_is_bright) orelse self.foreground_color orelse self.default_foreground_color);
            } else {
                break :color self.foreground_color orelse self.default_foreground_color;
            }
        };

        self.addCursor(screen, style, cursor_color);

        // If the cursor is visible then we set our uniforms.
        if (style == .block and screen.viewportIsBottom()) {
            const wide = screen.cursor.page_cell.wide;

            self.uniforms.cursor_pos = .{
                // If we are a spacer tail of a wide cell, our cursor needs
                // to move back one cell. The saturate is to ensure we don't
                // overflow but this shouldn't happen with well-formed input.
                switch (wide) {
                    .narrow, .spacer_head, .wide => screen.cursor.x,
                    .spacer_tail => screen.cursor.x -| 1,
                },
                screen.cursor.y,
            };

            self.uniforms.cursor_wide = switch (wide) {
                .narrow, .spacer_head => false,
                .wide, .spacer_tail => true,
            };

            const uniform_color = if (self.cursor_invert) blk: {
                // Use the background color from the cell under the cursor, if any.
                const sty = screen.cursor.page_pin.style(screen.cursor.page_cell);
                break :blk if (sty.flags.inverse)
                    // If the cell is reversed, use foreground color instead.
                    (sty.fg(color_palette, self.config.bold_is_bright) orelse self.foreground_color orelse self.default_foreground_color)
                else
                    (sty.bg(screen.cursor.page_cell, color_palette) orelse self.background_color orelse self.default_background_color);
            } else if (self.config.cursor_text) |txt|
                txt
            else
                self.background_color orelse self.default_background_color;

            self.uniforms.cursor_color = .{
                uniform_color.r,
                uniform_color.g,
                uniform_color.b,
                255,
            };
        }
    }

    // Setup our preedit text.
    if (preedit) |preedit_v| {
        const range = preedit_range.?;
        var x = range.x[0];
        for (preedit_v.codepoints[range.cp_offset..]) |cp| {
            self.addPreeditCell(cp, .{ .x = x, .y = range.y }) catch |err| {
                log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                    x,
                    range.y,
                    err,
                });
            };

            x += if (cp.wide) 2 else 1;
        }
    }

    // Update that our cells rebuilt
    self.cells_rebuilt = true;

    // Log some things
    // log.debug("rebuildCells complete cached_runs={}", .{
    //     self.font_shaper_cache.count(),
    // });
}

/// Add an underline decoration to the specified cell
fn addUnderline(
    self: *Metal,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    style: terminal.Attribute.Underline,
    color: terminal.color.RGB,
    alpha: u8,
) !void {
    const sprite: font.Sprite = switch (style) {
        .none => unreachable,
        .single => .underline,
        .double => .underline_double,
        .dotted => .underline_dotted,
        .dashed => .underline_dashed,
        .curly => .underline_curly,
    };

    const render = try self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        .{
            .cell_width = 1,
            .grid_metrics = self.grid_metrics,
        },
    );

    try self.cells.add(self.alloc, .underline, .{
        .mode = .fg,
        .grid_pos = .{ @intCast(x), @intCast(y) },
        .constraint_width = 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x),
            @intCast(render.glyph.offset_y),
        },
    });
}

/// Add a overline decoration to the specified cell
fn addOverline(
    self: *Metal,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    color: terminal.color.RGB,
    alpha: u8,
) !void {
    const render = try self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(font.Sprite.overline),
        .{
            .cell_width = 1,
            .grid_metrics = self.grid_metrics,
        },
    );

    try self.cells.add(self.alloc, .overline, .{
        .mode = .fg,
        .grid_pos = .{ @intCast(x), @intCast(y) },
        .constraint_width = 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x),
            @intCast(render.glyph.offset_y),
        },
    });
}

/// Add a strikethrough decoration to the specified cell
fn addStrikethrough(
    self: *Metal,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    color: terminal.color.RGB,
    alpha: u8,
) !void {
    const render = try self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(font.Sprite.strikethrough),
        .{
            .cell_width = 1,
            .grid_metrics = self.grid_metrics,
        },
    );

    try self.cells.add(self.alloc, .strikethrough, .{
        .mode = .fg,
        .grid_pos = .{ @intCast(x), @intCast(y) },
        .constraint_width = 1,
        .color = .{ color.r, color.g, color.b, alpha },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x),
            @intCast(render.glyph.offset_y),
        },
    });
}

// Add a glyph to the specified cell.
fn addGlyph(
    self: *Metal,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    cell_pin: terminal.Pin,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    color: terminal.color.RGB,
    alpha: u8,
) !void {
    const rac = cell_pin.rowAndCell();
    const cell = rac.cell;

    // Render
    const render = try self.font_grid.renderGlyph(
        self.alloc,
        shaper_run.font_index,
        shaper_cell.glyph_index,
        .{
            .grid_metrics = self.grid_metrics,
            .thicken = self.config.font_thicken,
            .thicken_strength = self.config.font_thicken_strength,
        },
    );

    // If the glyph is 0 width or height, it will be invisible
    // when drawn, so don't bother adding it to the buffer.
    if (render.glyph.width == 0 or render.glyph.height == 0) {
        return;
    }

    const mode: mtl_shaders.CellText.Mode = switch (try fgMode(
        render.presentation,
        cell_pin,
    )) {
        .normal => .fg,
        .color => .fg_color,
        .constrained => .fg_constrained,
        .powerline => .fg_powerline,
    };

    try self.cells.add(self.alloc, .text, .{
        .mode = mode,
        .grid_pos = .{ @intCast(x), @intCast(y) },
        .constraint_width = cell.gridWidth(),
        .color = .{ color.r, color.g, color.b, alpha },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x + shaper_cell.x_offset),
            @intCast(render.glyph.offset_y + shaper_cell.y_offset),
        },
    });
}

fn addCursor(
    self: *Metal,
    screen: *terminal.Screen,
    cursor_style: renderer.CursorStyle,
    cursor_color: terminal.color.RGB,
) void {
    // Add the cursor. We render the cursor over the wide character if
    // we're on the wide character tail.
    const wide, const x = cell: {
        // The cursor goes over the screen cursor position.
        const cell = screen.cursor.page_cell;
        if (cell.wide != .spacer_tail or screen.cursor.x == 0)
            break :cell .{ cell.wide == .wide, screen.cursor.x };

        // If we're part of a wide character, we move the cursor back to
        // the actual character.
        const prev_cell = screen.cursorCellLeft(1);
        break :cell .{ prev_cell.wide == .wide, screen.cursor.x - 1 };
    };

    const alpha: u8 = if (!self.focused) 255 else alpha: {
        const alpha = 255 * self.config.cursor_opacity;
        break :alpha @intFromFloat(@ceil(alpha));
    };

    const render = switch (cursor_style) {
        .block,
        .block_hollow,
        .bar,
        .underline,
        => render: {
            const sprite: font.Sprite = switch (cursor_style) {
                .block => .cursor_rect,
                .block_hollow => .cursor_hollow_rect,
                .bar => .cursor_bar,
                .underline => .underline,
                .lock => unreachable,
            };

            break :render self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = if (wide) 2 else 1,
                    .grid_metrics = self.grid_metrics,
                },
            ) catch |err| {
                log.warn("error rendering cursor glyph err={}", .{err});
                return;
            };
        },

        .lock => self.font_grid.renderCodepoint(
            self.alloc,
            0xF023, // lock symbol
            .regular,
            .text,
            .{
                .cell_width = if (wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        ) catch |err| {
            log.warn("error rendering cursor glyph err={}", .{err});
            return;
        } orelse {
            // This should never happen because we embed nerd
            // fonts so we just log and return instead of fallback.
            log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
            return;
        },
    };

    self.cells.setCursor(.{
        .mode = .cursor,
        .grid_pos = .{ x, screen.cursor.y },
        .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x),
            @intCast(render.glyph.offset_y),
        },
    });
}

fn addPreeditCell(
    self: *Metal,
    cp: renderer.State.Preedit.Codepoint,
    coord: terminal.Coordinate,
) !void {
    // Preedit is rendered inverted
    const bg = self.foreground_color orelse self.default_foreground_color;
    const fg = self.background_color orelse self.default_background_color;

    // Render the glyph for our preedit text
    const render_ = self.font_grid.renderCodepoint(
        self.alloc,
        @intCast(cp.codepoint),
        .regular,
        .text,
        .{ .grid_metrics = self.grid_metrics },
    ) catch |err| {
        log.warn("error rendering preedit glyph err={}", .{err});
        return;
    };
    const render = render_ orelse {
        log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
        return;
    };

    // Add our opaque background cell
    self.cells.bgCell(coord.y, coord.x).* = .{
        bg.r, bg.g, bg.b, 255,
    };
    if (cp.wide and coord.x < self.cells.size.columns - 1) {
        self.cells.bgCell(coord.y, coord.x + 1).* = .{
            bg.r, bg.g, bg.b, 255,
        };
    }

    // Add our text
    try self.cells.add(self.alloc, .text, .{
        .mode = .fg,
        .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
        .color = .{ fg.r, fg.g, fg.b, 255 },
        .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
        .glyph_size = .{ render.glyph.width, render.glyph.height },
        .bearings = .{
            @intCast(render.glyph.offset_x),
            @intCast(render.glyph.offset_y),
        },
    });
}

/// Sync the atlas data to the given texture. This copies the bytes
/// associated with the atlas to the given texture. If the atlas no longer
/// fits into the texture, the texture will be resized.
fn syncAtlasTexture(
    device: objc.Object,
    atlas: *const font.Atlas,
    texture: *objc.Object,
    /// Storage mode for the MTLTexture object
    storage_mode: mtl.MTLResourceOptions.StorageMode,
) !void {
    const width = texture.getProperty(c_ulong, "width");
    if (atlas.size > width) {
        // Free our old texture
        texture.*.release();

        // Reallocate
        texture.* = try initAtlasTexture(device, atlas, storage_mode);
    }

    texture.msgSend(
        void,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        .{
            mtl.MTLRegion{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{
                    .width = @intCast(atlas.size),
                    .height = @intCast(atlas.size),
                    .depth = 1,
                },
            },
            @as(c_ulong, 0),
            @as(*const anyopaque, atlas.data.ptr),
            @as(c_ulong, atlas.format.depth() * atlas.size),
        },
    );
}

/// Initialize a MTLTexture object for the given atlas.
fn initAtlasTexture(
    device: objc.Object,
    atlas: *const font.Atlas,
    /// Storage mode for the MTLTexture object
    storage_mode: mtl.MTLResourceOptions.StorageMode,
) !objc.Object {
    // Determine our pixel format
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .grayscale => .r8unorm,
        .rgba => .bgra8unorm,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("pixelFormat", @intFromEnum(pixel_format));
    desc.setProperty("width", @as(c_ulong, @intCast(atlas.size)));
    desc.setProperty("height", @as(c_ulong, @intCast(atlas.size)));

    desc.setProperty(
        "resourceOptions",
        mtl.MTLResourceOptions{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = storage_mode,
        },
    );

    // Initialize
    const id = device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;

    return objc.Object.fromId(id);
}

test {
    _ = mtl_cell;
}
