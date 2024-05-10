//! Rendering implementation for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const link = @import("link.zig");
const fgMode = @import("cell.zig").fgMode;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const imgui = @import("imgui");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const gl = @import("opengl");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");

const CellProgram = @import("opengl/CellProgram.zig");
const ImageProgram = @import("opengl/ImageProgram.zig");
const gl_image = @import("opengl/image.zig");
const custom = @import("opengl/custom.zig");
const Image = gl_image.Image;
const ImageMap = gl_image.ImageMap;
const ImagePlacementList = std.ArrayListUnmanaged(gl_image.Placement);

const log = std.log.scoped(.grid);

/// The runtime can request a single-threaded draw by setting this boolean
/// to true. In this case, the renderer.draw() call is expected to be called
/// from the runtime.
pub const single_threaded_draw = if (@hasDecl(apprt.Surface, "opengl_single_threaded_draw"))
    apprt.Surface.opengl_single_threaded_draw
else
    false;
const DrawMutex = if (single_threaded_draw) std.Thread.Mutex else void;
const drawMutexZero = if (DrawMutex == void) void{} else .{};

alloc: std.mem.Allocator,

/// The configuration we need derived from the main config.
config: DerivedConfig,

/// Current font metrics defining our grid.
grid_metrics: font.face.Metrics,

/// Current screen size dimensions for this grid. This is set on the first
/// resize event, and is not immediately available.
screen_size: ?renderer.ScreenSize,

/// The current set of cells to render. Each set of cells goes into
/// a separate shader call.
cells_bg: std.ArrayListUnmanaged(CellProgram.Cell),
cells: std.ArrayListUnmanaged(CellProgram.Cell),

/// The size of the cells list that was sent to the GPU. This is used
/// to detect when the cells array was reallocated/resized and handle that
/// accordingly.
gl_cells_size: usize = 0,

/// The last length of the cells that was written to the GPU. This is used to
/// determine what data needs to be rewritten on the GPU.
gl_cells_written: usize = 0,

/// Shader program for cell rendering.
gl_state: ?GLState = null,

/// The font structures.
font_grid: *font.SharedGrid,
font_shaper: font.Shaper,
font_shaper_cache: font.ShaperCache,
texture_greyscale_modified: usize = 0,
texture_greyscale_resized: usize = 0,
texture_color_modified: usize = 0,
texture_color_resized: usize = 0,

/// True if the window is focused
focused: bool,

/// The actual foreground color. May differ from the config foreground color if
/// changed by a terminal application
foreground_color: terminal.color.RGB,

/// The actual background color. May differ from the config background color if
/// changed by a terminal application
background_color: terminal.color.RGB,

/// The actual cursor color. May differ from the config cursor color if changed
/// by a terminal application
cursor_color: ?terminal.color.RGB,

/// Padding options
padding: renderer.Options.Padding,

/// The mailbox for communicating with the window.
surface_mailbox: apprt.surface.Mailbox,

/// Deferred operations. This is used to apply changes to the OpenGL context.
/// Some runtimes (GTK) do not support multi-threading so to keep our logic
/// simple we apply all OpenGL context changes in the render() call.
deferred_screen_size: ?SetScreenSize = null,
deferred_font_size: ?SetFontSize = null,
deferred_config: ?SetConfig = null,

/// If we're drawing with single threaded operations
draw_mutex: DrawMutex = drawMutexZero,

/// Current background to draw. This may not match self.background if the
/// terminal is in reversed mode.
draw_background: terminal.color.RGB,

/// The images that we may render.
images: ImageMap = .{},
image_placements: ImagePlacementList = .{},
image_bg_end: u32 = 0,
image_text_end: u32 = 0,

/// Defererred OpenGL operation to update the screen size.
const SetScreenSize = struct {
    size: renderer.ScreenSize,

    fn apply(self: SetScreenSize, r: *OpenGL) !void {
        const gl_state: *GLState = if (r.gl_state) |*v|
            v
        else
            return error.OpenGLUninitialized;

        // Apply our padding
        const padding = if (r.padding.balance)
            renderer.Padding.balanced(
                self.size,
                r.gridSize(self.size),
                .{
                    .width = r.grid_metrics.cell_width,
                    .height = r.grid_metrics.cell_height,
                },
            )
        else
            r.padding.explicit;
        const padded_size = self.size.subPadding(padding);

        log.debug("GL api: screen size padded={} screen={} grid={} cell={} padding={}", .{
            padded_size,
            self.size,
            r.gridSize(self.size),
            renderer.CellSize{
                .width = r.grid_metrics.cell_width,
                .height = r.grid_metrics.cell_height,
            },
            r.padding.explicit,
        });

        // Update our viewport for this context to be the entire window.
        // OpenGL works in pixels, so we have to use the pixel size.
        try gl.viewport(
            0,
            0,
            @intCast(self.size.width),
            @intCast(self.size.height),
        );

        // Update the projection uniform within our shader
        inline for (.{ "cell_program", "image_program" }) |name| {
            const program = @field(gl_state, name);
            const bind = try program.program.use();
            defer bind.unbind();
            try program.program.setUniform(
                "projection",

                // 2D orthographic projection with the full w/h
                math.ortho2d(
                    -1 * @as(f32, @floatFromInt(padding.left)),
                    @floatFromInt(padded_size.width + padding.right),
                    @floatFromInt(padded_size.height + padding.bottom),
                    -1 * @as(f32, @floatFromInt(padding.top)),
                ),
            );
        }

        // Update our custom shader resolution
        if (gl_state.custom) |*custom_state| {
            try custom_state.setScreenSize(self.size);
        }
    }
};

const SetFontSize = struct {
    metrics: font.face.Metrics,

    fn apply(self: SetFontSize, r: *const OpenGL) !void {
        const gl_state = r.gl_state orelse return error.OpenGLUninitialized;

        inline for (.{ "cell_program", "image_program" }) |name| {
            const program = @field(gl_state, name);
            const bind = try program.program.use();
            defer bind.unbind();
            try program.program.setUniform(
                "cell_size",
                @Vector(2, f32){
                    @floatFromInt(self.metrics.cell_width),
                    @floatFromInt(self.metrics.cell_height),
                },
            );
        }
    }
};

const SetConfig = struct {
    fn apply(self: SetConfig, r: *const OpenGL) !void {
        _ = self;
        const gl_state = r.gl_state orelse return error.OpenGLUninitialized;

        const bind = try gl_state.cell_program.program.use();
        defer bind.unbind();
        try gl_state.cell_program.program.setUniform(
            "min_contrast",
            r.config.min_contrast,
        );
    }
};

/// The configuration for this renderer that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    font_thicken: bool,
    font_features: std.ArrayListUnmanaged([:0]const u8),
    font_styles: font.CodepointResolver.StyleStatus,
    cursor_color: ?terminal.color.RGB,
    cursor_text: ?terminal.color.RGB,
    cursor_opacity: f64,
    background: terminal.color.RGB,
    background_opacity: f64,
    foreground: terminal.color.RGB,
    selection_background: ?terminal.color.RGB,
    selection_foreground: ?terminal.color.RGB,
    invert_selection_fg_bg: bool,
    min_contrast: f32,
    custom_shaders: std.ArrayListUnmanaged([:0]const u8),
    links: link.Set,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Copy our shaders
        const custom_shaders = try config.@"custom-shader".value.list.clone(alloc);

        // Copy our font features
        const font_features = try config.@"font-feature".list.clone(alloc);

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

        return .{
            .background_opacity = @max(0, @min(1, config.@"background-opacity")),
            .font_thicken = config.@"font-thicken",
            .font_features = font_features,
            .font_styles = font_styles,

            .cursor_color = if (config.@"cursor-color") |col|
                col.toTerminalRGB()
            else
                null,

            .cursor_text = if (config.@"cursor-text") |txt|
                txt.toTerminalRGB()
            else
                null,

            .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),
            .invert_selection_fg_bg = config.@"selection-invert-fg-bg",
            .min_contrast = @floatCast(config.@"minimum-contrast"),

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

            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        const alloc = self.arena.allocator();
        self.links.deinit(alloc);
        self.arena.deinit();
    }
};

pub fn init(alloc: Allocator, options: renderer.Options) !OpenGL {
    // Create the initial font shaper
    var shaper = try font.Shaper.init(alloc, .{
        .features = options.config.font_features.items,
    });
    errdefer shaper.deinit();

    // For the remainder of the setup we lock our font grid data because
    // we're reading it.
    const grid = options.font_grid;
    grid.lock.lockShared();
    defer grid.lock.unlockShared();

    var gl_state = try GLState.init(alloc, options.config, grid);
    errdefer gl_state.deinit();

    return OpenGL{
        .alloc = alloc,
        .config = options.config,
        .cells_bg = .{},
        .cells = .{},
        .grid_metrics = grid.metrics,
        .screen_size = null,
        .gl_state = gl_state,
        .font_grid = grid,
        .font_shaper = shaper,
        .font_shaper_cache = font.ShaperCache.init(),
        .draw_background = options.config.background,
        .focused = true,
        .foreground_color = options.config.foreground,
        .background_color = options.config.background,
        .cursor_color = options.config.cursor_color,
        .padding = options.padding,
        .surface_mailbox = options.surface_mailbox,
        .deferred_font_size = .{ .metrics = grid.metrics },
        .deferred_config = .{},
    };
}

pub fn deinit(self: *OpenGL) void {
    self.font_shaper.deinit();
    self.font_shaper_cache.deinit(self.alloc);

    {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.image.deinit(self.alloc);
        self.images.deinit(self.alloc);
    }
    self.image_placements.deinit(self.alloc);

    if (self.gl_state) |*v| v.deinit(self.alloc);

    self.cells.deinit(self.alloc);
    self.cells_bg.deinit(self.alloc);

    self.config.deinit();

    self.* = undefined;
}

/// Returns the hints that we want for this
pub fn glfwWindowHints(config: *const configpkg.Config) glfw.Window.Hints {
    return .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .cocoa_graphics_switching = builtin.os.tag == .macos,
        .cocoa_retina_framebuffer = true,
        .transparent_framebuffer = config.@"background-opacity" < 1,
    };
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    // Treat this like a thread entry
    const self: OpenGL = undefined;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK uses global OpenGL context so we load from null.
            const version = try gl.glad.load(null);
            const major = gl.glad.versionMajor(@intCast(version));
            const minor = gl.glad.versionMinor(@intCast(version));
            errdefer gl.glad.unload();
            log.info("loaded OpenGL {}.{}", .{ major, minor });

            // We require at least OpenGL 3.3
            if (major < 3 or (major == 3 and minor < 3)) {
                log.warn("OpenGL version is too old. Ghostty requires OpenGL 3.3", .{});
                return error.OpenGLOutdated;
            }
        },

        apprt.glfw => try self.threadEnter(surface),

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    // For GLFW, we grabbed the OpenGL context in surfaceInit and we
    // need to release it before we start the renderer thread.
    if (apprt.runtime == apprt.glfw) {
        glfw.makeContextCurrent(null);
    }
}

/// Called when the OpenGL context is made invalid, so we need to free
/// all previous resources and stop rendering.
pub fn displayUnrealized(self: *OpenGL) void {
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();

    if (self.gl_state) |*v| {
        v.deinit(self.alloc);
        self.gl_state = null;
    }
}

/// Called when the OpenGL is ready to be initialized.
pub fn displayRealize(self: *OpenGL) !void {
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();

    // Make our new state
    var gl_state = gl_state: {
        self.font_grid.lock.lockShared();
        defer self.font_grid.lock.unlockShared();
        break :gl_state try GLState.init(
            self.alloc,
            self.config,
            self.font_grid,
        );
    };
    errdefer gl_state.deinit();

    // Unrealize if we have to
    if (self.gl_state) |*v| v.deinit(self.alloc);

    // Set our new state
    self.gl_state = gl_state;

    // Make sure we invalidate all the fields so that we
    // reflush everything
    self.gl_cells_size = 0;
    self.gl_cells_written = 0;
    self.texture_greyscale_modified = 0;
    self.texture_color_modified = 0;
    self.texture_greyscale_resized = 0;
    self.texture_color_resized = 0;

    // We need to reset our uniforms
    if (self.screen_size) |size| {
        self.deferred_screen_size = .{ .size = size };
    }
    self.deferred_font_size = .{ .metrics = self.grid_metrics };
    self.deferred_config = .{};
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.glfw => {
            // We need to make the OpenGL context current. OpenGL requires
            // that a single thread own the a single OpenGL context (if any). This
            // ensures that the context switches over to our thread. Important:
            // the prior thread MUST have detached the context prior to calling
            // this entrypoint.
            glfw.makeContextCurrent(surface.window);
            errdefer glfw.makeContextCurrent(null);
            glfw.swapInterval(1);

            // Load OpenGL bindings. This API is context-aware so this sets
            // a threadlocal context for these pointers.
            const version = try gl.glad.load(&glfw.getProcAddress);
            errdefer gl.glad.unload();
            log.info("loaded OpenGL {}.{}", .{
                gl.glad.versionMajor(@intCast(version)),
                gl.glad.versionMinor(@intCast(version)),
            });
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.glfw => {
            gl.glad.unload();
            glfw.makeContextCurrent(null);
        },

        apprt.embedded => {
            // TODO: see threadEnter
        },
    }
}

/// True if our renderer has animations so that a higher frequency
/// timer is used.
pub fn hasAnimations(self: *const OpenGL) bool {
    const state = self.gl_state orelse return false;
    return state.custom != null;
}

/// See Metal
pub fn hasVsync(self: *const OpenGL) bool {
    _ = self;

    // OpenGL currently never has vsync
    return false;
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *OpenGL, focus: bool) !void {
    self.focused = focus;
}

/// Callback when the window is visible or occluded.
///
/// Must be called on the render thread.
pub fn setVisible(self: *OpenGL, visible: bool) void {
    _ = self;
    _ = visible;
}

/// Set the new font grid.
///
/// Must be called on the render thread.
pub fn setFontGrid(self: *OpenGL, grid: *font.SharedGrid) void {
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();

    // Reset our font grid
    self.font_grid = grid;
    self.grid_metrics = grid.metrics;
    self.texture_greyscale_modified = 0;
    self.texture_greyscale_resized = 0;
    self.texture_color_modified = 0;
    self.texture_color_resized = 0;

    // Reset our shaper cache. If our font changed (not just the size) then
    // the data in the shaper cache may be invalid and cannot be used, so we
    // always clear the cache just in case.
    const font_shaper_cache = font.ShaperCache.init();
    self.font_shaper_cache.deinit(self.alloc);
    self.font_shaper_cache = font_shaper_cache;

    // Defer our GPU updates
    self.deferred_font_size = .{ .metrics = grid.metrics };
}

/// The primary render callback that is completely thread-safe.
pub fn updateFrame(
    self: *OpenGL,
    surface: *apprt.Surface,
    state: *renderer.State,
    cursor_blink_visible: bool,
) !void {
    _ = surface;

    // Data we extract out of the critical area.
    const Critical = struct {
        gl_bg: terminal.color.RGB,
        screen: terminal.Screen,
        mouse: renderer.State.Mouse,
        preedit: ?renderer.State.Preedit,
        cursor_style: ?renderer.CursorStyle,
        color_palette: terminal.color.Palette,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // If we're in a synchronized output state, we pause all rendering.
        if (state.terminal.modes.get(.synchronized_output)) {
            log.debug("synchronized output started, skipping render", .{});
            return;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.background_color;
        const fg = self.foreground_color;
        defer {
            self.background_color = bg;
            self.foreground_color = fg;
        }
        if (state.terminal.modes.get(.reverse_colors)) {
            self.background_color = fg;
            self.foreground_color = bg;
        }

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock wile rebuilding GPU cells.
        var screen_copy = try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = .{} },
            null,
        );
        errdefer screen_copy.deinit();

        // Whether to draw our cursor or not.
        const cursor_style = renderer.cursorStyle(
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
        if (state.terminal.screen.kitty_images.dirty) {
            // prepKittyGraphics touches self.images which is also used
            // in drawFrame so if we're drawing on a separate thread we need
            // to lock this.
            if (single_threaded_draw) self.draw_mutex.lock();
            defer if (single_threaded_draw) self.draw_mutex.unlock();
            try self.prepKittyGraphics(state.terminal);
        }

        break :critical .{
            .gl_bg = self.background_color,
            .screen = screen_copy,
            .mouse = state.mouse,
            .preedit = preedit,
            .cursor_style = cursor_style,
            .color_palette = state.terminal.color_palette.colors,
        };
    };
    defer {
        critical.screen.deinit();
        if (critical.preedit) |p| p.deinit(self.alloc);
    }

    // Grab our draw mutex if we have it and update our data
    {
        if (single_threaded_draw) self.draw_mutex.lock();
        defer if (single_threaded_draw) self.draw_mutex.unlock();

        // Set our draw data
        self.draw_background = critical.gl_bg;

        // Build our GPU cells
        try self.rebuildCells(
            &critical.screen,
            critical.mouse,
            critical.preedit,
            critical.cursor_style,
            &critical.color_palette,
        );
    }
}

/// This goes through the Kitty graphic placements and accumulates the
/// placements we need to render on our viewport. It also ensures that
/// the visible images are loaded on the GPU.
fn prepKittyGraphics(
    self: *OpenGL,
    t: *terminal.Terminal,
) !void {
    const storage = &t.screen.kitty_images;
    defer storage.dirty = false;

    // We always clear our previous placements no matter what because
    // we rebuild them from scratch.
    self.image_placements.clearRetainingCapacity();

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
        // Find the image in storage
        const p = kv.value_ptr;
        const image = storage.imageById(kv.key_ptr.image_id) orelse {
            log.warn(
                "missing image for placement, ignoring image_id={}",
                .{kv.key_ptr.image_id},
            );
            continue;
        };

        // If the selection isn't within our viewport then skip it.
        const rect = p.rect(image, t);
        if (bot.before(rect.top_left)) continue;
        if (rect.bottom_right.before(top)) continue;

        // If the top left is outside the viewport we need to calc an offset
        // so that we render (0, 0) with some offset for the texture.
        const offset_y: u32 = if (rect.top_left.before(top)) offset_y: {
            const vp_y = t.screen.pages.pointFromPin(.screen, top).?.screen.y;
            const img_y = t.screen.pages.pointFromPin(.screen, rect.top_left).?.screen.y;
            const offset_cells = vp_y - img_y;
            const offset_pixels = offset_cells * self.grid_metrics.cell_height;
            break :offset_y @intCast(offset_pixels);
        } else 0;

        // We need to prep this image for upload if it isn't in the cache OR
        // it is in the cache but the transmit time doesn't match meaning this
        // image is different.
        const gop = try self.images.getOrPut(self.alloc, kv.key_ptr.image_id);
        if (!gop.found_existing or
            gop.value_ptr.transmit_time.order(image.transmit_time) != .eq)
        {
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
                .grey_alpha => .{ .pending_grey_alpha = pending },
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

        // Convert our screen point to a viewport point
        const viewport: terminal.point.Point = t.screen.pages.pointFromPin(
            .viewport,
            p.pin.*,
        ) orelse .{ .viewport = .{} };

        // Calculate the source rectangle
        const source_x = @min(image.width, p.source_x);
        const source_y = @min(image.height, p.source_y + offset_y);
        const source_width = if (p.source_width > 0)
            @min(image.width - source_x, p.source_width)
        else
            image.width;
        const source_height = if (p.source_height > 0)
            @min(image.height, p.source_height)
        else
            image.height -| offset_y;

        // Calculate the width/height of our image.
        const dest_width = if (p.columns > 0) p.columns * self.grid_metrics.cell_width else source_width;
        const dest_height = if (p.rows > 0) p.rows * self.grid_metrics.cell_height else source_height;

        // Accumulate the placement
        if (image.width > 0 and image.height > 0) {
            try self.image_placements.append(self.alloc, .{
                .image_id = kv.key_ptr.image_id,
                .x = @intCast(p.pin.x),
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

    // Sort the placements by their Z value.
    std.mem.sortUnstable(
        gl_image.Placement,
        self.image_placements.items,
        {},
        struct {
            fn lessThan(
                ctx: void,
                lhs: gl_image.Placement,
                rhs: gl_image.Placement,
            ) bool {
                _ = ctx;
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan,
    );

    // Find our indices
    self.image_bg_end = 0;
    self.image_text_end = 0;
    const bg_limit = std.math.minInt(i32) / 2;
    for (self.image_placements.items, 0..) |p, i| {
        if (self.image_bg_end == 0 and p.z >= bg_limit) {
            self.image_bg_end = @intCast(i);
        }
        if (self.image_text_end == 0 and p.z >= 0) {
            self.image_text_end = @intCast(i);
        }
    }
    if (self.image_text_end == 0) {
        self.image_text_end = @intCast(self.image_placements.items.len);
    }
}

/// rebuildCells rebuilds all the GPU cells from our CPU state. This is a
/// slow operation but ensures that the GPU state exactly matches the CPU state.
/// In steady-state operation, we use some GPU tricks to send down stale data
/// that is ignored. This accumulates more memory; rebuildCells clears it.
///
/// Note this doesn't have to typically be manually called. Internally,
/// the renderer will do this when it needs more memory space.
pub fn rebuildCells(
    self: *OpenGL,
    screen: *terminal.Screen,
    mouse: renderer.State.Mouse,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
    color_palette: *const terminal.color.Palette,
) !void {
    const rows_usize: usize = @intCast(screen.pages.rows);
    const cols_usize: usize = @intCast(screen.pages.cols);

    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    try self.cells_bg.ensureTotalCapacity(
        self.alloc,
        rows_usize * cols_usize,
    );

    // For now, we just ensure that we have enough cells for all the lines
    // we have plus a full width. This is very likely too much but its
    // the probably close enough while guaranteeing no more allocations.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for glyph + underline + strikethrough for each cell
        // + 1 for cursor
        (rows_usize * cols_usize * 3) + 1,
    );

    // Create an arena for all our temporary allocations while rebuilding
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // We've written no data to the GPU, refresh it all
    self.gl_cells_written = 0;

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

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?CellProgram.Cell = null;

    // Build each cell
    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var y: terminal.size.CellCountInt = 0;
    while (row_it.next()) |row| {
        defer y += 1;

        // Our selection value is only non-null if this selection happens
        // to contain this row. This selection value will be set to only be
        // the selection that contains this row. This way, if the selection
        // changes but not for this line, we don't invalidate the cache.
        const selection = sel: {
            const sel = screen.selection orelse break :sel null;
            const pin = screen.pages.pin(.{ .viewport = .{ .y = y } }) orelse
                break :sel null;
            break :sel sel.containedRow(screen, pin) orelse null;
        };

        // See Metal.zig
        const cursor_row = if (cursor_style_) |cursor_style|
            cursor_style == .block and
                screen.viewportIsBottom() and
                y == screen.cursor.y
        else
            false;

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (cursor_row) {
            // If we're on a wide spacer tail, then we want to look for
            // the previous cell.
            const screen_cell = row.cells(.all)[screen.cursor.x];
            const x = screen.cursor.x - @intFromBool(screen_cell.wide == .spacer_tail);
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_col == x and
                    (cell.mode == .fg or cell.mode == .fg_color))
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(
            self.font_grid,
            screen,
            row,
            selection,
            if (shape_cursor) screen.cursor.x else null,
        );
        while (try iter.next(self.alloc)) |run| {
            // Try to read the cells from the shaping cache if we can.
            const shaper_cells = self.font_shaper_cache.get(run) orelse cache: {
                const cells = try self.font_shaper.shape(run);

                // Try to cache them. If caching fails for any reason we continue
                // because it is just a performance optimization, not a correctness
                // issue.
                self.font_shaper_cache.put(self.alloc, run, cells) catch |err| {
                    log.warn("error caching font shaping results err={}", .{err});
                };

                // The cells we get from direct shaping are always owned by
                // the shaper and valid until the next shaping call so we can
                // just return them.
                break :cache cells;
            };

            for (shaper_cells) |shaper_cell| {
                // If this cell falls within our preedit range then we skip it.
                // We do this so we don't have conflicting data on the same
                // cell.
                if (preedit_range) |range| {
                    if (range.y == y and
                        shaper_cell.x >= range.x[0] and
                        shaper_cell.x <= range.x[1])
                    {
                        continue;
                    }
                }

                // It this cell is within our hint range then we need to
                // underline it.
                const cell: terminal.Pin = cell: {
                    var copy = row;
                    copy.x = shaper_cell.x;
                    break :cell copy;
                };

                if (self.updateCell(
                    screen,
                    cell,
                    if (link_match_set.orderedContains(screen, cell))
                        .single
                    else
                        null,
                    color_palette,
                    shaper_cell,
                    run,
                    shaper_cell.x,
                    y,
                )) |update| {
                    assert(update);
                } else |err| {
                    log.warn("error building cell, will be invalid x={} y={}, err={}", .{
                        shaper_cell.x,
                        y,
                        err,
                    });
                }
            }
        }
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    if (cursor_style_) |cursor_style| cursor_style: {
        // If we have a preedit, we try to render the preedit text on top
        // of the cursor.
        if (preedit) |preedit_v| {
            const range = preedit_range.?;
            var x = range.x[0];
            for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                self.addPreeditCell(cp, x, range.y) catch |err| {
                    log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                        x,
                        range.y,
                        err,
                    });
                };

                x += if (cp.wide) 2 else 1;
            }

            // Preedit hides the cursor
            break :cursor_style;
        }

        _ = self.addCursor(screen, cursor_style);
        if (cursor_cell) |*cell| {
            if (cell.mode == .fg) {
                if (self.config.cursor_text) |txt| {
                    cell.r = txt.r;
                    cell.g = txt.g;
                    cell.b = txt.b;
                    cell.a = 255;
                } else {
                    cell.r = self.background_color.r;
                    cell.g = self.background_color.g;
                    cell.b = self.background_color.b;
                    cell.a = 255;
                }
            }
            self.cells.appendAssumeCapacity(cell.*);
        }
    }

    // Some debug mode safety checks
    if (std.debug.runtime_safety) {
        for (self.cells_bg.items) |cell| assert(cell.mode == .bg);
        for (self.cells.items) |cell| assert(cell.mode != .bg);
    }
}

fn addPreeditCell(
    self: *OpenGL,
    cp: renderer.State.Preedit.Codepoint,
    x: usize,
    y: usize,
) !void {
    // Preedit is rendered inverted
    const bg = self.foreground_color;
    const fg = self.background_color;

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
    self.cells_bg.appendAssumeCapacity(.{
        .mode = .bg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(y),
        .grid_width = if (cp.wide) 2 else 1,
        .glyph_x = 0,
        .glyph_y = 0,
        .glyph_width = 0,
        .glyph_height = 0,
        .glyph_offset_x = 0,
        .glyph_offset_y = 0,
        .r = bg.r,
        .g = bg.g,
        .b = bg.b,
        .a = 255,
        .bg_r = 0,
        .bg_g = 0,
        .bg_b = 0,
        .bg_a = 0,
    });

    // Add our text
    self.cells.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(y),
        .grid_width = if (cp.wide) 2 else 1,
        .glyph_x = render.glyph.atlas_x,
        .glyph_y = render.glyph.atlas_y,
        .glyph_width = render.glyph.width,
        .glyph_height = render.glyph.height,
        .glyph_offset_x = render.glyph.offset_x,
        .glyph_offset_y = render.glyph.offset_y,
        .r = fg.r,
        .g = fg.g,
        .b = fg.b,
        .a = 255,
        .bg_r = bg.r,
        .bg_g = bg.g,
        .bg_b = bg.b,
        .bg_a = 255,
    });
}

fn addCursor(
    self: *OpenGL,
    screen: *terminal.Screen,
    cursor_style: renderer.CursorStyle,
) ?*const CellProgram.Cell {
    // Add the cursor. We render the cursor over the wide character if
    // we're on the wide characer tail.
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

    const color = self.cursor_color orelse self.foreground_color;
    const alpha: u8 = if (!self.focused) 255 else alpha: {
        const alpha = 255 * self.config.cursor_opacity;
        break :alpha @intFromFloat(@ceil(alpha));
    };

    const sprite: font.Sprite = switch (cursor_style) {
        .block => .cursor_rect,
        .block_hollow => .cursor_hollow_rect,
        .bar => .cursor_bar,
        .underline => .underline,
    };

    const render = self.font_grid.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        .{
            .cell_width = if (wide) 2 else 1,
            .grid_metrics = self.grid_metrics,
        },
    ) catch |err| {
        log.warn("error rendering cursor glyph err={}", .{err});
        return null;
    };

    self.cells.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(screen.cursor.y),
        .grid_width = if (wide) 2 else 1,
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = alpha,
        .bg_r = 0,
        .bg_g = 0,
        .bg_b = 0,
        .bg_a = 0,
        .glyph_x = render.glyph.atlas_x,
        .glyph_y = render.glyph.atlas_y,
        .glyph_width = render.glyph.width,
        .glyph_height = render.glyph.height,
        .glyph_offset_x = render.glyph.offset_x,
        .glyph_offset_y = render.glyph.offset_y,
    });

    return &self.cells.items[self.cells.items.len - 1];
}

/// Update a single cell. The bool returns whether the cell was updated
/// or not. If the cell wasn't updated, a full refreshCells call is
/// needed.
fn updateCell(
    self: *OpenGL,
    screen: *terminal.Screen,
    cell_pin: terminal.Pin,
    cell_underline: ?terminal.Attribute.Underline,
    palette: *const terminal.color.Palette,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    x: usize,
    y: usize,
) !bool {
    const BgFg = struct {
        /// Background is optional because in un-inverted mode
        /// it may just be equivalent to the default background in
        /// which case we do nothing to save on GPU render time.
        bg: ?terminal.color.RGB,

        /// Fg is always set to some color, though we may not render
        /// any fg if the cell is empty or has no attributes like
        /// underline.
        fg: terminal.color.RGB,
    };

    // True if this cell is selected
    const selected: bool = if (screen.selection) |sel|
        sel.contains(screen, cell_pin)
    else
        false;

    const rac = cell_pin.rowAndCell();
    const cell = rac.cell;
    const style = cell_pin.style(cell);
    const underline = cell_underline orelse style.flags.underline;

    // The colors for the cell.
    const colors: BgFg = colors: {
        // The normal cell result
        const cell_res: BgFg = if (!style.flags.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = style.bg(cell, palette),
            .fg = style.fg(palette) orelse self.foreground_color,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = style.fg(palette) orelse self.foreground_color,
            .fg = style.bg(cell, palette) orelse self.background_color,
        };

        // If we are selected, we our colors are just inverted fg/bg
        const selection_res: ?BgFg = if (selected) .{
            .bg = if (self.config.invert_selection_fg_bg)
                cell_res.fg
            else
                self.config.selection_background orelse self.foreground_color,
            .fg = if (self.config.invert_selection_fg_bg)
                cell_res.bg orelse self.background_color
            else
                self.config.selection_foreground orelse self.background_color,
        } else null;

        // If the cell is "invisible" then we just make fg = bg so that
        // the cell is transparent but still copy-able.
        const res: BgFg = selection_res orelse cell_res;
        if (style.flags.invisible) {
            break :colors BgFg{
                .bg = res.bg,
                .fg = res.bg orelse self.background_color,
            };
        }

        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (style.flags.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    const bg: [4]u8 = if (colors.bg) |rgb| bg: {
        // Determine our background alpha. If we have transparency configured
        // then this is dynamic depending on some situations. This is all
        // in an attempt to make transparency look the best for various
        // situations. See inline comments.
        const bg_alpha: u8 = bg_alpha: {
            const default: u8 = 255;

            if (self.config.background_opacity >= 1) break :bg_alpha default;

            // If we're selected, we do not apply background opacity
            if (selected) break :bg_alpha default;

            // If we're reversed, do not apply background opacity
            if (style.flags.inverse) break :bg_alpha default;

            // If we have a background and its not the default background
            // then we apply background opacity
            if (style.bg(cell, palette) != null and !rgb.eql(self.background_color)) {
                break :bg_alpha default;
            }

            // We apply background opacity.
            var bg_alpha: f64 = @floatFromInt(default);
            bg_alpha *= self.config.background_opacity;
            bg_alpha = @ceil(bg_alpha);
            break :bg_alpha @intFromFloat(bg_alpha);
        };

        self.cells_bg.appendAssumeCapacity(.{
            .mode = .bg,
            .grid_col = @intCast(x),
            .grid_row = @intCast(y),
            .grid_width = cell.gridWidth(),
            .glyph_x = 0,
            .glyph_y = 0,
            .glyph_width = 0,
            .glyph_height = 0,
            .glyph_offset_x = 0,
            .glyph_offset_y = 0,
            .r = rgb.r,
            .g = rgb.g,
            .b = rgb.b,
            .a = bg_alpha,
            .bg_r = 0,
            .bg_g = 0,
            .bg_b = 0,
            .bg_a = 0,
        });

        break :bg .{ rgb.r, rgb.g, rgb.b, bg_alpha };
    } else .{
        self.draw_background.r,
        self.draw_background.g,
        self.draw_background.b,
        @intFromFloat(@max(0, @min(255, @round(self.config.background_opacity * 255)))),
    };

    // If the cell has a character, draw it
    if (cell.hasText()) fg: {
        // Render
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index orelse break :fg,
            .{
                .grid_metrics = self.grid_metrics,
                .thicken = self.config.font_thicken,
            },
        );

        // If we're rendering a color font, we use the color atlas
        const mode: CellProgram.CellMode = switch (try fgMode(
            render.presentation,
            cell_pin,
        )) {
            .normal => .fg,
            .color => .fg_color,
            .constrained => .fg_constrained,
        };

        self.cells.appendAssumeCapacity(.{
            .mode = mode,
            .grid_col = @intCast(x),
            .grid_row = @intCast(y),
            .grid_width = cell.gridWidth(),
            .glyph_x = render.glyph.atlas_x,
            .glyph_y = render.glyph.atlas_y,
            .glyph_width = render.glyph.width,
            .glyph_height = render.glyph.height,
            .glyph_offset_x = render.glyph.offset_x + shaper_cell.x_offset,
            .glyph_offset_y = render.glyph.offset_y + shaper_cell.y_offset,
            .r = colors.fg.r,
            .g = colors.fg.g,
            .b = colors.fg.b,
            .a = alpha,
            .bg_r = bg[0],
            .bg_g = bg[1],
            .bg_b = bg[2],
            .bg_a = bg[3],
        });
    }

    if (underline != .none) {
        const sprite: font.Sprite = switch (underline) {
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
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        const color = style.underlineColor(palette) orelse colors.fg;

        self.cells.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_col = @intCast(x),
            .grid_row = @intCast(y),
            .grid_width = cell.gridWidth(),
            .glyph_x = render.glyph.atlas_x,
            .glyph_y = render.glyph.atlas_y,
            .glyph_width = render.glyph.width,
            .glyph_height = render.glyph.height,
            .glyph_offset_x = render.glyph.offset_x,
            .glyph_offset_y = render.glyph.offset_y,
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = alpha,
            .bg_r = bg[0],
            .bg_g = bg[1],
            .bg_b = bg[2],
            .bg_a = bg[3],
        });
    }

    if (style.flags.strikethrough) {
        const render = try self.font_grid.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(font.Sprite.strikethrough),
            .{
                .cell_width = if (cell.wide == .wide) 2 else 1,
                .grid_metrics = self.grid_metrics,
            },
        );

        self.cells.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_col = @intCast(x),
            .grid_row = @intCast(y),
            .grid_width = cell.gridWidth(),
            .glyph_x = render.glyph.atlas_x,
            .glyph_y = render.glyph.atlas_y,
            .glyph_width = render.glyph.width,
            .glyph_height = render.glyph.height,
            .glyph_offset_x = render.glyph.offset_x,
            .glyph_offset_y = render.glyph.offset_y,
            .r = colors.fg.r,
            .g = colors.fg.g,
            .b = colors.fg.b,
            .a = alpha,
            .bg_r = bg[0],
            .bg_g = bg[1],
            .bg_b = bg[2],
            .bg_a = bg[3],
        });
    }

    return true;
}

/// Returns the grid size for a given screen size. This is safe to call
/// on any thread.
fn gridSize(self: *const OpenGL, screen_size: renderer.ScreenSize) renderer.GridSize {
    return renderer.GridSize.init(
        screen_size.subPadding(self.padding.explicit),
        .{
            .width = self.grid_metrics.cell_width,
            .height = self.grid_metrics.cell_height,
        },
    );
}

/// Update the configuration.
pub fn changeConfig(self: *OpenGL, config: *DerivedConfig) !void {
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

    // Set our new colors
    self.background_color = config.background;
    self.foreground_color = config.foreground;
    self.cursor_color = config.cursor_color;

    // Update our uniforms
    self.deferred_config = .{};

    self.config.deinit();
    self.config = config.*;
}

/// Set the screen size for rendering. This will update the projection
/// used for the shader so that the scaling of the grid is correct.
pub fn setScreenSize(
    self: *OpenGL,
    dim: renderer.ScreenSize,
    pad: renderer.Padding,
) !void {
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();

    // Reset our buffer sizes so that we free memory when the screen shrinks.
    // This could be made more clever by only doing this when the screen
    // shrinks but the performance cost really isn't that much.
    self.cells.clearAndFree(self.alloc);
    self.cells_bg.clearAndFree(self.alloc);

    // Store our screen size
    self.screen_size = dim;
    self.padding.explicit = pad;

    // Recalculate the rows/columns.
    const grid_size = self.gridSize(dim);

    log.debug("screen size screen={} grid={} cell={} padding={}", .{
        dim,
        grid_size,
        renderer.CellSize{
            .width = self.grid_metrics.cell_width,
            .height = self.grid_metrics.cell_height,
        },
        self.padding.explicit,
    });

    // Defer our OpenGL updates
    self.deferred_screen_size = .{ .size = dim };
}

/// Updates the font texture atlas if it is dirty.
fn flushAtlas(self: *OpenGL) !void {
    const gl_state = self.gl_state orelse return;
    try flushAtlasSingle(
        &self.font_grid.lock,
        gl_state.texture,
        &self.font_grid.atlas_greyscale,
        &self.texture_greyscale_modified,
        &self.texture_greyscale_resized,
        .red,
        .red,
    );
    try flushAtlasSingle(
        &self.font_grid.lock,
        gl_state.texture_color,
        &self.font_grid.atlas_color,
        &self.texture_color_modified,
        &self.texture_color_resized,
        .rgba,
        .bgra,
    );
}

/// Flush a single atlas, grabbing all necessary locks, checking for
/// changes, etc.
fn flushAtlasSingle(
    lock: *std.Thread.RwLock,
    texture: gl.Texture,
    atlas: *font.Atlas,
    modified: *usize,
    resized: *usize,
    interal_format: gl.Texture.InternalFormat,
    format: gl.Texture.Format,
) !void {
    // If the texture isn't modified we do nothing
    const new_modified = atlas.modified.load(.monotonic);
    if (new_modified <= modified.*) return;

    // If it is modified we need to grab a read-lock
    lock.lockShared();
    defer lock.unlockShared();

    var texbind = try texture.bind(.@"2D");
    defer texbind.unbind();

    const new_resized = atlas.resized.load(.monotonic);
    if (new_resized > resized.*) {
        try texbind.image2D(
            0,
            interal_format,
            @intCast(atlas.size),
            @intCast(atlas.size),
            0,
            format,
            .UnsignedByte,
            atlas.data.ptr,
        );

        // Only update the resized number after successful resize
        resized.* = new_resized;
    } else {
        try texbind.subImage2D(
            0,
            0,
            0,
            @intCast(atlas.size),
            @intCast(atlas.size),
            format,
            .UnsignedByte,
            atlas.data.ptr,
        );
    }

    // Update our modified tracker after successful update
    modified.* = atlas.modified.load(.monotonic);
}

/// Render renders the current cell state. This will not modify any of
/// the cells.
pub fn drawFrame(self: *OpenGL, surface: *apprt.Surface) !void {
    // If we're in single-threaded more we grab a lock since we use shared data.
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();
    const gl_state: *GLState = if (self.gl_state) |*v| v else return;

    // Go through our images and see if we need to setup any textures.
    {
        var image_it = self.images.iterator();
        while (image_it.next()) |kv| {
            switch (kv.value_ptr.image) {
                .ready => {},

                .pending_grey_alpha,
                .pending_rgb,
                .pending_rgba,
                .replace_grey_alpha,
                .replace_rgb,
                .replace_rgba,
                => try kv.value_ptr.image.upload(self.alloc),

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

    // Draw our terminal cells
    try self.drawCellProgram(gl_state);

    // Draw our custom shaders
    if (gl_state.custom) |*custom_state| {
        try self.drawCustomPrograms(custom_state);
    }

    // Swap our window buffers
    switch (apprt.runtime) {
        apprt.glfw => surface.window.swapBuffers(),
        apprt.gtk => {},
        apprt.embedded => {},
        else => @compileError("unsupported runtime"),
    }
}

/// Draw the custom shaders.
fn drawCustomPrograms(
    self: *OpenGL,
    custom_state: *custom.State,
) !void {
    _ = self;

    // Bind our state that is global to all custom shaders
    const custom_bind = try custom_state.bind();
    defer custom_bind.unbind();

    // Setup the new frame
    try custom_state.newFrame();

    // Go through each custom shader and draw it.
    for (custom_state.programs) |program| {
        // Bind our cell program state, buffers
        const bind = try program.bind();
        defer bind.unbind();
        try bind.draw();
    }
}

/// Runs the cell program (shaders) to draw the terminal grid.
fn drawCellProgram(
    self: *OpenGL,
    gl_state: *const GLState,
) !void {
    // Try to flush our atlas, this will only do something if there
    // are changes to the atlas.
    try self.flushAtlas();

    // If we have custom shaders, then we draw to the custom
    // shader framebuffer.
    const fbobind: ?gl.Framebuffer.Binding = fbobind: {
        const state = gl_state.custom orelse break :fbobind null;
        break :fbobind try state.fbo.bind(.framebuffer);
    };
    defer if (fbobind) |v| v.unbind();

    // Clear the surface
    gl.clearColor(
        @as(f32, @floatFromInt(self.draw_background.r)) / 255,
        @as(f32, @floatFromInt(self.draw_background.g)) / 255,
        @as(f32, @floatFromInt(self.draw_background.b)) / 255,
        @floatCast(self.config.background_opacity),
    );
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);

    // If we have deferred operations, run them.
    if (self.deferred_screen_size) |v| {
        try v.apply(self);
        self.deferred_screen_size = null;
    }
    if (self.deferred_font_size) |v| {
        try v.apply(self);
        self.deferred_font_size = null;
    }
    if (self.deferred_config) |v| {
        try v.apply(self);
        self.deferred_config = null;
    }

    // Draw background images first
    try self.drawImages(
        gl_state,
        self.image_placements.items[0..self.image_bg_end],
    );

    // Draw our background
    try self.drawCells(gl_state, self.cells_bg);

    // Then draw images under text
    try self.drawImages(
        gl_state,
        self.image_placements.items[self.image_bg_end..self.image_text_end],
    );

    // Drag foreground
    try self.drawCells(gl_state, self.cells);

    // Draw remaining images
    try self.drawImages(
        gl_state,
        self.image_placements.items[self.image_text_end..],
    );
}

/// Runs the image program to draw images.
fn drawImages(
    self: *OpenGL,
    gl_state: *const GLState,
    placements: []const gl_image.Placement,
) !void {
    if (placements.len == 0) return;

    // Bind our image program
    const bind = try gl_state.image_program.bind();
    defer bind.unbind();

    // For each placement we need to bind the texture
    for (placements) |p| {
        // Get the image and image texture
        const image = self.images.get(p.image_id) orelse {
            log.warn("image not found for placement image_id={}", .{p.image_id});
            continue;
        };

        const texture = switch (image.image) {
            .ready => |t| t,
            else => {
                log.warn("image not ready for placement image_id={}", .{p.image_id});
                continue;
            },
        };

        // Bind the texture
        try gl.Texture.active(gl.c.GL_TEXTURE0);
        var texbind = try texture.bind(.@"2D");
        defer texbind.unbind();

        // Setup our data
        try bind.vbo.setData(ImageProgram.Input{
            .grid_col = @intCast(p.x),
            .grid_row = @intCast(p.y),
            .cell_offset_x = p.cell_offset_x,
            .cell_offset_y = p.cell_offset_y,
            .source_x = p.source_x,
            .source_y = p.source_y,
            .source_width = p.source_width,
            .source_height = p.source_height,
            .dest_width = p.width,
            .dest_height = p.height,
        }, .static_draw);

        try gl.drawElementsInstanced(
            gl.c.GL_TRIANGLES,
            6,
            gl.c.GL_UNSIGNED_BYTE,
            1,
        );
    }
}

/// Loads some set of cell data into our buffer and issues a draw call.
/// This expects all the OpenGL state to be setup.
///
/// Future: when we move to multiple shaders, this will go away and
/// we'll have a draw call per-shader.
fn drawCells(
    self: *OpenGL,
    gl_state: *const GLState,
    cells: std.ArrayListUnmanaged(CellProgram.Cell),
) !void {
    // If we have no cells to render, then we render nothing.
    if (cells.items.len == 0) return;

    // Todo: get rid of this completely
    self.gl_cells_written = 0;

    // Bind our cell program state, buffers
    const bind = try gl_state.cell_program.bind();
    defer bind.unbind();

    // Bind our textures
    try gl.Texture.active(gl.c.GL_TEXTURE0);
    var texbind = try gl_state.texture.bind(.@"2D");
    defer texbind.unbind();

    try gl.Texture.active(gl.c.GL_TEXTURE1);
    var texbind1 = try gl_state.texture_color.bind(.@"2D");
    defer texbind1.unbind();

    // Our allocated buffer on the GPU is smaller than our capacity.
    // We reallocate a new buffer with the full new capacity.
    if (self.gl_cells_size < cells.capacity) {
        log.info("reallocating GPU buffer old={} new={}", .{
            self.gl_cells_size,
            cells.capacity,
        });

        try bind.vbo.setDataNullManual(
            @sizeOf(CellProgram.Cell) * cells.capacity,
            .static_draw,
        );

        self.gl_cells_size = cells.capacity;
        self.gl_cells_written = 0;
    }

    // If we have data to write to the GPU, send it.
    if (self.gl_cells_written < cells.items.len) {
        const data = cells.items[self.gl_cells_written..];
        // log.info("sending {} cells to GPU", .{data.len});
        try bind.vbo.setSubData(self.gl_cells_written * @sizeOf(CellProgram.Cell), data);

        self.gl_cells_written += data.len;
        assert(data.len > 0);
        assert(self.gl_cells_written <= cells.items.len);
    }

    try gl.drawElementsInstanced(
        gl.c.GL_TRIANGLES,
        6,
        gl.c.GL_UNSIGNED_BYTE,
        cells.items.len,
    );
}

/// The OpenGL objects that are associated with a renderer. This makes it
/// easy to create/destroy these as a set in situations i.e. where the
/// OpenGL context is replaced.
const GLState = struct {
    cell_program: CellProgram,
    image_program: ImageProgram,
    texture: gl.Texture,
    texture_color: gl.Texture,
    custom: ?custom.State,

    pub fn init(
        alloc: Allocator,
        config: DerivedConfig,
        font_grid: *font.SharedGrid,
    ) !GLState {
        var arena = ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Load our custom shaders
        const custom_state: ?custom.State = custom: {
            const shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                config.custom_shaders.items,
                .glsl,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };
            if (shaders.len == 0) break :custom null;

            break :custom custom.State.init(
                alloc,
                shaders,
            ) catch |err| err: {
                log.warn("error initializing custom shaders err={}", .{err});
                break :err null;
            };
        };

        // Blending for text. We use GL_ONE here because we should be using
        // premultiplied alpha for all our colors in our fragment shaders.
        // This avoids having a blurry border where transparency is expected on
        // pixels.
        try gl.enable(gl.c.GL_BLEND);
        try gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA);

        // Build our texture
        const tex = try gl.Texture.create();
        errdefer tex.destroy();
        {
            const texbind = try tex.bind(.@"2D");
            try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
            try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
            try texbind.image2D(
                0,
                .red,
                @intCast(font_grid.atlas_greyscale.size),
                @intCast(font_grid.atlas_greyscale.size),
                0,
                .red,
                .UnsignedByte,
                font_grid.atlas_greyscale.data.ptr,
            );
        }

        // Build our color texture
        const tex_color = try gl.Texture.create();
        errdefer tex_color.destroy();
        {
            const texbind = try tex_color.bind(.@"2D");
            try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
            try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
            try texbind.image2D(
                0,
                .rgba,
                @intCast(font_grid.atlas_color.size),
                @intCast(font_grid.atlas_color.size),
                0,
                .bgra,
                .UnsignedByte,
                font_grid.atlas_color.data.ptr,
            );
        }

        // Build our cell renderer
        const cell_program = try CellProgram.init();
        errdefer cell_program.deinit();

        // Build our image renderer
        const image_program = try ImageProgram.init();
        errdefer image_program.deinit();

        return .{
            .cell_program = cell_program,
            .image_program = image_program,
            .texture = tex,
            .texture_color = tex_color,
            .custom = custom_state,
        };
    }

    pub fn deinit(self: *GLState, alloc: Allocator) void {
        if (self.custom) |v| v.deinit(alloc);
        self.texture.destroy();
        self.texture_color.destroy();
        self.image_program.deinit();
        self.cell_program.deinit();
    }
};
