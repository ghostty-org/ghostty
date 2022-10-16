//! Window represents a single OS window.
//!
//! NOTE(multi-window): This may be premature, but this abstraction is here
//! to pave the way One Day(tm) for multi-window support. At the time of
//! writing, we support exactly one window.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Grid = @import("Grid.zig");
const glfw = @import("glfw");
const gl = @import("opengl.zig");
const imgui = @import("imgui");
const libuv = @import("libuv");
const Pty = @import("Pty.zig");
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const SegmentedPool = @import("segmented_pool.zig").SegmentedPool;
const trace = @import("tracy").trace;
const max_timer = @import("max_timer.zig");
const terminal = @import("terminal/main.zig");
const Config = @import("config.zig").Config;
const input = @import("input.zig");
const DevMode = @import("DevMode.zig");

const RenderTimer = max_timer.MaxTimer(renderTimerCallback);

const log = std.log.scoped(.window);

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// Allocator
alloc: Allocator,
alloc_io_arena: std.heap.ArenaAllocator,

/// The font structures
font_lib: font.Library,
font_group: *font.GroupCache,

/// The glfw window handle.
window: glfw.Window,

/// The glfw mouse cursor handle.
cursor: glfw.Cursor,

/// Imgui context
imgui_ctx: if (DevMode.enabled) *imgui.Context else void,

/// Whether the window is currently focused
focused: bool,

/// The terminal grid attached to this window.
grid: Grid,

/// The underlying pty for this window.
pty: Pty,

/// The command we're running for our tty.
command: Command,

/// Mouse state.
mouse: Mouse,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid. This is connected back to
/// a renderer.
terminal: terminal.Terminal,

/// The stream parser.
terminal_stream: terminal.Stream(*Window),

/// Cursor state.
terminal_cursor: Cursor,

/// Render at least 60fps.
render_timer: RenderTimer,

/// The reader/writer stream for the pty.
pty_stream: libuv.Tty,

/// This is the pool of available (unused) write requests. If you grab
/// one from the pool, you must put it back when you're done!
write_req_pool: SegmentedPool(libuv.WriteReq.T, WRITE_REQ_PREALLOC) = .{},

/// The pool of available buffers for writing to the pty.
write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

/// The app configuration
config: *const Config,

/// Window background color
bg_r: f32,
bg_g: f32,
bg_b: f32,
bg_a: f32,

/// Bracketed paste mode
bracketed_paste: bool = false,

/// Set to true for a single GLFW key/char callback cycle to cause the
/// char callback to ignore. GLFW seems to always do key followed by char
/// callbacks so we abuse that here. This is to solve an issue where commands
/// like such as "control-v" will write a "v" even if they're intercepted.
ignore_char: bool = false,

/// Information related to the current cursor for the window.
//
// QUESTION(mitchellh): should this be attached to the Screen instead?
// I'm not sure if the cursor settings stick to the screen, i.e. if you
// change to an alternate screen if those are preserved. Need to check this.
const Cursor = struct {
    /// Timer for cursor blinking.
    timer: libuv.Timer,

    /// Current cursor style. This can be set by escape sequences. To get
    /// the default style, the config has to be referenced.
    style: terminal.CursorStyle = .default,

    /// Whether the cursor is visible at all. This should not be used for
    /// "blink" settings, see "blink" for that. This is used to turn the
    /// cursor ON or OFF.
    visible: bool = true,

    /// Whether the cursor is currently blinking. If it is blinking, then
    /// the cursor will not be rendered.
    blink: bool = false,

    /// Start (or restart) the timer. This is idempotent.
    pub fn startTimer(self: Cursor) !void {
        try self.timer.start(
            cursorTimerCallback,
            0,
            self.timer.getRepeat(),
        );
    }

    /// Stop the timer. This is idempotent.
    pub fn stopTimer(self: Cursor) !void {
        try self.timer.stop();
    }
};

/// Mouse state for the window.
const Mouse = struct {
    /// The last tracked mouse button state by button.
    click_state: [input.MouseButton.max]input.MouseButtonState = .{.release} ** input.MouseButton.max,

    /// The last mods state when the last mouse button (whatever it was) was
    /// pressed or release.
    mods: input.Mods = .{},

    /// The point at which the left mouse click happened. This is in screen
    /// coordinates so that scrolling preserves the location.
    left_click_point: terminal.point.ScreenPoint = .{},

    /// The starting xpos/ypos of the left click. Note that if scrolling occurs,
    /// these will point to different "cells", but the xpos/ypos will stay
    /// stable during scrolling relative to the window.
    left_click_xpos: f64 = 0,
    left_click_ypos: f64 = 0,

    /// The last x/y sent for mouse reports.
    event_point: terminal.point.Viewport = .{},
};

/// Create a new window. This allocates and returns a pointer because we
/// need a stable pointer for user data callbacks. Therefore, a stack-only
/// initialization is not currently possible.
pub fn create(alloc: Allocator, loop: libuv.Loop, config: *const Config) !*Window {
    var self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    // Create our window
    const window = try glfw.Window.create(640, 480, "ghostty", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
        .opengl_forward_compat = true,
        .cocoa_graphics_switching = builtin.os.tag == .macos,
        .cocoa_retina_framebuffer = true,
    });
    errdefer window.destroy();

    // NOTE(multi-window): We'll need to extract all the below into a
    // dedicated renderer and consider the multi-threading (or at the very
    // least: multi-OpenGL-context) implications. Since we don't support
    // multiple windows right now, we just do it all here.

    // Setup OpenGL
    try glfw.makeContextCurrent(window);
    try glfw.swapInterval(1);

    // Load OpenGL bindings
    const version = try gl.glad.load(switch (builtin.zig_backend) {
        .stage1 => glfw.getProcAddress,
        else => &glfw.getProcAddress,
    });
    log.info("loaded OpenGL {}.{}", .{
        gl.glad.versionMajor(version),
        gl.glad.versionMinor(version),
    });
    if (builtin.mode == .Debug) {
        var ext_iter = try gl.ext.iterator();
        while (try ext_iter.next()) |ext| {
            log.debug("OpenGL extension available name={s}", .{ext});
        }
    }

    if (builtin.mode == .Debug) {
        // Get our physical DPI - debug only because we don't have a use for
        // this but the logging of it may be useful
        const monitor = window.getMonitor() orelse monitor: {
            log.warn("window had null monitor, getting primary monitor", .{});
            break :monitor glfw.Monitor.getPrimary().?;
        };
        const physical_size = monitor.getPhysicalSize();
        const video_mode = try monitor.getVideoMode();
        const physical_x_dpi = @intToFloat(f32, video_mode.getWidth()) / (@intToFloat(f32, physical_size.width_mm) / 25.4);
        const physical_y_dpi = @intToFloat(f32, video_mode.getHeight()) / (@intToFloat(f32, physical_size.height_mm) / 25.4);
        log.debug("physical dpi x={} y={}", .{
            physical_x_dpi,
            physical_y_dpi,
        });
    }

    // Determine our DPI configurations so we can properly configure
    // font points to pixels and handle other high-DPI scaling factors.
    const content_scale = try window.getContentScale();
    const x_dpi = content_scale.x_scale * font.face.default_dpi;
    const y_dpi = content_scale.y_scale * font.face.default_dpi;
    log.debug("xscale={} yscale={} xdpi={} ydpi={}", .{
        content_scale.x_scale,
        content_scale.y_scale,
        x_dpi,
        y_dpi,
    });

    // Culling, probably not necessary. We have to change the winding
    // order since our 0,0 is top-left.
    gl.c.glEnable(gl.c.GL_CULL_FACE);
    gl.c.glFrontFace(gl.c.GL_CW);

    // Blending for text
    gl.c.glEnable(gl.c.GL_BLEND);
    gl.c.glBlendFunc(gl.c.GL_SRC_ALPHA, gl.c.GL_ONE_MINUS_SRC_ALPHA);

    // The font size we desire along with the DPI determiend for the window
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @floatToInt(u16, x_dpi),
        .ydpi = @floatToInt(u16, y_dpi),
    };

    // Find all the fonts for this window
    var font_lib = try font.Library.init();
    errdefer font_lib.deinit();
    var font_group = try alloc.create(font.GroupCache);
    errdefer alloc.destroy(font_group);
    font_group.* = try font.GroupCache.init(alloc, group: {
        var group = try font.Group.init(alloc, font_lib, font_size);
        errdefer group.deinit(alloc);

        // Search for fonts
        if (font.Discover != void) {
            var disco = font.Discover.init();
            defer disco.deinit();

            if (config.@"font-family") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.debug("font regular: {s}", .{try face.name()});
                    try group.addFace(alloc, .regular, face);
                }
            }
            if (config.@"font-family-bold") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .bold = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.debug("font bold: {s}", .{try face.name()});
                    try group.addFace(alloc, .bold, face);
                }
            }
            if (config.@"font-family-italic") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .italic = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.debug("font italic: {s}", .{try face.name()});
                    try group.addFace(alloc, .italic, face);
                }
            }
            if (config.@"font-family-bold-italic") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .bold = true,
                    .italic = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.debug("font bold+italic: {s}", .{try face.name()});
                    try group.addFace(alloc, .bold_italic, face);
                }
            }
        }

        // If we're on Mac, then we try to use the Apple Emoji font for Emoji.
        if (builtin.os.tag == .macos and font.Discover != void) {
            var disco = font.Discover.init();
            defer disco.deinit();
            var disco_it = try disco.discover(.{
                .family = "Apple Color Emoji",
                .size = font_size.points,
            });
            defer disco_it.deinit();
            if (try disco_it.next()) |face| {
                log.debug("font emoji: {s}", .{try face.name()});
                try group.addFace(alloc, .regular, face);
            }
        }

        // Our built-in font will be used as a backup
        try group.addFace(
            alloc,
            .regular,
            font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_ttf, font_size)),
        );
        try group.addFace(
            alloc,
            .bold,
            font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_bold_ttf, font_size)),
        );

        // Emoji fallback. We don't include this on Mac since Mac is expected
        // to always have the Apple Emoji available.
        if (builtin.os.tag != .macos or font.Discover == void) {
            try group.addFace(
                alloc,
                .regular,
                font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_emoji_ttf, font_size)),
            );
            try group.addFace(
                alloc,
                .regular,
                font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_emoji_text_ttf, font_size)),
            );
        }

        break :group group;
    });
    errdefer font_group.deinit(alloc);

    // Create our terminal grid with the initial window size
    const window_size = try window.getSize();
    var grid = try Grid.init(alloc, font_group);
    try grid.setScreenSize(.{ .width = window_size.width, .height = window_size.height });
    grid.background = .{
        .r = config.background.r,
        .g = config.background.g,
        .b = config.background.b,
    };
    grid.foreground = .{
        .r = config.foreground.r,
        .g = config.foreground.g,
        .b = config.foreground.b,
    };

    // Set a minimum size that is cols=10 h=4. This matches Mac's Terminal.app
    // but is otherwise somewhat arbitrary.
    try window.setSizeLimits(.{
        .width = @floatToInt(u32, grid.cell_size.width * 10),
        .height = @floatToInt(u32, grid.cell_size.height * 4),
    }, .{ .width = null, .height = null });

    // Create our pty
    var pty = try Pty.open(.{
        .ws_row = @intCast(u16, grid.size.rows),
        .ws_col = @intCast(u16, grid.size.columns),
        .ws_xpixel = @intCast(u16, window_size.width),
        .ws_ypixel = @intCast(u16, window_size.height),
    });
    errdefer pty.deinit();

    // Create our child process
    const path = (try Command.expandPath(alloc, config.command orelse "sh")) orelse
        return error.CommandNotFound;
    defer alloc.free(path);

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");

    var cmd: Command = .{
        .path = path,
        .args = &[_][]const u8{path},
        .env = &env,
        .pre_exec = (struct {
            fn callback(c: *Command) void {
                const p = c.getData(Pty) orelse unreachable;
                p.childPreExec() catch |err|
                    log.err("error initializing child: {}", .{err});
            }
        }).callback,
        .data = &pty,
    };
    // note: can't set these in the struct initializer because it
    // sets the handle to "0". Probably a stage1 zig bug.
    cmd.stdin = std.fs.File{ .handle = pty.slave };
    cmd.stdout = cmd.stdin;
    cmd.stderr = cmd.stdin;
    try cmd.start(alloc);
    log.debug("started subcommand path={s} pid={?}", .{ path, cmd.pid });

    // Read data
    var stream = try libuv.Tty.init(alloc, loop, pty.master);
    errdefer stream.deinit(alloc);
    stream.setData(self);
    try stream.readStart(ttyReadAlloc, ttyRead);

    // Create our terminal
    var term = try terminal.Terminal.init(alloc, grid.size.columns, grid.size.rows);
    errdefer term.deinit(alloc);

    // Setup a timer for blinking the cursor
    var timer = try libuv.Timer.init(alloc, loop);
    errdefer timer.deinit(alloc);
    errdefer timer.close(null);
    timer.setData(self);
    try timer.start(cursorTimerCallback, 600, 600);

    // Create the cursor
    const cursor = try glfw.Cursor.createStandard(.ibeam);
    errdefer cursor.destroy();
    try window.setCursor(cursor);

    // Create our IO allocator arena. Libuv appears to guarantee (in code,
    // not in docs) that read_alloc is called directly before a read so
    // we can use an arena to make allocation faster.
    var io_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer io_arena.deinit();

    self.* = .{
        .alloc = alloc,
        .alloc_io_arena = io_arena,
        .font_lib = font_lib,
        .font_group = font_group,
        .window = window,
        .cursor = cursor,
        .focused = false,
        .grid = grid,
        .pty = pty,
        .command = cmd,
        .mouse = .{},
        .terminal = term,
        .terminal_stream = .{ .handler = self },
        .terminal_cursor = .{
            .timer = timer,
            .style = .blinking_block,
        },
        .render_timer = try RenderTimer.init(loop, self, 6, 12),
        .pty_stream = stream,
        .config = config,
        .bg_r = @intToFloat(f32, config.background.r) / 255.0,
        .bg_g = @intToFloat(f32, config.background.g) / 255.0,
        .bg_b = @intToFloat(f32, config.background.b) / 255.0,
        .bg_a = 1.0,

        .imgui_ctx = if (!DevMode.enabled) void else try imgui.Context.create(),
    };
    errdefer if (DevMode.enabled) self.imgui_ctx.destroy();

    // Setup our callbacks and user data
    window.setUserPointer(self);
    window.setSizeCallback(sizeCallback);
    window.setCharCallback(charCallback);
    window.setKeyCallback(keyCallback);
    window.setFocusCallback(focusCallback);
    window.setRefreshCallback(refreshCallback);
    window.setScrollCallback(scrollCallback);
    window.setCursorPosCallback(cursorPosCallback);
    window.setMouseButtonCallback(mouseButtonCallback);

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the window
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    sizeCallback(
        window,
        @intCast(i32, window_size.width),
        @intCast(i32, window_size.height),
    );

    // Load imgui. This must be done LAST because it has to be done after
    // all our GLFW setup is complete.
    if (DevMode.enabled) {
        const io = try imgui.IO.get();
        io.cval().IniFilename = "ghostty_dev_mode.ini";

        // On Mac imgui handles scaling automatically just fine. On Linux
        // and other platforms we need to apply a scaling factor.
        if (builtin.os.tag != .macos) io.cval().FontGlobalScale = content_scale.x_scale;

        const style = try imgui.Style.get();
        style.colorsDark();

        assert(imgui.ImplGlfw.initForOpenGL(
            @ptrCast(*imgui.ImplGlfw.GLFWWindow, window.handle),
            true,
        ));
        assert(imgui.ImplOpenGL3.init("#version 330 core"));
    }

    return self;
}

pub fn destroy(self: *Window) void {
    if (DevMode.enabled) {
        // Uninitialize imgui
        imgui.ImplOpenGL3.shutdown();
        imgui.ImplGlfw.shutdown();
        self.imgui_ctx.destroy();
    }

    // Deinitialize the pty. This closes the pty handles. This should
    // cause a close in the our subprocess so just wait for that.
    self.pty.deinit();
    _ = self.command.wait() catch |err|
        log.err("error waiting for command to exit: {}", .{err});

    self.terminal.deinit(self.alloc);
    self.grid.deinit();
    self.window.destroy();

    self.terminal_cursor.timer.close((struct {
        fn callback(t: *libuv.Timer) void {
            const alloc = t.loop().getData(Allocator).?.*;
            t.deinit(alloc);
        }
    }).callback);

    self.render_timer.deinit();

    // We have to dealloc our window in the close callback because
    // we can't free some of the memory associated with the window
    // until the stream is closed.
    self.pty_stream.readStop();
    self.pty_stream.close((struct {
        fn callback(t: *libuv.Tty) void {
            const win = t.getData(Window).?;
            const alloc = win.alloc;
            t.deinit(alloc);
            win.write_req_pool.deinit(alloc);
            win.write_buf_pool.deinit(alloc);
            win.alloc.destroy(win);
        }
    }).callback);

    // We can destroy the cursor right away. glfw will just revert any
    // windows using it to the default.
    self.cursor.destroy();

    self.font_group.deinit(self.alloc);
    self.font_lib.deinit();

    self.alloc_io_arena.deinit();
}

pub fn shouldClose(self: Window) bool {
    return self.window.shouldClose();
}

/// Queue a write to the pty.
fn queueWrite(self: *Window, data: []const u8) !void {
    // We go through and chunk the data if necessary to fit into
    // our cached buffers that we can queue to the stream.
    var i: usize = 0;
    while (i < data.len) {
        const req = try self.write_req_pool.get();
        const buf = try self.write_buf_pool.get();
        const end = @minimum(data.len, i + buf.len);
        std.mem.copy(u8, buf, data[i..end]);
        try self.pty_stream.write(
            .{ .req = req },
            &[1][]u8{buf[0..(end - i)]},
            ttyWrite,
        );

        i = end;
    }
}

/// The cursor position from glfw directly is in screen coordinates but
/// all our internal state works in pixels.
fn cursorPosToPixels(self: Window, pos: glfw.Window.CursorPos) glfw.Window.CursorPos {
    // The cursor position is in screen coordinates but we
    // want it in pixels. we need to get both the size of the
    // window in both to get the ratio to make the conversion.
    const size = self.window.getSize() catch unreachable;
    const fb_size = self.window.getFramebufferSize() catch unreachable;

    // If our framebuffer and screen are the same, then there is no scaling
    // happening and we can short-circuit by returning the pos as-is.
    if (fb_size.width == size.width and fb_size.height == size.height)
        return pos;

    const x_scale = @intToFloat(f64, fb_size.width) / @intToFloat(f64, size.width);
    const y_scale = @intToFloat(f64, fb_size.height) / @intToFloat(f64, size.height);
    return .{
        .xpos = pos.xpos * x_scale,
        .ypos = pos.ypos * y_scale,
    };
}

fn sizeCallback(window: glfw.Window, width: i32, height: i32) void {
    const tracy = trace(@src());
    defer tracy.end();

    // glfw gives us signed integers, but negative width/height is n
    // non-sensical so we use unsigned throughout, so assert.
    assert(width >= 0);
    assert(height >= 0);

    // Get our framebuffer size since this will give us the size in pixels
    // whereas width/height in this callback is in screen coordinates. For
    // Retina displays (or any other displays that have a scale factor),
    // these will not match.
    const px_size = window.getFramebufferSize() catch |err| err: {
        log.err("error querying window size in pixels, will use screen size err={}", .{err});
        break :err glfw.Window.Size{
            .width = @intCast(u32, width),
            .height = @intCast(u32, height),
        };
    };

    // Update our grid so that the projections on render are correct.
    const win = window.getUserPointer(Window) orelse return;
    win.grid.setScreenSize(.{
        .width = px_size.width,
        .height = px_size.height,
    }) catch |err| log.err("error updating grid screen size err={}", .{err});

    // Update the size of our terminal state
    win.terminal.resize(win.alloc, win.grid.size.columns, win.grid.size.rows) catch |err|
        log.err("error updating terminal size: {}", .{err});

    // Update the size of our pty
    win.pty.setSize(.{
        .ws_row = @intCast(u16, win.grid.size.rows),
        .ws_col = @intCast(u16, win.grid.size.columns),
        .ws_xpixel = @intCast(u16, width),
        .ws_ypixel = @intCast(u16, height),
    }) catch |err| log.err("error updating pty screen size err={}", .{err});

    // Update our viewport for this context to be the entire window.
    // OpenGL works in pixels, so we have to use the pixel size.
    gl.viewport(0, 0, @intCast(i32, px_size.width), @intCast(i32, px_size.height)) catch |err|
        log.err("error updating OpenGL viewport err={}", .{err});

    // Draw
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render timer in sizeCallback err={}", .{err});
}

fn charCallback(window: glfw.Window, codepoint: u21) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // Ignore if requested. See field docs for more information.
    if (win.ignore_char) {
        win.ignore_char = false;
        return;
    }

    // Anytime is character is created, we have to clear the selection
    if (win.terminal.selection != null) {
        win.terminal.selection = null;
        win.render_timer.schedule() catch |err|
            log.err("error scheduling render in charCallback err={}", .{err});
    }

    // We want to scroll to the bottom
    // TODO: detect if we're at the bottom to avoid the render call here.
    win.terminal.scrollViewport(.{ .bottom = {} }) catch |err|
        log.err("error scrolling viewport err={}", .{err});
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render in charCallback err={}", .{err});

    // Write the character to the pty
    win.queueWrite(&[1]u8{@intCast(u8, codepoint)}) catch |err|
        log.err("error queueing write in charCallback err={}", .{err});
}

fn keyCallback(
    window: glfw.Window,
    key: glfw.Key,
    scancode: i32,
    action: glfw.Action,
    mods: glfw.Mods,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // Reset the ignore char setting. If we didn't handle the char
    // by here, we aren't going to get it so we just reset this.
    win.ignore_char = false;

    //log.info("KEY {} {} {} {}", .{ key, scancode, mods, action });
    _ = scancode;

    if (action == .press or action == .repeat) {
        // Convert our glfw input into a platform agnostic trigger. When we
        // extract the platform out of this file, we'll pull a lot of this out
        // into a function. For now, this is the only place we do it so we just
        // put it right here.
        const trigger: input.Binding.Trigger = .{
            .mods = @bitCast(input.Mods, mods),
            .key = switch (key) {
                .a => .a,
                .b => .b,
                .c => .c,
                .d => .d,
                .e => .e,
                .f => .f,
                .g => .g,
                .h => .h,
                .i => .i,
                .j => .j,
                .k => .k,
                .l => .l,
                .m => .m,
                .n => .n,
                .o => .o,
                .p => .p,
                .q => .q,
                .r => .r,
                .s => .s,
                .t => .t,
                .u => .u,
                .v => .v,
                .w => .w,
                .x => .x,
                .y => .y,
                .z => .z,
                .up => .up,
                .down => .down,
                .right => .right,
                .left => .left,
                .home => .home,
                .end => .end,
                .page_up => .page_up,
                .page_down => .page_down,
                .F1 => .f1,
                .F2 => .f2,
                .F3 => .f3,
                .F4 => .f4,
                .F5 => .f5,
                .F6 => .f6,
                .F7 => .f7,
                .F8 => .f8,
                .F9 => .f9,
                .F10 => .f10,
                .F11 => .f11,
                .F12 => .f12,
                .grave_accent => .grave_accent,
                else => .invalid,
            },
        };

        if (win.config.keybind.set.get(trigger)) |binding_action| {
            //log.warn("BINDING ACTION={}", .{binding_action});

            switch (binding_action) {
                .unbind => unreachable,
                .ignore => {},

                .csi => |data| {
                    win.queueWrite("\x1B[") catch |err|
                        log.err("error queueing write in keyCallback err={}", .{err});
                    win.queueWrite(data) catch |err|
                        log.warn("error pasting clipboard: {}", .{err});
                },

                .copy_to_clipboard => {
                    if (win.terminal.selection) |sel| {
                        var buf = win.terminal.screen.selectionString(win.alloc, sel) catch |err| {
                            log.err("error reading selection string err={}", .{err});
                            return;
                        };
                        defer win.alloc.free(buf);

                        glfw.setClipboardString(buf) catch |err| {
                            log.err("error setting clipboard string err={}", .{err});
                            return;
                        };
                    }
                },

                .paste_from_clipboard => {
                    const data = glfw.getClipboardString() catch |err| {
                        log.warn("error reading clipboard: {}", .{err});
                        return;
                    };

                    if (data.len > 0) {
                        if (win.bracketed_paste) win.queueWrite("\x1B[200~") catch |err|
                            log.err("error queueing write in keyCallback err={}", .{err});
                        win.queueWrite(data) catch |err|
                            log.warn("error pasting clipboard: {}", .{err});
                        if (win.bracketed_paste) win.queueWrite("\x1B[201~") catch |err|
                            log.err("error queueing write in keyCallback err={}", .{err});
                    }
                },

                .toggle_dev_mode => if (DevMode.enabled) {
                    DevMode.instance.visible = !DevMode.instance.visible;
                    win.render_timer.schedule() catch unreachable;
                } else log.warn("dev mode was not compiled into this binary", .{}),
            }

            // Bindings always result in us ignoring the char if printable
            win.ignore_char = true;

            // No matter what, if there is a binding then we are done.
            return;
        }

        // Handle non-printables
        const char: u8 = char: {
            const mods_int = @bitCast(u8, mods);
            const ctrl_only = @bitCast(u8, glfw.Mods{ .control = true });

            // If we're only pressing control, check if this is a character
            // we convert to a non-printable.
            if (mods_int == ctrl_only) {
                const val: u8 = switch (key) {
                    .a => 0x01,
                    .b => 0x02,
                    .c => 0x03,
                    .d => 0x04,
                    .e => 0x05,
                    .f => 0x06,
                    .g => 0x07,
                    .h => 0x08,
                    .i => 0x09,
                    .j => 0x0A,
                    .k => 0x0B,
                    .l => 0x0C,
                    .m => 0x0D,
                    .n => 0x0E,
                    .o => 0x0F,
                    .p => 0x10,
                    .q => 0x11,
                    .r => 0x12,
                    .s => 0x13,
                    .t => 0x14,
                    .u => 0x15,
                    .v => 0x16,
                    .w => 0x17,
                    .x => 0x18,
                    .y => 0x19,
                    .z => 0x1A,
                    else => 0,
                };

                if (val > 0) break :char val;
            }

            // Otherwise, we don't care what modifiers we press we do this.
            break :char @as(u8, switch (key) {
                .backspace => 0x7F,
                .enter => '\r',
                .tab => '\t',
                .escape => 0x1B,
                else => 0,
            });
        };
        if (char > 0) {
            win.queueWrite(&[1]u8{char}) catch |err|
                log.err("error queueing write in keyCallback err={}", .{err});
        }
    }
}

fn focusCallback(window: glfw.Window, focused: bool) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If we aren't changing focus state, do nothing. I don't think this
    // can happen but it costs very little to check.
    if (win.focused == focused) return;

    // We have to schedule a render because no matter what we're changing
    // the cursor. If we're focused its reappearing, if we're not then
    // its changing to hollow and not blinking.
    win.render_timer.schedule() catch unreachable;

    // Set our focused state on the window.
    win.focused = focused;

    if (focused)
        win.terminal_cursor.startTimer() catch unreachable
    else
        win.terminal_cursor.stopTimer() catch unreachable;
}

fn refreshCallback(window: glfw.Window) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // The point of this callback is to schedule a render, so do that.
    win.render_timer.schedule() catch unreachable;
}

fn scrollCallback(window: glfw.Window, xoff: f64, yoff: f64) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If we're scrolling up or down, then send a mouse event
    if (yoff != 0) {
        const pos = window.getCursorPos() catch |err| {
            log.err("error reading cursor position: {}", .{err});
            return;
        };

        win.mouseReport(if (yoff < 0) .four else .five, .press, win.mouse.mods, pos) catch |err| {
            log.err("error reporting mouse event: {}", .{err});
            return;
        };
    }

    //log.info("SCROLL: {} {}", .{ xoff, yoff });
    _ = xoff;

    // Positive is up
    const sign: isize = if (yoff > 0) -1 else 1;
    const delta: isize = sign * @maximum(@divFloor(win.grid.size.rows, 15), 1);
    log.info("scroll: delta={}", .{delta});
    win.terminal.scrollViewport(.{ .delta = delta }) catch |err|
        log.err("error scrolling viewport err={}", .{err});

    // Schedule render since scrolling usually does something.
    // TODO(perf): we can only schedule render if we know scrolling
    // did something
    win.render_timer.schedule() catch unreachable;
}

/// The type of action to report for a mouse event.
const MouseReportAction = enum { press, release, motion };

fn mouseReport(
    self: *Window,
    button: ?input.MouseButton,
    action: MouseReportAction,
    mods: input.Mods,
    unscaled_pos: glfw.Window.CursorPos,
) !void {
    // TODO: posToViewport currently clamps to the window boundary,
    // do we want to not report mouse events at all outside the window?

    // Depending on the event, we may do nothing at all.
    switch (self.terminal.modes.mouse_event) {
        .none => return,

        // X10 only reports clicks with mouse button 1, 2, 3. We verify
        // the button later.
        .x10 => if (action != .press or
            button == null or
            !(button.? == .left or
            button.? == .right or
            button.? == .middle)) return,

        // Doesn't report motion
        .normal => if (action == .motion) return,

        // Button must be pressed
        .button => if (button == null) return,

        // Everything
        .any => {},
    }

    // This format reports X/Y
    const pos = self.cursorPosToPixels(unscaled_pos);
    const viewport_point = self.posToViewport(pos.xpos, pos.ypos);

    // For button events, we only report if we moved cells
    if (self.terminal.modes.mouse_event == .button or
        self.terminal.modes.mouse_event == .any)
    {
        if (self.mouse.event_point.x == viewport_point.x and
            self.mouse.event_point.y == viewport_point.y) return;

        // Record our new point
        self.mouse.event_point = viewport_point;
    }

    // Get the code we'll actually write
    const button_code: u8 = code: {
        var acc: u8 = 0;

        // Determine our initial button value
        if (button == null) {
            // Null button means motion without a button pressed
            acc = 3;
        } else if (action == .release and self.terminal.modes.mouse_format != .sgr) {
            // Release is 3. It is NOT 3 in SGR mode because SGR can tell
            // the application what button was released.
            acc = 3;
        } else {
            acc = switch (button.?) {
                .left => 0,
                .right => 1,
                .middle => 2,
                .four => 64,
                .five => 65,
                else => return, // unsupported
            };
        }

        // X10 doesn't have modifiers
        if (self.terminal.modes.mouse_event != .x10) {
            if (mods.shift) acc += 4;
            if (mods.super) acc += 8;
            if (mods.ctrl) acc += 16;
        }

        // Motion adds another bit
        if (action == .motion) acc += 32;

        break :code acc;
    };

    switch (self.terminal.modes.mouse_format) {
        .x10 => {
            if (viewport_point.x > 222 or viewport_point.y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 below is because our x/y is 0-indexed and proto wants 1
            var buf = [_]u8{ '\x1b', '[', 'M', 0, 0, 0 };
            buf[3] = 32 + button_code;
            buf[4] = 32 + @intCast(u8, viewport_point.x) + 1;
            buf[5] = 32 + @intCast(u8, viewport_point.y) + 1;
            try self.queueWrite(&buf);
        },

        .utf8 => {
            // Maximum of 12 because at most we have 2 fully UTF-8 encoded chars
            var buf: [12]u8 = undefined;
            buf[0] = '\x1b';
            buf[1] = '[';
            buf[2] = 'M';

            // The button code will always fit in a single u8
            buf[3] = 32 + button_code;

            // UTF-8 encode the x/y
            var i: usize = 4;
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.x + 1), buf[i..]);
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.y + 1), buf[i..]);

            try self.queueWrite(buf[0..i]);
        },

        .sgr => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var buf: [32]u8 = undefined;
            const resp = try std.fmt.bufPrint(&buf, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
                final,
            });

            try self.queueWrite(resp);
        },

        .urxvt => {
            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var buf: [32]u8 = undefined;
            const resp = try std.fmt.bufPrint(&buf, "\x1B[{d};{d};{d}M", .{
                32 + button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
            });

            try self.queueWrite(resp);
        },

        .sgr_pixels => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var buf: [32]u8 = undefined;
            const resp = try std.fmt.bufPrint(&buf, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                pos.xpos,
                pos.ypos,
                final,
            });

            try self.queueWrite(resp);
        },
    }
}

fn mouseButtonCallback(
    window: glfw.Window,
    glfw_button: glfw.MouseButton,
    glfw_action: glfw.Action,
    mods: glfw.Mods,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If our dev mode window is visible then we always schedule a render on
    // cursor move because the cursor might touch our windows.
    if (DevMode.enabled and DevMode.instance.visible) {
        win.render_timer.schedule() catch |err|
            log.err("error scheduling render timer in cursorPosCallback err={}", .{err});
    }

    // Convert glfw button to input button
    const button: input.MouseButton = switch (glfw_button) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .four => .four,
        .five => .five,
        .six => .six,
        .seven => .seven,
        .eight => .eight,
    };
    const action: input.MouseButtonState = switch (glfw_action) {
        .press => .press,
        .release => .release,
        else => unreachable,
    };

    // Always record our latest mouse state
    win.mouse.click_state[@enumToInt(button)] = action;
    win.mouse.mods = @bitCast(input.Mods, mods);

    // Report mouse events if enabled
    if (win.terminal.modes.mouse_event != .none) {
        const pos = window.getCursorPos() catch |err| {
            log.err("error reading cursor position: {}", .{err});
            return;
        };

        const report_action: MouseReportAction = switch (action) {
            .press => .press,
            .release => .release,
        };

        win.mouseReport(
            button,
            report_action,
            win.mouse.mods,
            pos,
        ) catch |err| {
            log.err("error reporting mouse event: {}", .{err});
            return;
        };
    }

    // For left button clicks we always record some information for
    // selection/highlighting purposes.
    if (button == .left and action == .press) {
        const pos = win.cursorPosToPixels(window.getCursorPos() catch |err| {
            log.err("error reading cursor position: {}", .{err});
            return;
        });

        // Store it
        const point = win.posToViewport(pos.xpos, pos.ypos);
        win.mouse.left_click_point = point.toScreen(&win.terminal.screen);
        win.mouse.left_click_xpos = pos.xpos;
        win.mouse.left_click_ypos = pos.ypos;

        // Selection is always cleared
        if (win.terminal.selection != null) {
            win.terminal.selection = null;
            win.render_timer.schedule() catch |err|
                log.err("error scheduling render in mouseButtinCallback err={}", .{err});
        }
    }
}

fn cursorPosCallback(
    window: glfw.Window,
    unscaled_xpos: f64,
    unscaled_ypos: f64,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If our dev mode window is visible then we always schedule a render on
    // cursor move because the cursor might touch our windows.
    if (DevMode.enabled and DevMode.instance.visible) {
        win.render_timer.schedule() catch |err|
            log.err("error scheduling render timer in cursorPosCallback err={}", .{err});
    }

    // Do a mouse report
    if (win.terminal.modes.mouse_event != .none) {
        // We use the first mouse button we find pressed in order to report
        // since the spec (afaict) does not say...
        const button: ?input.MouseButton = button: for (win.mouse.click_state) |state, i| {
            if (state == .press)
                break :button @intToEnum(input.MouseButton, i);
        } else null;

        win.mouseReport(button, .motion, win.mouse.mods, .{
            .xpos = unscaled_xpos,
            .ypos = unscaled_ypos,
        }) catch |err| {
            log.err("error reporting mouse event: {}", .{err});
            return;
        };

        // If we're doing mouse motion tracking, we do not support text
        // selection.
        return;
    }

    // If the cursor isn't clicked currently, it doesn't matter
    if (win.mouse.click_state[@enumToInt(input.MouseButton.left)] != .press) return;

    // All roads lead to requiring a re-render at this pont.
    win.render_timer.schedule() catch |err|
        log.err("error scheduling render timer in cursorPosCallback err={}", .{err});

    // Convert to pixels from screen coords
    const pos = win.cursorPosToPixels(.{ .xpos = unscaled_xpos, .ypos = unscaled_ypos });
    const xpos = pos.xpos;
    const ypos = pos.ypos;

    // Convert to points
    const viewport_point = win.posToViewport(xpos, ypos);
    const screen_point = viewport_point.toScreen(&win.terminal.screen);

    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    if (win.terminal.selection) |sel| {
        const reset: bool = if (sel.end.before(sel.start))
            sel.start.before(screen_point)
        else
            screen_point.before(sel.start);

        if (reset) win.terminal.selection = null;
    }

    // Our logic for determing if the starting cell is selected:
    //
    //   - The "xboundary" is 60% the width of a cell from the left. We choose
    //     60% somewhat arbitrarily based on feeling.
    //   - If we started our click left of xboundary, backwards selections
    //     can NEVER select the current char.
    //   - If we started our click right of xboundary, backwards selections
    //     ALWAYS selected the current char, but we must move the cursor
    //     left of the xboundary.
    //   - Inverted logic for forwards selections.
    //

    // the boundary point at which we consider selection or non-selection
    const cell_xboundary = win.grid.cell_size.width * 0.6;

    // first xpos of the clicked cell
    const cell_xstart = @intToFloat(f32, win.mouse.left_click_point.x) * win.grid.cell_size.width;
    const cell_start_xpos = win.mouse.left_click_xpos - cell_xstart;

    // If this is the same cell, then we only start the selection if weve
    // moved past the boundary point the opposite direction from where we
    // started.
    if (std.meta.eql(screen_point, win.mouse.left_click_point)) {
        const cell_xpos = xpos - cell_xstart;
        const selected: bool = if (cell_start_xpos < cell_xboundary)
            cell_xpos >= cell_xboundary
        else
            cell_xpos < cell_xboundary;

        win.terminal.selection = if (selected) .{
            .start = screen_point,
            .end = screen_point,
        } else null;

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (win.terminal.selection == null) {
        //   - If we're moving to a point before the start, then we select
        //     the starting cell if we started after the boundary, else
        //     we start selection of the prior cell.
        //   - Inverse logic for a point after the start.
        const click_point = win.mouse.left_click_point;
        const start: terminal.point.ScreenPoint = if (screen_point.before(click_point)) start: {
            if (win.mouse.left_click_xpos > cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x > 0) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x - 1,
                } else terminal.point.ScreenPoint{
                    .x = win.terminal.screen.cols - 1,
                    .y = click_point.y -| 1,
                };
            }
        } else start: {
            if (win.mouse.left_click_xpos < cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x < win.terminal.screen.cols - 1) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x + 1,
                } else terminal.point.ScreenPoint{
                    .y = click_point.y + 1,
                    .x = 0,
                };
            }
        };

        win.terminal.selection = .{ .start = start, .end = screen_point };
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(win.terminal.selection != null);
    win.terminal.selection.?.end = screen_point;
}

fn posToViewport(self: Window, xpos: f64, ypos: f64) terminal.point.Viewport {
    // xpos and ypos can be negative if while dragging, the user moves the
    // mouse off the window. Likewise, they can be larger than our window
    // width if the user drags out of the window positively.
    return .{
        .x = if (xpos < 0) 0 else x: {
            // Our cell is the mouse divided by cell width
            const cell_width = @floatCast(f64, self.grid.cell_size.width);
            const x = @floatToInt(usize, xpos / cell_width);

            // Can be off the screen if the user drags it out, so max
            // it out on our available columns
            break :x @minimum(x, self.terminal.cols - 1);
        },

        .y = if (ypos < 0) 0 else y: {
            const cell_height = @floatCast(f64, self.grid.cell_size.height);
            const y = @floatToInt(usize, ypos / cell_height);
            break :y @minimum(y, self.terminal.rows - 1);
        },
    };
}

fn cursorTimerCallback(t: *libuv.Timer) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = t.getData(Window) orelse return;

    // If the cursor is currently invisible, then we do nothing. Ideally
    // in this state the timer would be cancelled but no big deal.
    if (!win.terminal_cursor.visible) return;

    // Swap blink state and schedule a render
    win.terminal_cursor.blink = !win.terminal_cursor.blink;
    win.render_timer.schedule() catch unreachable;
}

fn ttyReadAlloc(t: *libuv.Tty, size: usize) ?[]u8 {
    const tracy = trace(@src());
    defer tracy.end();

    const win = t.getData(Window) orelse return null;
    const alloc = win.alloc_io_arena.allocator();
    return alloc.alloc(u8, size) catch null;
}

fn ttyRead(t: *libuv.Tty, n: isize, buf: []const u8) void {
    const tracy = trace(@src());
    tracy.color(0xEAEA7F); // yellow-ish
    defer tracy.end();

    const win = t.getData(Window).?;
    defer {
        const alloc = win.alloc_io_arena.allocator();
        alloc.free(buf);
    }

    // log.info("DATA: {d}", .{n});
    // log.info("DATA: {any}", .{buf[0..@intCast(usize, n)]});

    // First check for errors in the case n is less than 0.
    libuv.convertError(@intCast(i32, n)) catch |err| {
        switch (err) {
            // ignore EOF because it should end the process.
            libuv.Error.EOF => {},
            else => log.err("read error: {}", .{err}),
        }

        return;
    };

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible.
    win.terminal_cursor.blink = false;
    if (win.terminal_cursor.timer.isActive() catch false) {
        _ = win.terminal_cursor.timer.again() catch null;
    }

    // Schedule a render
    win.render_timer.schedule() catch unreachable;

    // Process the terminal data. This is an extremely hot part of the
    // terminal emulator, so we do some abstraction leakage to avoid
    // function calls and unnecessary logic.
    //
    // The ground state is the only state that we can see and print/execute
    // ASCII, so we only execute this hot path if we're already in the ground
    // state.
    //
    // Empirically, this alone improved throughput of large text output by ~20%.
    var i: usize = 0;
    const end = @intCast(usize, n);
    if (win.terminal_stream.parser.state == .ground and false) {
        for (buf[i..end]) |c| {
            switch (terminal.parse_table.table[c][@enumToInt(terminal.Parser.State.ground)].action) {
                // Print, call directly.
                .print => win.print(@intCast(u21, c)) catch |err|
                    log.err("error processing terminal data: {}", .{err}),

                // C0 execute, let our stream handle this one but otherwise
                // continue since we're guaranteed to be back in ground.
                .execute => win.terminal_stream.execute(c) catch |err|
                    log.err("error processing terminal data: {}", .{err}),

                // Otherwise, break out and go the slow path until we're
                // back in ground. There is a slight optimization here where
                // could try to find the next transition to ground but when
                // I implemented that it didn't materially change performance.
                else => break,
            }

            i += 1;
        }
    }

    if (i < end) {
        win.terminal_stream.nextSlice(buf[i..end]) catch |err|
            log.err("error processing terminal data: {}", .{err});
    }
}

fn ttyWrite(req: *libuv.WriteReq, status: i32) void {
    const tracy = trace(@src());
    defer tracy.end();

    const tty = req.handle(libuv.Tty).?;
    const win = tty.getData(Window).?;
    win.write_req_pool.put();
    win.write_buf_pool.put();

    libuv.convertError(status) catch |err|
        log.err("write error: {}", .{err});

    //log.info("WROTE: {d}", .{status});
}

fn renderTimerCallback(t: *libuv.Timer) void {
    const tracy = trace(@src());
    tracy.color(0x006E7F); // blue-ish
    defer tracy.end();

    const win = t.getData(Window).?;

    // Setup our cursor settings
    if (win.focused) {
        win.grid.cursor_visible = win.terminal_cursor.visible and !win.terminal_cursor.blink;
        win.grid.cursor_style = Grid.CursorStyle.fromTerminal(win.terminal_cursor.style) orelse .box;
    } else {
        win.grid.cursor_visible = true;
        win.grid.cursor_style = .box_hollow;
    }

    // Calculate foreground and background colors
    const bg = win.grid.background;
    const fg = win.grid.foreground;
    defer {
        win.grid.background = bg;
        win.grid.foreground = fg;
    }
    if (win.terminal.modes.reverse_colors) {
        win.grid.background = fg;
        win.grid.foreground = bg;
    }

    // Set our background
    const gl_bg: struct {
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    } = if (win.terminal.modes.reverse_colors) .{
        .r = @intToFloat(f32, fg.r) / 255,
        .g = @intToFloat(f32, fg.g) / 255,
        .b = @intToFloat(f32, fg.b) / 255,
        .a = 1.0,
    } else .{
        .r = win.bg_r,
        .g = win.bg_g,
        .b = win.bg_b,
        .a = win.bg_a,
    };
    gl.clearColor(gl_bg.r, gl_bg.g, gl_bg.b, gl_bg.a);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);

    // For now, rebuild all cells
    win.grid.rebuildCells(&win.terminal) catch |err|
        log.err("error calling rebuildCells in render timer err={}", .{err});

    // Finalize the cells prior to render
    win.grid.finalizeCells(&win.terminal) catch |err|
        log.err("error calling updateCells in render timer err={}", .{err});

    // Render the grid
    win.grid.render() catch |err| {
        log.err("error rendering grid: {}", .{err});
        return;
    };

    if (DevMode.enabled and DevMode.instance.visible) {
        DevMode.instance.update();
        const data = DevMode.instance.render() catch unreachable;
        imgui.ImplOpenGL3.renderDrawData(data);
    }

    // Swap
    win.window.swapBuffers() catch |err| {
        log.err("error swapping buffers: {}", .{err});
        return;
    };

    // Record our run
    win.render_timer.tick();
}

//-------------------------------------------------------------------
// Stream Callbacks

pub fn print(self: *Window, c: u21) !void {
    try self.terminal.print(c);
}

pub fn bell(self: Window) !void {
    _ = self;
    log.info("BELL", .{});
}

pub fn backspace(self: *Window) !void {
    self.terminal.backspace();
}

pub fn horizontalTab(self: *Window) !void {
    try self.terminal.horizontalTab();
}

pub fn linefeed(self: *Window) !void {
    // Small optimization: call index instead of linefeed because they're
    // identical and this avoids one layer of function call overhead.
    try self.terminal.index();
}

pub fn carriageReturn(self: *Window) !void {
    self.terminal.carriageReturn();
}

pub fn setCursorLeft(self: *Window, amount: u16) !void {
    self.terminal.cursorLeft(amount);
}

pub fn setCursorRight(self: *Window, amount: u16) !void {
    self.terminal.cursorRight(amount);
}

pub fn setCursorDown(self: *Window, amount: u16) !void {
    self.terminal.cursorDown(amount);
}

pub fn setCursorUp(self: *Window, amount: u16) !void {
    self.terminal.cursorUp(amount);
}

pub fn setCursorCol(self: *Window, col: u16) !void {
    self.terminal.setCursorColAbsolute(col);
}

pub fn setCursorRow(self: *Window, row: u16) !void {
    if (self.terminal.modes.origin) {
        // TODO
        log.err("setCursorRow: implement origin mode", .{});
        unreachable;
    }

    self.terminal.setCursorPos(row, self.terminal.screen.cursor.x + 1);
}

pub fn setCursorPos(self: *Window, row: u16, col: u16) !void {
    self.terminal.setCursorPos(row, col);
}

pub fn eraseDisplay(self: *Window, mode: terminal.EraseDisplay) !void {
    if (mode == .complete) {
        // Whenever we erase the full display, scroll to bottom.
        try self.terminal.scrollViewport(.{ .bottom = {} });
        try self.render_timer.schedule();
    }

    self.terminal.eraseDisplay(mode);
}

pub fn eraseLine(self: *Window, mode: terminal.EraseLine) !void {
    self.terminal.eraseLine(mode);
}

pub fn deleteChars(self: *Window, count: usize) !void {
    try self.terminal.deleteChars(count);
}

pub fn eraseChars(self: *Window, count: usize) !void {
    self.terminal.eraseChars(count);
}

pub fn insertLines(self: *Window, count: usize) !void {
    try self.terminal.insertLines(count);
}

pub fn insertBlanks(self: *Window, count: usize) !void {
    self.terminal.insertBlanks(count);
}

pub fn deleteLines(self: *Window, count: usize) !void {
    try self.terminal.deleteLines(count);
}

pub fn reverseIndex(self: *Window) !void {
    try self.terminal.reverseIndex();
}

pub fn index(self: *Window) !void {
    try self.terminal.index();
}

pub fn nextLine(self: *Window) !void {
    self.terminal.carriageReturn();
    try self.terminal.index();
}

pub fn setTopAndBottomMargin(self: *Window, top: u16, bot: u16) !void {
    self.terminal.setScrollingRegion(top, bot);
}

pub fn setMode(self: *Window, mode: terminal.Mode, enabled: bool) !void {
    switch (mode) {
        .reverse_colors => {
            self.terminal.modes.reverse_colors = enabled;

            // Schedule a render since we changed colors
            try self.render_timer.schedule();
        },

        .origin => {
            self.terminal.modes.origin = enabled;
            self.terminal.setCursorPos(1, 1);
        },

        .autowrap => {
            self.terminal.modes.autowrap = enabled;
        },

        .cursor_visible => {
            self.terminal_cursor.visible = enabled;
        },

        .alt_screen_save_cursor_clear_enter => {
            const opts: terminal.Terminal.AlternateScreenOptions = .{
                .cursor_save = true,
                .clear_on_enter = true,
            };

            if (enabled)
                self.terminal.alternateScreen(opts)
            else
                self.terminal.primaryScreen(opts);

            // Schedule a render since we changed screens
            try self.render_timer.schedule();
        },

        .bracketed_paste => self.bracketed_paste = true,

        .enable_mode_3 => {
            // Disable deccolm
            self.terminal.setDeccolmSupported(enabled);

            // Force resize back to the window size
            self.terminal.resize(self.alloc, self.grid.size.columns, self.grid.size.rows) catch |err|
                log.err("error updating terminal size: {}", .{err});
        },

        .@"132_column" => try self.terminal.deccolm(
            self.alloc,
            if (enabled) .@"132_cols" else .@"80_cols",
        ),

        .mouse_event_x10 => self.terminal.modes.mouse_event = if (enabled) .x10 else .none,
        .mouse_event_normal => self.terminal.modes.mouse_event = if (enabled) .normal else .none,
        .mouse_event_button => self.terminal.modes.mouse_event = if (enabled) .button else .none,
        .mouse_event_any => self.terminal.modes.mouse_event = if (enabled) .any else .none,

        .mouse_format_utf8 => self.terminal.modes.mouse_format = if (enabled) .utf8 else .x10,
        .mouse_format_sgr => self.terminal.modes.mouse_format = if (enabled) .sgr else .x10,
        .mouse_format_urxvt => self.terminal.modes.mouse_format = if (enabled) .urxvt else .x10,
        .mouse_format_sgr_pixels => self.terminal.modes.mouse_format = if (enabled) .sgr_pixels else .x10,

        else => if (enabled) log.warn("unimplemented mode: {}", .{mode}),
    }
}

pub fn setAttribute(self: *Window, attr: terminal.Attribute) !void {
    switch (attr) {
        .unknown => |unk| log.warn("unimplemented or unknown attribute: {any}", .{unk}),

        else => self.terminal.setAttribute(attr) catch |err|
            log.warn("error setting attribute {}: {}", .{ attr, err }),
    }
}

pub fn deviceAttributes(
    self: *Window,
    req: terminal.DeviceAttributeReq,
    params: []const u16,
) !void {
    _ = params;

    switch (req) {
        // VT220
        .primary => self.queueWrite("\x1B[?62;c") catch |err|
            log.warn("error queueing device attr response: {}", .{err}),
        else => log.warn("unimplemented device attributes req: {}", .{req}),
    }
}

pub fn deviceStatusReport(
    self: *Window,
    req: terminal.DeviceStatusReq,
) !void {
    switch (req) {
        .operating_status => self.queueWrite("\x1B[0n") catch |err|
            log.warn("error queueing device attr response: {}", .{err}),

        .cursor_position => {
            const pos: struct {
                x: usize,
                y: usize,
            } = if (self.terminal.modes.origin) .{
                // TODO: what do we do if cursor is outside scrolling region?
                .x = self.terminal.screen.cursor.x,
                .y = self.terminal.screen.cursor.y -| self.terminal.scrolling_region.top,
            } else .{
                .x = self.terminal.screen.cursor.x,
                .y = self.terminal.screen.cursor.y,
            };

            // Response always is at least 4 chars, so this leaves the
            // remainder for the row/column as base-10 numbers. This
            // will support a very large terminal.
            var buf: [32]u8 = undefined;
            const resp = try std.fmt.bufPrint(&buf, "\x1B[{};{}R", .{
                pos.y + 1,
                pos.x + 1,
            });

            try self.queueWrite(resp);
        },

        else => log.warn("unimplemented device status req: {}", .{req}),
    }
}

pub fn setCursorStyle(
    self: *Window,
    style: terminal.CursorStyle,
) !void {
    self.terminal_cursor.style = style;
}

pub fn decaln(self: *Window) !void {
    try self.terminal.decaln();
}

pub fn tabClear(self: *Window, cmd: terminal.TabClear) !void {
    self.terminal.tabClear(cmd);
}

pub fn tabSet(self: *Window) !void {
    self.terminal.tabSet();
}

pub fn saveCursor(self: *Window) !void {
    self.terminal.saveCursor();
}

pub fn restoreCursor(self: *Window) !void {
    self.terminal.restoreCursor();
}

pub fn enquiry(self: *Window) !void {
    try self.queueWrite("");
}

pub fn scrollDown(self: *Window, count: usize) !void {
    try self.terminal.scrollDown(count);
}

pub fn scrollUp(self: *Window, count: usize) !void {
    try self.terminal.scrollUp(count);
}

pub fn setActiveStatusDisplay(
    self: *Window,
    req: terminal.StatusDisplay,
) !void {
    self.terminal.status_display = req;
}

pub fn configureCharset(
    self: *Window,
    slot: terminal.CharsetSlot,
    set: terminal.Charset,
) !void {
    self.terminal.configureCharset(slot, set);
}

pub fn invokeCharset(
    self: *Window,
    active: terminal.CharsetActiveSlot,
    slot: terminal.CharsetSlot,
    single: bool,
) !void {
    self.terminal.invokeCharset(active, slot, single);
}

const face_ttf = @embedFile("font/res/FiraCode-Regular.ttf");
const face_bold_ttf = @embedFile("font/res/FiraCode-Bold.ttf");
const face_emoji_ttf = @embedFile("font/res/NotoColorEmoji.ttf");
const face_emoji_text_ttf = @embedFile("font/res/NotoEmoji-Regular.ttf");
