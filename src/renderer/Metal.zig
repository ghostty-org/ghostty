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
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const DevMode = @import("../DevMode.zig");
const Surface = @import("../Surface.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Terminal = terminal.Terminal;

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

/// Current cell dimensions for this grid.
cell_size: renderer.CellSize,

/// Current screen size dimensions for this grid. This is set on the first
/// resize event, and is not immediately available.
screen_size: ?renderer.ScreenSize,

/// Explicit padding.
padding: renderer.Options.Padding,

/// True if the window is focused
focused: bool,

/// Whether the cursor is visible or not. This is used to control cursor
/// blinking.
cursor_visible: bool,
cursor_style: renderer.CursorStyle,

/// The current set of cells to render. This is rebuilt on every frame
/// but we keep this around so that we don't reallocate. Each set of
/// cells goes into a separate shader.
cells_bg: std.ArrayListUnmanaged(GPUCell),
cells: std.ArrayListUnmanaged(GPUCell),

/// The current GPU uniform values.
uniforms: GPUUniforms,

/// The font structures.
font_group: *font.GroupCache,
font_shaper: font.Shaper,

/// Metal objects
device: objc.Object, // MTLDevice
queue: objc.Object, // MTLCommandQueue
swapchain: objc.Object, // CAMetalLayer
buf_cells_bg: objc.Object, // MTLBuffer
buf_cells: objc.Object, // MTLBuffer
buf_instance: objc.Object, // MTLBuffer
pipeline: objc.Object, // MTLRenderPipelineState
texture_greyscale: objc.Object, // MTLTexture
texture_color: objc.Object, // MTLTexture

const GPUCell = extern struct {
    mode: GPUCellMode,
    grid_pos: [2]f32,
    glyph_pos: [2]u32 = .{ 0, 0 },
    glyph_size: [2]u32 = .{ 0, 0 },
    glyph_offset: [2]i32 = .{ 0, 0 },
    color: [4]u8,
    cell_width: u8,
};

// Intel macOS 13 doesn't like it when any field in a vertex buffer is not
// aligned on the alignment of the struct. I don't understand it, I think
// this must be some macOS 13 Metal GPU driver bug because it doesn't matter
// on macOS 12 or Apple Silicon macOS 13.
//
// To be safe, we put this test in here.
test "GPUCell offsets" {
    const testing = std.testing;
    const alignment = @alignOf(GPUCell);
    inline for (@typeInfo(GPUCell).Struct.fields) |field| {
        const offset = @offsetOf(GPUCell, field.name);
        try testing.expectEqual(0, @mod(offset, alignment));
    }
}

const GPUUniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat,

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32,

    /// Metrics for underline/strikethrough
    strikethrough_position: f32,
    strikethrough_thickness: f32,
};

const GPUCellMode = enum(u8) {
    bg = 1,
    fg = 2,
    fg_color = 7,
    strikethrough = 8,
};

/// The configuration for this renderer that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    cursor_color: ?terminal.color.RGB,
    background: terminal.color.RGB,
    foreground: terminal.color.RGB,
    selection_background: ?terminal.color.RGB,
    selection_foreground: ?terminal.color.RGB,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        _ = alloc_gpa;

        return .{
            .cursor_color = if (config.@"cursor-color") |col|
                col.toTerminalRGB()
            else
                null,

            .background = config.background.toTerminalRGB(),
            .foreground = config.foreground.toTerminalRGB(),

            .selection_background = if (config.@"selection-background") |bg|
                bg.toTerminalRGB()
            else
                null,

            .selection_foreground = if (config.@"selection-foreground") |bg|
                bg.toTerminalRGB()
            else
                null,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        _ = self;
    }
};

/// Returns the hints that we want for this
pub fn glfwWindowHints() glfw.Window.Hints {
    return .{
        .client_api = .no_api,
        // .cocoa_graphics_switching = builtin.os.tag == .macos,
        // .cocoa_retina_framebuffer = true,
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
    // Initialize our metal stuff
    const device = objc.Object.fromId(MTLCreateSystemDefaultDevice());
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    const swapchain = swapchain: {
        const CAMetalLayer = objc.Class.getClass("CAMetalLayer").?;
        const swapchain = CAMetalLayer.msgSend(objc.Object, objc.sel("layer"), .{});
        swapchain.setProperty("device", device.value);
        swapchain.setProperty("opaque", true);

        // disable v-sync
        swapchain.setProperty("displaySyncEnabled", false);

        break :swapchain swapchain;
    };

    // Get our cell metrics based on a regular font ascii 'M'. Why 'M'?
    // Doesn't matter, any normal ASCII will do we're just trying to make
    // sure we use the regular font.
    const metrics = metrics: {
        const index = (try options.font_group.indexForCodepoint(alloc, 'M', .regular, .text)).?;
        const face = try options.font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    log.debug("cell dimensions={}", .{metrics});

    // Set the sprite font up
    options.font_group.group.sprite = font.sprite.Face{
        .width = @intFromFloat(metrics.cell_width),
        .height = @intFromFloat(metrics.cell_height),
        .thickness = 2,
        .underline_position = @intFromFloat(metrics.underline_position),
    };

    // Create the font shaper. We initially create a shaper that can support
    // a width of 160 which is a common width for modern screens to help
    // avoid allocations later.
    var shape_buf = try alloc.alloc(font.shape.Cell, 160);
    errdefer alloc.free(shape_buf);
    var font_shaper = try font.Shaper.init(alloc, shape_buf);
    errdefer font_shaper.deinit();

    // Initialize our Metal buffers
    const buf_instance = buffer: {
        const data = [6]u16{
            0, 1, 3, // Top-left triangle
            1, 2, 3, // Bottom-right triangle
        };

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithBytes:length:options:"),
            .{
                @as(*const anyopaque, @ptrCast(&data)),
                @as(c_ulong, @intCast(data.len * @sizeOf(u16))),
                MTLResourceStorageModeShared,
            },
        );
    };

    const buf_cells = buffer: {
        // Preallocate for 160x160 grid with 3 modes (bg, fg, text). This
        // should handle most terminals well, and we can avoid a resize later.
        const prealloc = 160 * 160 * 3;

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithLength:options:"),
            .{
                @as(c_ulong, @intCast(prealloc * @sizeOf(GPUCell))),
                MTLResourceStorageModeShared,
            },
        );
    };

    const buf_cells_bg = buffer: {
        // Preallocate for 160x160 grid with 3 modes (bg, fg, text). This
        // should handle most terminals well, and we can avoid a resize later.
        const prealloc = 160 * 160;

        break :buffer device.msgSend(
            objc.Object,
            objc.sel("newBufferWithLength:options:"),
            .{
                @as(c_ulong, @intCast(prealloc * @sizeOf(GPUCell))),
                MTLResourceStorageModeShared,
            },
        );
    };

    // Initialize our shader (MTLLibrary)
    const library = try initLibrary(device, @embedFile("shaders/cell.metal"));
    const pipeline_state = try initPipelineState(device, library);
    const texture_greyscale = try initAtlasTexture(device, &options.font_group.atlas_greyscale);
    const texture_color = try initAtlasTexture(device, &options.font_group.atlas_color);

    return Metal{
        .alloc = alloc,
        .config = options.config,
        .surface_mailbox = options.surface_mailbox,
        .cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height },
        .screen_size = null,
        .padding = options.padding,
        .focused = true,
        .cursor_visible = true,
        .cursor_style = .box,

        // Render state
        .cells_bg = .{},
        .cells = .{},
        .uniforms = .{
            .projection_matrix = undefined,
            .cell_size = undefined,
            .strikethrough_position = metrics.strikethrough_position,
            .strikethrough_thickness = metrics.strikethrough_thickness,
        },

        // Fonts
        .font_group = options.font_group,
        .font_shaper = font_shaper,

        // Metal stuff
        .device = device,
        .queue = queue,
        .swapchain = swapchain,
        .buf_cells = buf_cells,
        .buf_cells_bg = buf_cells_bg,
        .buf_instance = buf_instance,
        .pipeline = pipeline_state,
        .texture_greyscale = texture_greyscale,
        .texture_color = texture_color,
    };
}

pub fn deinit(self: *Metal) void {
    self.cells.deinit(self.alloc);
    self.cells_bg.deinit(self.alloc);

    self.font_shaper.deinit();
    self.alloc.free(self.font_shaper.cell_buf);

    self.config.deinit();

    deinitMTLResource(self.buf_cells_bg);
    deinitMTLResource(self.buf_cells);
    deinitMTLResource(self.buf_instance);
    deinitMTLResource(self.texture_greyscale);
    deinitMTLResource(self.texture_color);
    self.queue.msgSend(void, objc.sel("release"), .{});

    self.* = undefined;
}

/// This is called just prior to spinning up the renderer thread for
/// final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const Metal, surface: *apprt.Surface) !void {
    const Info = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the view and scale factor for our surface.
    const info: Info = switch (apprt.runtime) {
        apprt.glfw => info: {
            // Everything in glfw is window-oriented so we grab the backing
            // window, then derive everything from that.
            const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(surface.window).?);
            const contentView = objc.Object.fromId(nswindow.getProperty(?*anyopaque, "contentView").?);
            const scaleFactor = nswindow.getProperty(macos.graphics.c.CGFloat, "backingScaleFactor");
            break :info .{
                .view = contentView,
                .scaleFactor = scaleFactor,
            };
        },

        apprt.embedded => .{
            .view = surface.nsview,
            .scaleFactor = @floatCast(surface.content_scale.x),
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Make our view layer-backed with our Metal layer
    info.view.setProperty("layer", self.swapchain.value);
    info.view.setProperty("wantsLayer", true);

    // Ensure that our metal layer has a content scale set to match the
    // scale factor of the window. This avoids magnification issues leading
    // to blurry rendering.
    const layer = info.view.getProperty(objc.Object, "layer");
    layer.setProperty("contentsScale", info.scaleFactor);
}

/// This is called if this renderer runs DevMode.
pub fn initDevMode(self: *const Metal, surface: *apprt.Surface) !void {
    if (DevMode.enabled) {
        // Initialize for our window
        assert(imgui.ImplGlfw.initForOther(@ptrCast(surface.window.handle), true));
        assert(imgui.ImplMetal.init(self.device.value));
    }
}

/// This is called if this renderer runs DevMode.
pub fn deinitDevMode(self: *const Metal) void {
    _ = self;

    if (DevMode.enabled) {
        imgui.ImplMetal.shutdown();
        imgui.ImplGlfw.shutdown();
    }
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

/// Returns the grid size for a given screen size. This is safe to call
/// on any thread.
fn gridSize(self: *Metal) ?renderer.GridSize {
    const screen_size = self.screen_size orelse return null;
    return renderer.GridSize.init(
        screen_size.subPadding(self.padding.explicit),
        self.cell_size,
    );
}

/// Callback when the focus changes for the terminal this is rendering.
///
/// Must be called on the render thread.
pub fn setFocus(self: *Metal, focus: bool) !void {
    self.focused = focus;
}

/// Called to toggle the blink state of the cursor
///
/// Must be called on the render thread.
pub fn blinkCursor(self: *Metal, reset: bool) void {
    self.cursor_visible = reset or !self.cursor_visible;
}

/// Set the new font size.
///
/// Must be called on the render thread.
pub fn setFontSize(self: *Metal, size: font.face.DesiredSize) !void {
    log.info("set font size={}", .{size});

    // Set our new size, this will also reset our font atlas.
    try self.font_group.setSize(size);

    // Recalculate our metrics
    const metrics = metrics: {
        const index = (try self.font_group.indexForCodepoint(self.alloc, 'M', .regular, .text)).?;
        const face = try self.font_group.group.faceFromIndex(index);
        break :metrics face.metrics;
    };
    const new_cell_size = .{ .width = metrics.cell_width, .height = metrics.cell_height };

    // Update our uniforms
    self.uniforms = .{
        .projection_matrix = self.uniforms.projection_matrix,
        .cell_size = .{ new_cell_size.width, new_cell_size.height },
        .strikethrough_position = metrics.strikethrough_position,
        .strikethrough_thickness = metrics.strikethrough_thickness,
    };

    // Recalculate our cell size. If it is the same as before, then we do
    // nothing since the grid size couldn't have possibly changed.
    if (std.meta.eql(self.cell_size, new_cell_size)) return;
    self.cell_size = new_cell_size;

    // Resize our font shaping buffer to fit the new width.
    if (self.gridSize()) |grid_size| {
        var shape_buf = try self.alloc.alloc(font.shape.Cell, grid_size.columns * 2);
        errdefer self.alloc.free(shape_buf);
        self.alloc.free(self.font_shaper.cell_buf);
        self.font_shaper.cell_buf = shape_buf;
    }

    // Set the sprite font up
    self.font_group.group.sprite = font.sprite.Face{
        .width = @intFromFloat(self.cell_size.width),
        .height = @intFromFloat(self.cell_size.height),
        .thickness = 2,
        .underline_position = @intFromFloat(metrics.underline_position),
    };

    // Notify the window that the cell size changed.
    _ = self.surface_mailbox.push(.{
        .cell_size = new_cell_size,
    }, .{ .forever = {} });
}

/// The primary render callback that is completely thread-safe.
pub fn render(
    self: *Metal,
    surface: *apprt.Surface,
    state: *renderer.State,
) !void {
    _ = surface;

    // Data we extract out of the critical area.
    const Critical = struct {
        bg: terminal.color.RGB,
        devmode: bool,
        selection: ?terminal.Selection,
        screen: terminal.Screen,
        draw_cursor: bool,
    };

    // Update all our data as tightly as possible within the mutex.
    var critical: Critical = critical: {
        state.mutex.lock();
        defer state.mutex.unlock();

        // Setup our cursor state
        if (self.focused) {
            self.cursor_visible = self.cursor_visible and state.cursor.visible;
            self.cursor_style = renderer.CursorStyle.fromTerminal(state.cursor.style) orelse .box;
        } else {
            self.cursor_visible = true;
            self.cursor_style = .box_hollow;
        }

        // Swap bg/fg if the terminal is reversed
        const bg = self.config.background;
        const fg = self.config.foreground;
        defer {
            self.config.background = bg;
            self.config.foreground = fg;
        }
        if (state.terminal.modes.reverse_colors) {
            self.config.background = fg;
            self.config.foreground = bg;
        }

        // We used to share terminal state, but we've since learned through
        // analysis that it is faster to copy the terminal state than to
        // hold the lock wile rebuilding GPU cells.
        const viewport_bottom = state.terminal.screen.viewportIsBottom();
        var screen_copy = if (viewport_bottom) try state.terminal.screen.clone(
            self.alloc,
            .{ .active = 0 },
            .{ .active = state.terminal.rows - 1 },
        ) else try state.terminal.screen.clone(
            self.alloc,
            .{ .viewport = 0 },
            .{ .viewport = state.terminal.rows - 1 },
        );
        errdefer screen_copy.deinit();

        // Convert our selection to viewport points because we copy only
        // the viewport above.
        const selection: ?terminal.Selection = if (state.terminal.screen.selection) |sel|
            sel.toViewport(&state.terminal.screen)
        else
            null;

        break :critical .{
            .bg = self.config.background,
            .devmode = if (state.devmode) |dm| dm.visible else false,
            .selection = selection,
            .screen = screen_copy,
            .draw_cursor = self.cursor_visible and state.terminal.screen.viewportIsBottom(),
        };
    };
    defer critical.screen.deinit();

    // @autoreleasepool {}
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Build our GPU cells
    try self.rebuildCells(
        critical.selection,
        &critical.screen,
        critical.draw_cursor,
    );

    // Get our drawable (CAMetalDrawable)
    const drawable = self.swapchain.msgSend(objc.Object, objc.sel("nextDrawable"), .{});

    // If our font atlas changed, sync the texture data
    if (self.font_group.atlas_greyscale.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_greyscale, &self.texture_greyscale);
        self.font_group.atlas_greyscale.modified = false;
    }
    if (self.font_group.atlas_color.modified) {
        try syncAtlasTexture(self.device, &self.font_group.atlas_color, &self.texture_color);
        self.font_group.atlas_color.modified = false;
    }

    // Command buffer (MTLCommandBuffer)
    const buffer = self.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});

    {
        // MTLRenderPassDescriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.Class.getClass("MTLRenderPassDescriptor").?;
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

                // Texture is a property of CAMetalDrawable but if you run
                // Ghostty in XCode in debug mode it returns a CaptureMTLDrawable
                // which ironically doesn't implement CAMetalDrawable as a
                // property so we just send a message.
                const texture = drawable.msgSend(objc.c.id, objc.sel("texture"), .{});
                attachment.setProperty("loadAction", @intFromEnum(MTLLoadAction.clear));
                attachment.setProperty("storeAction", @intFromEnum(MTLStoreAction.store));
                attachment.setProperty("texture", texture);
                attachment.setProperty("clearColor", MTLClearColor{
                    .red = @as(f32, @floatFromInt(critical.bg.r)) / 255,
                    .green = @as(f32, @floatFromInt(critical.bg.g)) / 255,
                    .blue = @as(f32, @floatFromInt(critical.bg.b)) / 255,
                    .alpha = 1.0,
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

        //do we need to do this?
        //encoder.msgSend(void, objc.sel("setViewport:"), .{viewport});

        // Use our shader pipeline
        encoder.msgSend(void, objc.sel("setRenderPipelineState:"), .{self.pipeline.value});

        // Set our buffers
        encoder.msgSend(
            void,
            objc.sel("setVertexBytes:length:atIndex:"),
            .{
                @as(*const anyopaque, @ptrCast(&self.uniforms)),
                @as(c_ulong, @sizeOf(@TypeOf(self.uniforms))),
                @as(c_ulong, 1),
            },
        );
        encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{
                self.texture_greyscale.value,
                @as(c_ulong, 0),
            },
        );
        encoder.msgSend(
            void,
            objc.sel("setFragmentTexture:atIndex:"),
            .{
                self.texture_color.value,
                @as(c_ulong, 1),
            },
        );

        // Issue the draw calls for this shader
        try self.drawCells(encoder, &self.buf_cells_bg, self.cells_bg);
        try self.drawCells(encoder, &self.buf_cells, self.cells);

        // Build our devmode draw data. This sucks because it requires we
        // lock our state mutex but the metal imgui implementation requires
        // access to all this stuff.
        if (critical.devmode) {
            state.mutex.lock();
            defer state.mutex.unlock();

            if (DevMode.enabled) {
                if (state.devmode) |dm| {
                    if (dm.visible) {
                        imgui.ImplMetal.newFrame(desc.value);
                        imgui.ImplGlfw.newFrame();
                        try dm.update();
                        imgui.ImplMetal.renderDrawData(
                            try dm.render(),
                            buffer.value,
                            encoder.value,
                        );
                    }
                }
            }
        }
    }

    buffer.msgSend(void, objc.sel("presentDrawable:"), .{drawable.value});
    buffer.msgSend(void, objc.sel("commit"), .{});
}

/// Loads some set of cell data into our buffer and issues a draw call.
/// This expects all the Metal command encoder state to be setup.
///
/// Future: when we move to multiple shaders, this will go away and
/// we'll have a draw call per-shader.
fn drawCells(
    self: *Metal,
    encoder: objc.Object,
    buf: *objc.Object,
    cells: std.ArrayListUnmanaged(GPUCell),
) !void {
    try self.syncCells(buf, cells);
    encoder.msgSend(
        void,
        objc.sel("setVertexBuffer:offset:atIndex:"),
        .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
    );

    if (cells.items.len > 0) {
        encoder.msgSend(
            void,
            objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:"),
            .{
                @intFromEnum(MTLPrimitiveType.triangle),
                @as(c_ulong, 6),
                @intFromEnum(MTLIndexType.uint16),
                self.buf_instance.value,
                @as(c_ulong, 0),
                @as(c_ulong, cells.items.len),
            },
        );
    }
}

/// Update the configuration.
pub fn changeConfig(self: *Metal, config: *DerivedConfig) !void {
    self.config = config.*;
}

/// Resize the screen.
pub fn setScreenSize(self: *Metal, dim: renderer.ScreenSize) !void {
    // Store our screen size
    self.screen_size = dim;

    // Recalculate the rows/columns. This can't fail since we just set
    // the screen size above.
    const grid_size = self.gridSize().?;

    // Determine if we need to pad the window. For "auto" padding, we take
    // the leftover amounts on the right/bottom that don't fit a full grid cell
    // and we split them equal across all boundaries.
    const padding = self.padding.explicit.add(if (self.padding.balance)
        renderer.Padding.balanced(dim, grid_size, self.cell_size)
    else
        .{});
    const padded_dim = dim.subPadding(padding);

    // Update our shaper
    // TODO: don't reallocate if it is close enough (but bigger)
    var shape_buf = try self.alloc.alloc(font.shape.Cell, grid_size.columns * 2);
    errdefer self.alloc.free(shape_buf);
    self.alloc.free(self.font_shaper.cell_buf);
    self.font_shaper.cell_buf = shape_buf;

    // Set the size of the drawable surface to the bounds
    self.swapchain.setProperty("drawableSize", macos.graphics.Size{
        .width = @floatFromInt(dim.width),
        .height = @floatFromInt(dim.height),
    });

    // Setup our uniforms
    const old = self.uniforms;
    self.uniforms = .{
        .projection_matrix = math.ortho2d(
            -1 * padding.left,
            @as(f32, @floatFromInt(padded_dim.width)) + padding.right,
            @as(f32, @floatFromInt(padded_dim.height)) + padding.bottom,
            -1 * padding.top,
        ),
        .cell_size = .{ self.cell_size.width, self.cell_size.height },
        .strikethrough_position = old.strikethrough_position,
        .strikethrough_thickness = old.strikethrough_thickness,
    };

    log.debug("screen size screen={} grid={}, cell={}", .{ dim, grid_size, self.cell_size });
}

/// Sync all the CPU cells with the GPU state (but still on the CPU here).
/// This builds all our "GPUCells" on this struct, but doesn't send them
/// down to the GPU yet.
fn rebuildCells(
    self: *Metal,
    term_selection: ?terminal.Selection,
    screen: *terminal.Screen,
    draw_cursor: bool,
) !void {
    // Bg cells at most will need space for the visible screen size
    self.cells_bg.clearRetainingCapacity();
    try self.cells_bg.ensureTotalCapacity(self.alloc, screen.rows * screen.cols);

    // Over-allocate just to ensure we don't allocate again during loops.
    self.cells.clearRetainingCapacity();
    try self.cells.ensureTotalCapacity(
        self.alloc,

        // * 3 for background modes and cursor and underlines
        // + 1 for cursor
        (screen.rows * screen.cols * 2) + 1,
    );

    // This is the cell that has [mode == .fg] and is underneath our cursor.
    // We keep track of it so that we can invert the colors so the character
    // remains visible.
    var cursor_cell: ?GPUCell = null;

    // Build each cell
    var rowIter = screen.rowIterator(.viewport);
    var y: usize = 0;
    while (rowIter.next()) |row| {
        defer y += 1;

        // If this is the row with our cursor, then we may have to modify
        // the cell with the cursor.
        const start_i: usize = self.cells.items.len;
        defer if (draw_cursor and
            self.cursor_visible and
            self.cursor_style == .box and
            screen.viewportIsBottom() and
            y == screen.cursor.y)
        {
            for (self.cells.items[start_i..]) |cell| {
                if (cell.grid_pos[0] == @as(f32, @floatFromInt(screen.cursor.x)) and
                    cell.mode == .fg)
                {
                    cursor_cell = cell;
                    break;
                }
            }
        };

        // We need to get this row's selection if there is one for proper
        // run splitting.
        const row_selection = sel: {
            if (term_selection) |sel| {
                const screen_point = (terminal.point.Viewport{
                    .x = 0,
                    .y = y,
                }).toScreen(screen);
                if (sel.containedRow(screen, screen_point)) |row_sel| {
                    break :sel row_sel;
                }
            }

            break :sel null;
        };

        // Split our row into runs and shape each one.
        var iter = self.font_shaper.runIterator(self.font_group, row, row_selection);
        while (try iter.next(self.alloc)) |run| {
            for (try self.font_shaper.shape(run)) |shaper_cell| {
                if (self.updateCell(
                    term_selection,
                    screen,
                    row.getCell(shaper_cell.x),
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

        // Set row is not dirty anymore
        row.setDirty(false);
    }

    // Add the cursor at the end so that it overlays everything. If we have
    // a cursor cell then we invert the colors on that and add it in so
    // that we can always see it.
    if (draw_cursor) {
        self.addCursor(screen);
        if (cursor_cell) |*cell| {
            cell.color = .{ 0, 0, 0, 255 };
            self.cells.appendAssumeCapacity(cell.*);
        }
    }

    // Some debug mode safety checks
    if (std.debug.runtime_safety) {
        for (self.cells_bg.items) |cell| assert(cell.mode == .bg);
        for (self.cells.items) |cell| assert(cell.mode != .bg);
    }
}

pub fn updateCell(
    self: *Metal,
    selection: ?terminal.Selection,
    screen: *terminal.Screen,
    cell: terminal.Screen.Cell,
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

    // The colors for the cell.
    const colors: BgFg = colors: {
        // If we have a selection, then we need to check if this
        // cell is selected.
        // TODO(perf): we can check in advance if selection is in
        // our viewport at all and not run this on every point.
        var selection_res: ?BgFg = sel_colors: {
            if (selection) |sel| {
                const screen_point = (terminal.point.Viewport{
                    .x = x,
                    .y = y,
                }).toScreen(screen);

                // If we are selected, we our colors are just inverted fg/bg
                if (sel.contains(screen_point)) {
                    break :sel_colors BgFg{
                        .bg = self.config.selection_background orelse self.config.foreground,
                        .fg = self.config.selection_foreground orelse self.config.background,
                    };
                }
            }

            break :sel_colors null;
        };

        const res: BgFg = selection_res orelse if (!cell.attrs.inverse) .{
            // In normal mode, background and fg match the cell. We
            // un-optionalize the fg by defaulting to our fg color.
            .bg = if (cell.attrs.has_bg) cell.bg else null,
            .fg = if (cell.attrs.has_fg) cell.fg else self.config.foreground,
        } else .{
            // In inverted mode, the background MUST be set to something
            // (is never null) so it is either the fg or default fg. The
            // fg is either the bg or default background.
            .bg = if (cell.attrs.has_fg) cell.fg else self.config.foreground,
            .fg = if (cell.attrs.has_bg) cell.bg else self.config.background,
        };

        // If the cell is "invisible" then we just make fg = bg so that
        // the cell is transparent but still copy-able.
        if (cell.attrs.invisible) {
            break :colors BgFg{
                .bg = res.bg,
                .fg = res.bg orelse self.config.background,
            };
        }

        break :colors res;
    };

    // Alpha multiplier
    const alpha: u8 = if (cell.attrs.faint) 175 else 255;

    // If the cell has a background, we always draw it.
    if (colors.bg) |rgb| {
        self.cells_bg.appendAssumeCapacity(.{
            .mode = .bg,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ rgb.r, rgb.g, rgb.b, alpha },
        });
    }

    // If the cell has a character, draw it
    if (cell.char > 0) {
        // Render
        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            shaper_run.font_index,
            shaper_cell.glyph_index,
            @intFromFloat(@ceil(self.cell_size.height)),
        );

        // If we're rendering a color font, we use the color atlas
        const presentation = try self.font_group.group.presentationFromIndex(shaper_run.font_index);
        const mode: GPUCellMode = switch (presentation) {
            .text => .fg,
            .emoji => .fg_color,
        };

        self.cells.appendAssumeCapacity(.{
            .mode = mode,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
        });
    }

    if (cell.attrs.underline != .none) {
        const sprite: font.Sprite = switch (cell.attrs.underline) {
            .none => unreachable,
            .single => .underline,
            .double => .underline_double,
            .dotted => .underline_dotted,
            .dashed => .underline_dashed,
            .curly => .underline_curly,
        };

        const glyph = try self.font_group.renderGlyph(
            self.alloc,
            font.sprite_index,
            @intFromEnum(sprite),
            null,
        );

        const color = if (cell.attrs.underline_color) cell.underline_fg else colors.fg;

        self.cells.appendAssumeCapacity(.{
            .mode = .fg,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ color.r, color.g, color.b, alpha },
            .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
            .glyph_size = .{ glyph.width, glyph.height },
            .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
        });
    }

    if (cell.attrs.strikethrough) {
        self.cells.appendAssumeCapacity(.{
            .mode = .strikethrough,
            .grid_pos = .{ @as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)) },
            .cell_width = cell.widthLegacy(),
            .color = .{ colors.fg.r, colors.fg.g, colors.fg.b, alpha },
        });
    }

    return true;
}

fn addCursor(self: *Metal, screen: *terminal.Screen) void {
    // Add the cursor
    const cell = screen.getCell(
        .active,
        screen.cursor.y,
        screen.cursor.x,
    );

    const color = self.config.cursor_color orelse terminal.color.RGB{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    };

    const sprite: font.Sprite = switch (self.cursor_style) {
        .box => .cursor_rect,
        .box_hollow => .cursor_hollow_rect,
        .bar => .cursor_bar,
    };

    const glyph = self.font_group.renderGlyph(
        self.alloc,
        font.sprite_index,
        @intFromEnum(sprite),
        null,
    ) catch |err| {
        log.warn("error rendering cursor glyph err={}", .{err});
        return;
    };

    self.cells.appendAssumeCapacity(.{
        .mode = .fg,
        .grid_pos = .{
            @as(f32, @floatFromInt(screen.cursor.x)),
            @as(f32, @floatFromInt(screen.cursor.y)),
        },
        .cell_width = if (cell.attrs.wide) 2 else 1,
        .color = .{ color.r, color.g, color.b, 0xFF },
        .glyph_pos = .{ glyph.atlas_x, glyph.atlas_y },
        .glyph_size = .{ glyph.width, glyph.height },
        .glyph_offset = .{ glyph.offset_x, glyph.offset_y },
    });
}

/// Sync the vertex buffer inputs to the GPU. This will attempt to reuse
/// the existing buffer (of course!) but will allocate a new buffer if
/// our cells don't fit in it.
fn syncCells(
    self: *Metal,
    target: *objc.Object,
    cells: std.ArrayListUnmanaged(GPUCell),
) !void {
    const req_bytes = cells.items.len * @sizeOf(GPUCell);
    const avail_bytes = target.getProperty(c_ulong, "length");

    // If we need more bytes than our buffer has, we need to reallocate.
    if (req_bytes > avail_bytes) {
        // Deallocate previous buffer
        deinitMTLResource(target.*);

        // Allocate a new buffer with enough to hold double what we require.
        const size = req_bytes * 2;
        target.* = self.device.msgSend(
            objc.Object,
            objc.sel("newBufferWithLength:options:"),
            .{
                @as(c_ulong, @intCast(size * @sizeOf(GPUCell))),
                MTLResourceStorageModeShared,
            },
        );
    }

    // We can fit within the vertex buffer so we can just replace bytes.
    const dst = dst: {
        const ptr = target.msgSend(?[*]u8, objc.sel("contents"), .{}) orelse {
            log.warn("buf_cells contents ptr is null", .{});
            return error.MetalFailed;
        };

        break :dst ptr[0..req_bytes];
    };

    const src = src: {
        const ptr = @as([*]const u8, @ptrCast(cells.items.ptr));
        break :src ptr[0..req_bytes];
    };

    @memcpy(dst, src);
}

/// Sync the atlas data to the given texture. This copies the bytes
/// associated with the atlas to the given texture. If the atlas no longer
/// fits into the texture, the texture will be resized.
fn syncAtlasTexture(device: objc.Object, atlas: *const font.Atlas, texture: *objc.Object) !void {
    const width = texture.getProperty(c_ulong, "width");
    if (atlas.size > width) {
        // Free our old texture
        deinitMTLResource(texture.*);

        // Reallocate
        texture.* = try initAtlasTexture(device, atlas);
    }

    // Workaround for: https://github.com/ziglang/zig/issues/13598
    ghostty_metal_replaceregion(
        texture.value,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:").value,
        MTLRegion{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{
                .width = @intCast(atlas.size),
                .height = @intCast(atlas.size),
                .depth = 1,
            },
        },
        0,
        atlas.data.ptr,
        @as(c_ulong, atlas.format.depth() * atlas.size),
    );

    // Once the above linked issue is fixed, this is what we actually
    // want to do:
    //
    // texture.msgSend(
    //     void,
    //     objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
    //     .{
    //         MTLRegion{
    //             .origin = .{ .x = 0, .y = 0, .z = 0 },
    //             .size = .{
    //                 .width = @intCast(c_ulong, atlas.size),
    //                 .height = @intCast(c_ulong, atlas.size),
    //                 .depth = 1,
    //             },
    //         },
    //         @as(c_ulong, 0),
    //         atlas.data.ptr,
    //         @as(c_ulong, atlas.format.depth() * atlas.size),
    //     },
    // );

}

extern "c" fn ghostty_metal_replaceregion(
    objc.c.id,
    objc.c.SEL,
    MTLRegion,
    c_ulong,
    *anyopaque,
    c_ulong,
) void;

/// Initialize the shader library.
fn initLibrary(device: objc.Object, data: []const u8) !objc.Object {
    const source = try macos.foundation.String.createWithBytes(
        data,
        .utf8,
        false,
    );
    defer source.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithSource:options:error:"),
        .{
            source,
            @as(?*anyopaque, null),
            &err,
        },
    );
    try checkError(err);

    return library;
}

/// Initialize the render pipeline for our shader library.
fn initPipelineState(device: objc.Object, library: objc.Object) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };

    // Create the vertex descriptor. The vertex descriptor describves the
    // data layout of the vertex inputs. We use indexed (or "instanced")
    // rendering, so this makes it so that each instance gets a single
    // GPUCell as input.
    const vertex_desc = vertex_desc: {
        const desc = init: {
            const Class = objc.Class.getClass("MTLVertexDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Our attributes are the fields of the input
        const attrs = objc.Object.fromId(desc.getProperty(?*anyopaque, "attributes"));
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "mode")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 1)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "grid_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 2)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 3)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_size")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 4)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.int2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "glyph_offset")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 5)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.uchar4));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "color")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 6)},
            );

            attr.setProperty("format", @intFromEnum(MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(GPUCell, "cell_width")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }

        // The layout describes how and when we fetch the next vertex input.
        const layouts = objc.Object.fromId(desc.getProperty(?*anyopaque, "layouts"));
        {
            const layout = layouts.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Access each GPUCell per instance, not per vertex.
            layout.setProperty("stepFunction", @intFromEnum(MTLVertexStepFunction.per_instance));
            layout.setProperty("stride", @as(c_ulong, @sizeOf(GPUCell)));
        }

        break :vertex_desc desc;
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.Class.getClass("MTLRenderPipelineDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("vertexFunction", func_vert);
    desc.setProperty("fragmentFunction", func_frag);
    desc.setProperty("vertexDescriptor", vertex_desc);

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        // Value is MTLPixelFormatBGRA8Unorm
        attachment.setProperty("pixelFormat", @as(c_ulong, 80));

        // Blending. This is required so that our text we render on top
        // of our drawable properly blends into the bg.
        attachment.setProperty("blendingEnabled", true);
        attachment.setProperty("rgbBlendOperation", @intFromEnum(MTLBlendOperation.add));
        attachment.setProperty("alphaBlendOperation", @intFromEnum(MTLBlendOperation.add));
        attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(MTLBlendFactor.one));
        attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(MTLBlendFactor.one));
        attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(MTLBlendFactor.one_minus_source_alpha));
        attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(MTLBlendFactor.one_minus_source_alpha));
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);

    return pipeline_state;
}

/// Initialize a MTLTexture object for the given atlas.
fn initAtlasTexture(device: objc.Object, atlas: *const font.Atlas) !objc.Object {
    // Determine our pixel format
    const pixel_format: MTLPixelFormat = switch (atlas.format) {
        .greyscale => .r8unorm,
        .rgba => .bgra8unorm,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    // Create our descriptor
    const desc = init: {
        const Class = objc.Class.getClass("MTLTextureDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };

    // Set our properties
    desc.setProperty("pixelFormat", @intFromEnum(pixel_format));
    desc.setProperty("width", @as(c_ulong, @intCast(atlas.size)));
    desc.setProperty("height", @as(c_ulong, @intCast(atlas.size)));

    // Initialize
    const id = device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{desc},
    ) orelse return error.MetalFailed;

    return objc.Object.fromId(id);
}

/// Deinitialize a metal resource (buffer, texture, etc.) and free the
/// memory associated with it.
fn deinitMTLResource(obj: objc.Object) void {
    obj.msgSend(void, objc.sel("release"), .{});
}

fn checkError(err_: ?*anyopaque) !void {
    if (err_) |err| {
        const nserr = objc.Object.fromId(err);
        const str = @as(
            *macos.foundation.String,
            @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
        );

        log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
        return error.MetalFailed;
    }
}

/// https://developer.apple.com/documentation/metal/mtlloadaction?language=objc
const MTLLoadAction = enum(c_ulong) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// https://developer.apple.com/documentation/metal/mtlstoreaction?language=objc
const MTLStoreAction = enum(c_ulong) {
    dont_care = 0,
    store = 1,
};

/// https://developer.apple.com/documentation/metal/mtlstoragemode?language=objc
const MTLStorageMode = enum(c_ulong) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

/// https://developer.apple.com/documentation/metal/mtlprimitivetype?language=objc
const MTLPrimitiveType = enum(c_ulong) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// https://developer.apple.com/documentation/metal/mtlindextype?language=objc
const MTLIndexType = enum(c_ulong) {
    uint16 = 0,
    uint32 = 1,
};

/// https://developer.apple.com/documentation/metal/mtlvertexformat?language=objc
const MTLVertexFormat = enum(c_ulong) {
    uchar4 = 3,
    float2 = 29,
    int2 = 33,
    uint2 = 37,
    uchar = 45,
};

/// https://developer.apple.com/documentation/metal/mtlvertexstepfunction?language=objc
const MTLVertexStepFunction = enum(c_ulong) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
};

/// https://developer.apple.com/documentation/metal/mtlpixelformat?language=objc
const MTLPixelFormat = enum(c_ulong) {
    r8unorm = 10,
    bgra8unorm = 80,
};

/// https://developer.apple.com/documentation/metal/mtlpurgeablestate?language=objc
const MTLPurgeableState = enum(c_ulong) {
    empty = 4,
};

/// https://developer.apple.com/documentation/metal/mtlblendfactor?language=objc
const MTLBlendFactor = enum(c_ulong) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    dest_color = 6,
    one_minus_dest_color = 7,
    dest_alpha = 8,
    one_minus_dest_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
    source_1_color = 15,
    one_minus_source_1_color = 16,
    source_1_alpha = 17,
    one_minus_source_1_alpha = 18,
};

/// https://developer.apple.com/documentation/metal/mtlblendoperation?language=objc
const MTLBlendOperation = enum(c_ulong) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
};

/// https://developer.apple.com/documentation/metal/mtlresourceoptions?language=objc
/// (incomplete, we only use this mode so we just hardcode it)
const MTLResourceStorageModeShared: c_ulong = @intFromEnum(MTLStorageMode.shared) << 4;

const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

const MTLViewport = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

const MTLOrigin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

const MTLSize = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
