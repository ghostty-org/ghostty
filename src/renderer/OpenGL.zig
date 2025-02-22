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
const isCovering = @import("cell.zig").isCovering;
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
grid_metrics: font.Metrics,

/// The size of everything.
size: renderer.Size,

/// The current set of cells to render. Each set of cells goes into
/// a separate shader call.
cells_bg: std.ArrayListUnmanaged(CellProgram.Cell),
cells: std.ArrayListUnmanaged(CellProgram.Cell),

/// The last viewport that we based our rebuild off of. If this changes,
/// then we do a full rebuild of the cells. The pointer values in this pin
/// are NOT SAFE to read because they may be modified, freed, etc from the
/// termio thread. We treat the pointers as integers for comparison only.
cells_viewport: ?terminal.Pin = null,

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
texture_grayscale_modified: usize = 0,
texture_grayscale_resized: usize = 0,
texture_color_modified: usize = 0,
texture_color_resized: usize = 0,

/// True if the window is focused
focused: bool,

/// The foreground color set by an OSC 10 sequence. If unset then the default
/// value from the config file is used.
foreground_color: ?terminal.color.RGB,

/// Foreground color set in the user's config file.
default_foreground_color: terminal.color.RGB,

/// The background color set by an OSC 11 sequence. If unset then the default
/// value from the config file is used.
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

/// Whether we're doing padding extension for vertical sides.
padding_extend_top: bool = true,
padding_extend_bottom: bool = true,

/// The images that we may render.
images: ImageMap = .{},
image_placements: ImagePlacementList = .{},
image_bg_end: u32 = 0,
image_text_end: u32 = 0,
image_virtual: bool = false,

/// Deferred OpenGL operation to update the screen size.
const SetScreenSize = struct {
    size: renderer.Size,

    fn apply(self: SetScreenSize, r: *OpenGL) !void {
        const gl_state: *GLState = if (r.gl_state) |*v|
            v
        else
            return error.OpenGLUninitialized;

        // Apply our padding
        const grid_size = self.size.grid();
        const terminal_size = self.size.terminal();

        // Blank space around the grid.
        const blank: renderer.Padding = switch (r.config.padding_color) {
            // We can use zero padding because the background color is our
            // clear color.
            .background => .{},

            .extend, .@"extend-always" => self.size.screen.blankPadding(
                self.size.padding,
                grid_size,
                self.size.cell,
            ).add(self.size.padding),
        };

        // Update our viewport for this context to be the entire window.
        // OpenGL works in pixels, so we have to use the pixel size.
        try gl.viewport(
            0,
            0,
            @intCast(self.size.screen.width),
            @intCast(self.size.screen.height),
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
                    -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                    @floatFromInt(terminal_size.width + self.size.padding.right),
                    @floatFromInt(terminal_size.height + self.size.padding.bottom),
                    -1 * @as(f32, @floatFromInt(self.size.padding.top)),
                ),
            );
        }

        // Setup our grid padding
        {
            const program = gl_state.cell_program;
            const bind = try program.program.use();
            defer bind.unbind();
            try program.program.setUniform(
                "grid_padding",
                @Vector(4, f32){
                    @floatFromInt(blank.top),
                    @floatFromInt(blank.right),
                    @floatFromInt(blank.bottom),
                    @floatFromInt(blank.left),
                },
            );
            try program.program.setUniform(
                "grid_size",
                @Vector(2, f32){
                    @floatFromInt(grid_size.columns),
                    @floatFromInt(grid_size.rows),
                },
            );
        }

        // Update our custom shader resolution
        if (gl_state.custom) |*custom_state| {
            try custom_state.setScreenSize(self.size);
        }
    }
};

const SetFontSize = struct {
    metrics: font.Metrics,

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
    font_thicken_strength: u8,
    font_features: std.ArrayListUnmanaged([:0]const u8),
    font_styles: font.CodepointResolver.StyleStatus,
    cursor_color: ?terminal.color.RGB,
    cursor_invert: bool,
    cursor_text: ?terminal.color.RGB,
    cursor_opacity: f64,
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
        .size = options.size,
        .gl_state = gl_state,
        .font_grid = grid,
        .font_shaper = shaper,
        .font_shaper_cache = font.ShaperCache.init(),
        .draw_background = options.config.background,
        .focused = true,
        .foreground_color = null,
        .default_foreground_color = options.config.foreground,
        .background_color = null,
        .default_background_color = options.config.background,
        .cursor_color = null,
        .default_cursor_color = options.config.cursor_color,
        .cursor_invert = options.config.cursor_invert,
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
    self.texture_grayscale_modified = 0;
    self.texture_color_modified = 0;
    self.texture_grayscale_resized = 0;
    self.texture_color_resized = 0;

    // We need to reset our uniforms
    self.deferred_screen_size = .{ .size = self.size };
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

/// See Metal.
pub fn markDirty(self: *OpenGL) void {
    // Do nothing, we don't have dirty tracking yet.
    _ = self;
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
    self.texture_grayscale_modified = 0;
    self.texture_grayscale_resized = 0;
    self.texture_color_modified = 0;
    self.texture_color_resized = 0;

    // Reset our shaper cache. If our font changed (not just the size) then
    // the data in the shaper cache may be invalid and cannot be used, so we
    // always clear the cache just in case.
    const font_shaper_cache = font.ShaperCache.init();
    self.font_shaper_cache.deinit(self.alloc);
    self.font_shaper_cache = font_shaper_cache;

    // Update our screen size because the font grid can affect grid
    // metrics which update uniforms.
    self.deferred_screen_size = .{ .size = self.size };

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
        full_rebuild: bool,
        gl_bg: terminal.color.RGB,
        screen: terminal.Screen,
        screen_type: terminal.ScreenType,
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
            // prepKittyGraphics touches self.images which is also used
            // in drawFrame so if we're drawing on a separate thread we need
            // to lock this.
            if (single_threaded_draw) self.draw_mutex.lock();
            defer if (single_threaded_draw) self.draw_mutex.unlock();
            try self.prepKittyGraphics(state.terminal);
        }

        // If we have any terminal dirty flags set then we need to rebuild
        // the entire screen. This can be optimized in the future.
        const full_rebuild: bool = rebuild: {
            {
                const Int = @typeInfo(terminal.Terminal.Dirty).Struct.backing_integer.?;
                const v: Int = @bitCast(state.terminal.flags.dirty);
                if (v > 0) break :rebuild true;
            }
            {
                const Int = @typeInfo(terminal.Screen.Dirty).Struct.backing_integer.?;
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

        // Update our viewport pin for dirty tracking
        self.cells_viewport = viewport_pin;

        break :critical .{
            .full_rebuild = full_rebuild,
            .gl_bg = self.background_color orelse self.default_background_color,
            .screen = screen_copy,
            .screen_type = state.terminal.active_screen,
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
        // Find the image in storage
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
    self: *OpenGL,
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
    self: *OpenGL,
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

    // If we specify `rows` then our offset above is in viewport space
    // and not in the coordinate space of the source image. Without `rows`
    // that's one and the same.
    const source_offset_y: u32 = if (p.rows > 0) source_offset_y: {
        // Determine the scale factor to apply for this row height.
        const image_height: f64 = @floatFromInt(image.height);
        const viewport_height: f64 = @floatFromInt(p.rows * self.grid_metrics.cell_height);
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
    const dest_width = if (p.columns > 0) p.columns * self.grid_metrics.cell_width else source_width;
    const dest_height = if (p.rows > 0) rows: {
        // Clip to the viewport to handle scrolling. offset_y is already in
        // viewport scale so we can subtract it directly.
        break :rows (p.rows * self.grid_metrics.cell_height) - offset_y;
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
    self: *OpenGL,
    image: *const terminal.kitty.graphics.Image,
) !void {
    // We need to prep this image for upload if it isn't in the cache OR
    // it is in the cache but the transmit time doesn't match meaning this
    // image is different.
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

/// rebuildCells rebuilds all the GPU cells from our CPU state. This is a
/// slow operation but ensures that the GPU state exactly matches the CPU state.
/// In steady-state operation, we use some GPU tricks to send down stale data
/// that is ignored. This accumulates more memory; rebuildCells clears it.
///
/// Note this doesn't have to typically be manually called. Internally,
/// the renderer will do this when it needs more memory space.
pub fn rebuildCells(
    self: *OpenGL,
    rebuild: bool,
    screen: *terminal.Screen,
    screen_type: terminal.ScreenType,
    mouse: renderer.State.Mouse,
    preedit: ?renderer.State.Preedit,
    cursor_style_: ?renderer.CursorStyle,
    color_palette: *const terminal.color.Palette,
) !void {
    _ = screen_type;

    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    self.cells.clearRetainingCapacity();

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

    // These are all the foreground cells underneath the cursor.
    //
    // We keep track of these so that we can invert the colors and move them
    // in front of the block cursor so that the character remains visible.
    //
    // We init with a capacity of 4 to account for decorations such
    // as underline and strikethrough, as well as combining chars.
    var cursor_cells = try std.ArrayListUnmanaged(CellProgram.Cell).initCapacity(arena_alloc, 4);
    defer cursor_cells.deinit(arena_alloc);

    if (rebuild) {
        switch (self.config.padding_color) {
            .background => {},

            .extend, .@"extend-always" => {
                self.padding_extend_top = true;
                self.padding_extend_bottom = true;
            },
        }
    }

    const grid_size = self.size.grid();

    // We rebuild the cells row-by-row because we do font shaping by row.
    var row_it = screen.pages.rowIterator(.left_up, .{ .viewport = .{} }, null);
    // If our cell contents buffer is shorter than the screen viewport,
    // we render the rows that fit, starting from the bottom. If instead
    // the viewport is shorter than the cell contents buffer, we align
    // the top of the viewport with the top of the contents buffer.
    var y: terminal.size.CellCountInt = @min(
        screen.pages.rows,
        grid_size.rows,
    );
    while (row_it.next()) |row| {
        // The viewport may have more rows than our cell contents,
        // so we need to break from the loop early if we hit y = 0.
        if (y == 0) break;

        y -= 1;

        // True if we want to do font shaping around the cursor. We want to
        // do font shaping as long as the cursor is enabled.
        const shape_cursor = screen.viewportIsBottom() and
            y == screen.cursor.y;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (shape_cursor and cursor_style_ == .block) {
            const x = screen.cursor.x;
            const wide = row.cells(.all)[x].wide;
            const min_x = switch (wide) {
                .narrow, .spacer_head, .wide => x,
                .spacer_tail => x -| 1,
            };
            const max_x = switch (wide) {
                .narrow, .spacer_head, .spacer_tail => x,
                .wide => x +| 1,
            };
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_col < min_x or cell.grid_col > max_x) continue;
                if (cell.mode.isFg()) {
                    cursor_cells.append(arena_alloc, cell) catch {
                        // We silently ignore if this fails because
                        // worst case scenario some combining glyphs
                        // aren't visible under the cursor '\_('-')_/'
                    };
                }
            }
        };

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
                self.padding_extend_top = !row.neverExtendBg(
                    color_palette,
                    self.background_color orelse self.default_background_color,
                );
            } else if (y == self.size.grid().rows - 1) {
                self.padding_extend_bottom = !row.neverExtendBg(
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
        const row_cells = row_cells_all[0..@min(row_cells_all.len, grid_size.columns)];

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

            // If the cell has a background color, set it.
            const bg_color: [4]u8 = if (bg) |rgb| bg: {
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
                    if (style.bg(cell, color_palette) != null and !rgb.eql(self.background_color orelse self.default_background_color)) {
                        break :bg_alpha default;
                    }

                    // We apply background opacity.
                    var bg_alpha: f64 = @floatFromInt(default);
                    bg_alpha *= self.config.background_opacity;
                    bg_alpha = @ceil(bg_alpha);
                    break :bg_alpha @intFromFloat(bg_alpha);
                };

                try self.cells_bg.append(self.alloc, .{
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

                break :bg .{
                    rgb.r, rgb.g, rgb.b, bg_alpha,
                };
            } else .{
                self.draw_background.r,
                self.draw_background.g,
                self.draw_background.b,
                @intFromFloat(@max(0, @min(255, @round(self.config.background_opacity * 255)))),
            };

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
                bg_color,
            ) catch |err| {
                log.warn(
                    "error adding underline to cell, will be invalid x={} y={}, err={}",
                    .{ x, y, err },
                );
            };

            if (style.flags.overline) self.addOverline(
                @intCast(x),
                @intCast(y),
                fg,
                alpha,
                bg_color,
            ) catch |err| {
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
                        bg_color,
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
                bg_color,
            ) catch |err| {
                log.warn(
                    "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                    .{ x, y, err },
                );
            };
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

        _ = try self.addCursor(screen, cursor_style, cursor_color);
        for (cursor_cells.items) |*cell| {
            if (cell.mode.isFg() and cell.mode != .fg_color) {
                const cell_color = if (self.cursor_invert) blk: {
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

                cell.r = cell_color.r;
                cell.g = cell_color.g;
                cell.b = cell_color.b;
                cell.a = 255;
            }
            try self.cells.append(self.alloc, cell.*);
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
    try self.cells_bg.append(self.alloc, .{
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
    try self.cells.append(self.alloc, .{
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
    cursor_color: terminal.color.RGB,
) !?*const CellProgram.Cell {
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
                return null;
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
            return null;
        } orelse {
            // This should never happen because we embed nerd
            // fonts so we just log and return instead of fallback.
            log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
            return null;
        },
    };

    try self.cells.append(self.alloc, .{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(screen.cursor.y),
        .grid_width = if (wide) 2 else 1,
        .r = cursor_color.r,
        .g = cursor_color.g,
        .b = cursor_color.b,
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

/// Add an underline decoration to the specified cell
fn addUnderline(
    self: *OpenGL,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    style: terminal.Attribute.Underline,
    color: terminal.color.RGB,
    alpha: u8,
    bg: [4]u8,
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

    try self.cells.append(self.alloc, .{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(y),
        .grid_width = 1,
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

/// Add an overline decoration to the specified cell
fn addOverline(
    self: *OpenGL,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    color: terminal.color.RGB,
    alpha: u8,
    bg: [4]u8,
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

    try self.cells.append(self.alloc, .{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(y),
        .grid_width = 1,
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

/// Add a strikethrough decoration to the specified cell
fn addStrikethrough(
    self: *OpenGL,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    color: terminal.color.RGB,
    alpha: u8,
    bg: [4]u8,
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

    try self.cells.append(self.alloc, .{
        .mode = .fg,
        .grid_col = @intCast(x),
        .grid_row = @intCast(y),
        .grid_width = 1,
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

// Add a glyph to the specified cell.
fn addGlyph(
    self: *OpenGL,
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    cell_pin: terminal.Pin,
    shaper_cell: font.shape.Cell,
    shaper_run: font.shape.TextRun,
    color: terminal.color.RGB,
    alpha: u8,
    bg: [4]u8,
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

    // If we're rendering a color font, we use the color atlas
    const mode: CellProgram.CellMode = switch (try fgMode(
        render.presentation,
        cell_pin,
    )) {
        .normal => .fg,
        .color => .fg_color,
        .constrained => .fg_constrained,
        .powerline => .fg_powerline,
    };

    try self.cells.append(self.alloc, .{
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
    self.default_background_color = config.background;
    self.default_foreground_color = config.foreground;
    self.default_cursor_color = if (!config.cursor_invert) config.cursor_color else null;
    self.cursor_invert = config.cursor_invert;

    // Update our uniforms
    self.deferred_config = .{};

    self.config.deinit();
    self.config = config.*;
}

/// Set the screen size for rendering. This will update the projection
/// used for the shader so that the scaling of the grid is correct.
pub fn setScreenSize(
    self: *OpenGL,
    size: renderer.Size,
) !void {
    if (single_threaded_draw) self.draw_mutex.lock();
    defer if (single_threaded_draw) self.draw_mutex.unlock();

    // Reset our buffer sizes so that we free memory when the screen shrinks.
    // This could be made more clever by only doing this when the screen
    // shrinks but the performance cost really isn't that much.
    self.cells.clearAndFree(self.alloc);
    self.cells_bg.clearAndFree(self.alloc);

    // Store our screen size
    self.size = size;

    // Defer our OpenGL updates
    self.deferred_screen_size = .{ .size = size };

    log.debug("screen size size={}", .{size});
}

/// Updates the font texture atlas if it is dirty.
fn flushAtlas(self: *OpenGL) !void {
    const gl_state = self.gl_state orelse return;
    try flushAtlasSingle(
        &self.font_grid.lock,
        gl_state.texture,
        &self.font_grid.atlas_grayscale,
        &self.texture_grayscale_modified,
        &self.texture_grayscale_resized,
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
    internal_format: gl.Texture.InternalFormat,
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
            internal_format,
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

                .pending_gray,
                .pending_gray_alpha,
                .pending_rgb,
                .pending_rgba,
                .replace_gray,
                .replace_gray_alpha,
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

    // In the "OpenGL Programming Guide for Mac" it explains that: "When you
    // use an NSOpenGLView object with OpenGL calls that are issued from a
    // thread other than the main one, you must set up mutex locking."
    // This locks the context and avoids crashes that can happen due to
    // races with the underlying Metal layer that Apple is using to
    // implement OpenGL.
    const is_darwin = builtin.target.isDarwin();
    const ogl = if (comptime is_darwin) @cImport({
        @cInclude("OpenGL/OpenGL.h");
    }) else {};
    const cgl_ctx = if (comptime is_darwin) ogl.CGLGetCurrentContext();
    if (comptime is_darwin) _ = ogl.CGLLockContext(cgl_ctx);
    defer _ = if (comptime is_darwin) ogl.CGLUnlockContext(cgl_ctx);

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
fn drawCustomPrograms(self: *OpenGL, custom_state: *custom.State) !void {
    _ = self;
    assert(custom_state.programs.len > 0);

    // Bind our state that is global to all custom shaders
    const custom_bind = try custom_state.bind();
    defer custom_bind.unbind();

    // Setup the new frame
    try custom_state.newFrame();

    // Go through each custom shader and draw it.
    for (custom_state.programs) |program| {
        const bind = try program.bind();
        defer bind.unbind();
        try bind.draw();
        try custom_state.copyFramebuffer();
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
        @floatCast(@as(f32, @floatFromInt(self.draw_background.r)) / 255 * self.config.background_opacity),
        @floatCast(@as(f32, @floatFromInt(self.draw_background.g)) / 255 * self.config.background_opacity),
        @floatCast(@as(f32, @floatFromInt(self.draw_background.b)) / 255 * self.config.background_opacity),
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

    // Apply our padding extension fields
    {
        const program = gl_state.cell_program;
        const bind = try program.program.use();
        defer bind.unbind();
        try program.program.setUniform(
            "padding_vertical_top",
            self.padding_extend_top,
        );
        try program.program.setUniform(
            "padding_vertical_bottom",
            self.padding_extend_bottom,
        );
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
                config.custom_shaders,
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
                @intCast(font_grid.atlas_grayscale.size),
                @intCast(font_grid.atlas_grayscale.size),
                0,
                .red,
                .UnsignedByte,
                font_grid.atlas_grayscale.data.ptr,
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
