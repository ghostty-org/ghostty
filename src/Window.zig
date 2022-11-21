//! Window represents a single OS window.
//!
//! NOTE(multi-window): This may be premature, but this abstraction is here
//! to pave the way One Day(tm) for multi-window support. At the time of
//! writing, we support exactly one window.
const Window = @This();

// TODO: eventually, I want to extract Window.zig into the "window" package
// so we can also have alternate implementations (i.e. not glfw).
const message = @import("window/message.zig");
pub const Mailbox = message.Mailbox;
pub const Message = message.Message;

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const objc = @import("objc");
const glfw = @import("glfw");
const imgui = @import("imgui");
const Pty = @import("Pty.zig");
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const trace = @import("tracy").trace;
const terminal = @import("terminal/main.zig");
const Config = @import("config.zig").Config;
const input = @import("input.zig");
const DevMode = @import("DevMode.zig");
const App = @import("App.zig");
const internal_os = @import("os/main.zig");

// Get native API access on certain platforms so we can do more customization.
const glfwNative = glfw.Native(.{
    .cocoa = builtin.target.isDarwin(),
});

const log = std.log.scoped(.window);

// The renderer implementation to use.
const Renderer = renderer.Renderer;

/// Allocator
alloc: Allocator,

/// The app that this window is a part of.
app: *App,

/// The font structures
font_lib: font.Library,
font_group: *font.GroupCache,
font_size: font.face.DesiredSize,

/// The glfw window handle.
window: glfw.Window,

/// The glfw mouse cursor handle.
cursor: glfw.Cursor,

/// Imgui context
imgui_ctx: if (DevMode.enabled) *imgui.Context else void,

/// The renderer for this window.
renderer: Renderer,

/// The render state
renderer_state: renderer.State,

/// The renderer thread manager
renderer_thread: renderer.Thread,

/// The actual thread
renderer_thr: std.Thread,

/// Mouse state.
mouse: Mouse,

/// The terminal IO handler.
io: termio.Impl,
io_thread: termio.Thread,
io_thr: std.Thread,

/// All the cached sizes since we need them at various times.
screen_size: renderer.ScreenSize,
grid_size: renderer.GridSize,
cell_size: renderer.CellSize,

/// Explicit padding due to configuration
padding: renderer.Padding,

/// The app configuration
config: *const Config,

/// Set to true for a single GLFW key/char callback cycle to cause the
/// char callback to ignore. GLFW seems to always do key followed by char
/// callbacks so we abuse that here. This is to solve an issue where commands
/// like such as "control-v" will write a "v" even if they're intercepted.
ignore_char: bool = false,

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
pub fn create(alloc: Allocator, app: *App, config: *const Config) !*Window {
    var self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    // Create our window
    const window = try glfw.Window.create(640, 480, "ghostty", null, null, Renderer.windowHints());
    errdefer window.destroy();
    try Renderer.windowInit(window);

    // On Mac, enable tabbing
    if (comptime builtin.target.isDarwin()) {
        const NSWindowTabbingMode = enum(usize) { automatic = 0, preferred = 1, disallowed = 2 };
        const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(window).?);

        // Tabbing mode enables tabbing at all
        nswindow.setProperty("tabbingMode", NSWindowTabbingMode.automatic);

        // All windows within a tab bar must have a matching tabbing ID.
        // The app sets this up for us.
        nswindow.setProperty("tabbingIdentifier", app.darwin.tabbing_id);
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

    // The font size we desire along with the DPI determiend for the window
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @floatToInt(u16, x_dpi),
        .ydpi = @floatToInt(u16, y_dpi),
    };

    // Find all the fonts for this window
    //
    // Future: we can share the font group amongst all windows to save
    // some new window init time and some memory. This will require making
    // thread-safe changes to font structs.
    var font_lib = try font.Library.init();
    errdefer font_lib.deinit();
    var font_group = try alloc.create(font.GroupCache);
    errdefer alloc.destroy(font_group);
    font_group.* = try font.GroupCache.init(alloc, group: {
        var group = try font.Group.init(alloc, font_lib, font_size);
        errdefer group.deinit();

        // Search for fonts
        if (font.Discover != void) {
            var disco = font.Discover.init();
            group.discover = disco;

            if (config.@"font-family") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font regular: {s}", .{try face.name()});
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
                    log.info("font bold: {s}", .{try face.name()});
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
                    log.info("font italic: {s}", .{try face.name()});
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
                    log.info("font bold+italic: {s}", .{try face.name()});
                    try group.addFace(alloc, .bold_italic, face);
                }
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

        break :group group;
    });
    errdefer font_group.deinit(alloc);

    // Pre-calculate our initial cell size ourselves.
    const cell_size = try renderer.CellSize.init(alloc, font_group);

    // Convert our padding from points to pixels
    const padding_x = (@intToFloat(f32, config.@"window-padding-x") * x_dpi) / 72;
    const padding_y = (@intToFloat(f32, config.@"window-padding-y") * y_dpi) / 72;
    const padding: renderer.Padding = .{
        .top = padding_y,
        .bottom = padding_y,
        .right = padding_x,
        .left = padding_x,
    };

    // Create our terminal grid with the initial window size
    var renderer_impl = try Renderer.init(alloc, .{
        .config = config,
        .font_group = font_group,
        .padding = .{
            .explicit = padding,
            .balance = config.@"window-padding-balance",
        },
        .window_mailbox = .{ .window = self, .app = app.mailbox },
    });
    errdefer renderer_impl.deinit();

    // Calculate our grid size based on known dimensions.
    const window_size = try window.getSize();
    const screen_size: renderer.ScreenSize = .{
        .width = window_size.width,
        .height = window_size.height,
    };
    const grid_size = renderer.GridSize.init(
        screen_size.subPadding(padding),
        cell_size,
    );

    // Set a minimum size that is cols=10 h=4. This matches Mac's Terminal.app
    // but is otherwise somewhat arbitrary.
    try window.setSizeLimits(.{
        .width = @floatToInt(u32, cell_size.width * 10),
        .height = @floatToInt(u32, cell_size.height * 4),
    }, .{ .width = null, .height = null });

    // Create the cursor
    const cursor = try glfw.Cursor.createStandard(.ibeam);
    errdefer cursor.destroy();
    if ((comptime !builtin.target.isDarwin()) or internal_os.macosVersionAtLeast(13, 0, 0)) {
        // We only set our cursor if we're NOT on Mac, or if we are then the
        // macOS version is >= 13 (Ventura). On prior versions, glfw crashes
        // since we use a tab group.
        try window.setCursor(cursor);
    }

    // The mutex used to protect our renderer state.
    var mutex = try alloc.create(std.Thread.Mutex);
    mutex.* = .{};
    errdefer alloc.destroy(mutex);

    // Create the renderer thread
    var render_thread = try renderer.Thread.init(
        alloc,
        window,
        &self.renderer,
        &self.renderer_state,
    );
    errdefer render_thread.deinit();

    // Start our IO implementation
    var io = try termio.Impl.init(alloc, .{
        .grid_size = grid_size,
        .screen_size = screen_size,
        .config = config,
        .renderer_state = &self.renderer_state,
        .renderer_wakeup = render_thread.wakeup,
        .renderer_mailbox = render_thread.mailbox,
        .window_mailbox = .{ .window = self, .app = app.mailbox },
    });
    errdefer io.deinit();

    // Create the IO thread
    var io_thread = try termio.Thread.init(alloc, &self.io);
    errdefer io_thread.deinit();

    // True if this window is hosting devmode. We only host devmode on
    // the first window since imgui is not threadsafe. We need to do some
    // work to make DevMode work with multiple threads.
    const host_devmode = DevMode.enabled and DevMode.instance.window == null;

    self.* = .{
        .alloc = alloc,
        .app = app,
        .font_lib = font_lib,
        .font_group = font_group,
        .font_size = font_size,
        .window = window,
        .cursor = cursor,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .cursor = .{
                .style = .blinking_block,
                .visible = true,
            },
            .terminal = &self.io.terminal,
            .devmode = if (!host_devmode) null else &DevMode.instance,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .io = io,
        .io_thread = io_thread,
        .io_thr = undefined,
        .screen_size = screen_size,
        .grid_size = grid_size,
        .cell_size = cell_size,
        .padding = padding,
        .config = config,

        .imgui_ctx = if (!DevMode.enabled) {} else try imgui.Context.create(),
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
    if (DevMode.enabled and DevMode.instance.window == null) {
        const dev_io = try imgui.IO.get();
        dev_io.cval().IniFilename = "ghostty_dev_mode.ini";

        // Add our built-in fonts so it looks slightly better
        const dev_atlas = @ptrCast(*imgui.FontAtlas, dev_io.cval().Fonts);
        dev_atlas.addFontFromMemoryTTF(
            face_ttf,
            @intToFloat(f32, font_size.pixels()),
        );

        // Default dark style
        const style = try imgui.Style.get();
        style.colorsDark();

        // Add our window to the instance if it isn't set.
        DevMode.instance.window = self;

        // Let our renderer setup
        try renderer_impl.initDevMode(window);
    }

    // Give the renderer one more opportunity to finalize any window
    // setup on the main thread prior to spinning up the rendering thread.
    try renderer_impl.finalizeWindowInit(window);

    // Start our renderer thread
    self.renderer_thr = try std.Thread.spawn(
        .{},
        renderer.Thread.threadMain,
        .{&self.renderer_thread},
    );
    self.renderer_thr.setName("renderer") catch {};

    // Start our IO thread
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{&self.io_thread},
    );
    self.io_thr.setName("io") catch {};

    return self;
}

pub fn destroy(self: *Window) void {
    {
        // Stop rendering thread
        self.renderer_thread.stop.send() catch |err|
            log.err("error notifying renderer thread to stop, may stall err={}", .{err});
        self.renderer_thr.join();

        // We need to become the active rendering thread again
        self.renderer.threadEnter(self.window) catch unreachable;
        self.renderer_thread.deinit();

        // If we are devmode-owning, clean that up.
        if (DevMode.enabled and DevMode.instance.window == self) {
            // Let our renderer clean up
            self.renderer.deinitDevMode();

            // Clear the window
            DevMode.instance.window = null;

            // Uninitialize imgui
            self.imgui_ctx.destroy();
        }

        // Deinit our renderer
        self.renderer.deinit();
    }

    {
        // Stop our IO thread
        self.io_thread.stop.send() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        self.io_thr.join();
        self.io_thread.deinit();

        // Deinitialize our terminal IO
        self.io.deinit();
    }

    var tabgroup_opt: if (builtin.target.isDarwin()) ?objc.Object else void = undefined;
    if (comptime builtin.target.isDarwin()) {
        const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(self.window).?);
        const tabgroup = nswindow.getProperty(objc.Object, "tabGroup");

        // On macOS versions prior to Ventura, we lose window focus on tab close
        // for some reason. We manually fix this by keeping track of the tab
        // group and just selecting the next window.
        if (internal_os.macosVersionAtLeast(13, 0, 0))
            tabgroup_opt = null
        else
            tabgroup_opt = tabgroup;

        const windows = tabgroup.getProperty(objc.Object, "windows");
        switch (windows.getProperty(usize, "count")) {
            // If we're going down to one window our tab bar is going to be
            // destroyed so unset it so that the later logic doesn't try to
            // use it.
            1 => tabgroup_opt = null,

            // If our tab bar is visible and we are going down to 1 window,
            // hide the tab bar. The check is "2" because our current window
            // is still present.
            2 => if (tabgroup.getProperty(bool, "tabBarVisible")) {
                nswindow.msgSend(void, objc.sel("toggleTabBar:"), .{nswindow.value});
            },

            else => {},
        }
    }

    self.window.destroy();

    // If we have a tabgroup set, we want to manually focus the next window.
    // We should NOT have to do this usually, see the comments above.
    if (comptime builtin.target.isDarwin()) {
        if (tabgroup_opt) |tabgroup| {
            const selected = tabgroup.getProperty(objc.Object, "selectedWindow");
            selected.msgSend(void, objc.sel("makeKeyWindow"), .{});
        }
    }

    // We can destroy the cursor right away. glfw will just revert any
    // windows using it to the default.
    self.cursor.destroy();

    self.font_group.deinit(self.alloc);
    self.font_lib.deinit();
    self.alloc.destroy(self.font_group);

    self.alloc.destroy(self.renderer_state.mutex);

    self.alloc.destroy(self);
}

pub fn shouldClose(self: Window) bool {
    return self.window.shouldClose();
}

/// Add a window to the tab group of this window.
pub fn addWindow(self: Window, other: *Window) void {
    assert(builtin.target.isDarwin());

    const NSWindowOrderingMode = enum(isize) { below = -1, out = 0, above = 1 };
    const nswindow = objc.Object.fromId(glfwNative.getCocoaWindow(self.window).?);
    nswindow.msgSend(void, objc.sel("addTabbedWindow:ordered:"), .{
        objc.Object.fromId(glfwNative.getCocoaWindow(other.window).?),
        NSWindowOrderingMode.above,
    });
}

/// Called from the app thread to handle mailbox messages to our specific
/// window.
pub fn handleMessage(self: *Window, msg: Message) !void {
    switch (msg) {
        .set_title => |*v| {
            // The ptrCast just gets sliceTo to return the proper type.
            // We know that our title should end in 0.
            const slice = std.mem.sliceTo(@ptrCast([*:0]const u8, v), 0);
            log.debug("changing title \"{s}\"", .{slice});
            try self.window.setTitle(slice.ptr);
        },

        .cell_size => |size| try self.setCellSize(size),

        .clipboard_read => |kind| try self.clipboardRead(kind),

        .clipboard_write => |req| switch (req) {
            .small => |v| try self.clipboardWrite(v.data[0..v.len]),
            .stable => |v| try self.clipboardWrite(v),
            .alloc => |v| {
                defer v.alloc.free(v.data);
                try self.clipboardWrite(v.data);
            },
        },
    }
}

fn clipboardRead(self: *const Window, kind: u8) !void {
    if (!self.config.@"clipboard-read") {
        log.info("application attempted to read clipboard, but 'clipboard-read' setting is off", .{});
        return;
    }

    const data = glfw.getClipboardString() catch |err| {
        log.warn("error reading clipboard: {}", .{err});
        return;
    };

    // Even if the clipboard data is empty we reply, since presumably
    // the client app is expecting a reply. We first allocate our buffer.
    // This must hold the base64 encoded data PLUS the OSC code surrounding it.
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    var buf = try self.alloc.alloc(u8, size + 9); // const for OSC
    defer self.alloc.free(buf);

    // Wrap our data with the OSC code
    const prefix = try std.fmt.bufPrint(buf, "\x1b]52;{c};", .{kind});
    assert(prefix.len == 7);
    buf[buf.len - 2] = '\x1b';
    buf[buf.len - 1] = '\\';

    // Do the base64 encoding
    const encoded = enc.encode(buf[prefix.len..], data);
    assert(encoded.len == size);

    _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
        self.alloc,
        buf,
    ), .{ .forever = {} });
    self.io_thread.wakeup.send() catch {};
}

fn clipboardWrite(self: *const Window, data: []const u8) !void {
    if (!self.config.@"clipboard-write") {
        log.info("application attempted to write clipboard, but 'clipboard-write' setting is off", .{});
        return;
    }

    const dec = std.base64.standard.Decoder;

    // Build buffer
    const size = try dec.calcSizeForSlice(data);
    var buf = try self.alloc.allocSentinel(u8, size, 0);
    defer self.alloc.free(buf);
    buf[buf.len] = 0;

    // Decode
    try dec.decode(buf, data);
    assert(buf[buf.len] == 0);

    glfw.setClipboardString(buf) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}

/// Change the cell size for the terminal grid. This can happen as
/// a result of changing the font size at runtime.
fn setCellSize(self: *Window, size: renderer.CellSize) !void {
    // Update our new cell size for future calcs
    self.cell_size = size;

    // Update our grid_size
    self.grid_size = renderer.GridSize.init(
        self.screen_size.subPadding(self.padding),
        self.cell_size,
    );

    // Notify the terminal
    _ = self.io_thread.mailbox.push(.{
        .resize = .{
            .grid_size = self.grid_size,
            .screen_size = self.screen_size,
            .padding = self.padding,
        },
    }, .{ .forever = {} });
    self.io_thread.wakeup.send() catch {};
}

/// Change the font size.
///
/// This can only be called from the main thread.
pub fn setFontSize(self: *Window, size: font.face.DesiredSize) void {
    // Update our font size so future changes work
    self.font_size = size;

    // Notify our render thread of the font size. This triggers everything else.
    _ = self.renderer_thread.mailbox.push(.{
        .font_size = size,
    }, .{ .forever = {} });

    // Schedule render which also drains our mailbox
    self.queueRender() catch unreachable;
}

/// This queues a render operation with the renderer thread. The render
/// isn't guaranteed to happen immediately but it will happen as soon as
/// practical.
fn queueRender(self: *const Window) !void {
    try self.renderer_thread.wakeup.send();
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

    const win = window.getUserPointer(Window) orelse return;

    // TODO: if our screen size didn't change, then we should avoid the
    // overhead of inter-thread communication

    // Save our screen size
    win.screen_size = .{
        .width = px_size.width,
        .height = px_size.height,
    };

    // Recalculate our grid size
    win.grid_size = renderer.GridSize.init(
        win.screen_size.subPadding(win.padding),
        win.cell_size,
    );
    if (win.grid_size.columns < 5 and (win.padding.left > 0 or win.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (win.grid_size.rows < 2 and (win.padding.top > 0 or win.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }

    // Mail the renderer
    _ = win.renderer_thread.mailbox.push(.{
        .screen_size = win.screen_size,
    }, .{ .forever = {} });
    win.queueRender() catch unreachable;

    // Mail the IO thread
    _ = win.io_thread.mailbox.push(.{
        .resize = .{
            .grid_size = win.grid_size,
            .screen_size = win.screen_size,
            .padding = win.padding,
        },
    }, .{ .forever = {} });
    win.io_thread.wakeup.send() catch {};
}

fn charCallback(window: glfw.Window, codepoint: u21) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // Dev Mode
    if (DevMode.enabled and DevMode.instance.visible) {
        // If the event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureKeyboard) {
                win.queueRender() catch |err|
                    log.err("error scheduling render timer err={}", .{err});
            }
        } else |_| {}
    }

    // Ignore if requested. See field docs for more information.
    if (win.ignore_char) {
        win.ignore_char = false;
        return;
    }

    // Critical area
    {
        win.renderer_state.mutex.lock();
        defer win.renderer_state.mutex.unlock();

        // Clear the selction if we have one.
        if (win.io.terminal.selection != null) {
            win.io.terminal.selection = null;
            win.queueRender() catch |err|
                log.err("error scheduling render in charCallback err={}", .{err});
        }

        // We want to scroll to the bottom
        // TODO: detect if we're at the bottom to avoid the render call here.
        win.io.terminal.scrollViewport(.{ .bottom = {} }) catch |err|
            log.err("error scrolling viewport err={}", .{err});
    }

    // Ask our IO thread to write the data
    var data: termio.Message.WriteReq.Small.Array = undefined;
    data[0] = @intCast(u8, codepoint);
    _ = win.io_thread.mailbox.push(.{
        .write_small = .{
            .data = data,
            .len = 1,
        },
    }, .{ .forever = {} });

    // After sending all our messages we have to notify our IO thread
    win.io_thread.wakeup.send() catch {};
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

    // Dev Mode
    if (DevMode.enabled and DevMode.instance.visible) {
        // If the event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureKeyboard) {
                win.queueRender() catch |err|
                    log.err("error scheduling render timer err={}", .{err});
            }
        } else |_| {}
    }

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
                .zero => .zero,
                .one => .one,
                .two => .three,
                .three => .four,
                .four => .four,
                .five => .five,
                .six => .six,
                .seven => .seven,
                .eight => .eight,
                .nine => .nine,
                .up => .up,
                .down => .down,
                .right => .right,
                .left => .left,
                .home => .home,
                .end => .end,
                .page_up => .page_up,
                .page_down => .page_down,
                .escape => .escape,
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
                .minus => .minus,
                .equal => .equal,
                else => .invalid,
            },
        };

        //log.warn("BINDING TRIGGER={}", .{trigger});
        if (win.config.keybind.set.get(trigger)) |binding_action| {
            //log.warn("BINDING ACTION={}", .{binding_action});

            switch (binding_action) {
                .unbind => unreachable,
                .ignore => {},

                .csi => |data| {
                    _ = win.io_thread.mailbox.push(.{
                        .write_stable = "\x1B[",
                    }, .{ .forever = {} });
                    _ = win.io_thread.mailbox.push(.{
                        .write_stable = data,
                    }, .{ .forever = {} });
                    win.io_thread.wakeup.send() catch {};
                },

                .copy_to_clipboard => {
                    // We can read from the renderer state without holding
                    // the lock because only we will write to this field.
                    if (win.io.terminal.selection) |sel| {
                        var buf = win.io.terminal.screen.selectionString(
                            win.alloc,
                            sel,
                        ) catch |err| {
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
                        const bracketed = bracketed: {
                            win.renderer_state.mutex.lock();
                            defer win.renderer_state.mutex.unlock();
                            break :bracketed win.io.terminal.modes.bracketed_paste;
                        };

                        if (bracketed) {
                            _ = win.io_thread.mailbox.push(.{
                                .write_stable = "\x1B[200~",
                            }, .{ .forever = {} });
                        }

                        _ = win.io_thread.mailbox.push(termio.Message.writeReq(
                            win.alloc,
                            data,
                        ) catch unreachable, .{ .forever = {} });

                        if (bracketed) {
                            _ = win.io_thread.mailbox.push(.{
                                .write_stable = "\x1B[201~",
                            }, .{ .forever = {} });
                        }

                        win.io_thread.wakeup.send() catch {};
                    }
                },

                .increase_font_size => |delta| {
                    log.debug("increase font size={}", .{delta});

                    var size = win.font_size;
                    size.points +|= delta;
                    win.setFontSize(size);
                },

                .decrease_font_size => |delta| {
                    log.debug("decrease font size={}", .{delta});

                    var size = win.font_size;
                    size.points = @max(1, size.points -| delta);
                    win.setFontSize(size);
                },

                .reset_font_size => {
                    log.debug("reset font size", .{});

                    var size = win.font_size;
                    size.points = win.config.@"font-size";
                    win.setFontSize(size);
                },

                .toggle_dev_mode => if (DevMode.enabled) {
                    DevMode.instance.visible = !DevMode.instance.visible;
                    win.queueRender() catch unreachable;
                } else log.warn("dev mode was not compiled into this binary", .{}),

                .new_window => {
                    _ = win.app.mailbox.push(.{
                        .new_window = .{
                            .font_size = if (win.config.@"window-inherit-font-size")
                                win.font_size
                            else
                                null,
                        },
                    }, .{ .instant = {} });
                    win.app.wakeup();
                },

                .new_tab => {
                    _ = win.app.mailbox.push(.{
                        .new_tab = .{
                            .parent = win,

                            .font_size = if (win.config.@"window-inherit-font-size")
                                win.font_size
                            else
                                null,
                        },
                    }, .{ .instant = {} });
                    win.app.wakeup();
                },

                .close_window => win.window.setShouldClose(true),

                .quit => {
                    _ = win.app.mailbox.push(.{
                        .quit = {},
                    }, .{ .instant = {} });
                    win.app.wakeup();
                },
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
            // Ask our IO thread to write the data
            var data: termio.Message.WriteReq.Small.Array = undefined;
            data[0] = @intCast(u8, char);
            _ = win.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = 1,
                },
            }, .{ .forever = {} });

            // After sending all our messages we have to notify our IO thread
            win.io_thread.wakeup.send() catch {};
        }
    }
}

fn focusCallback(window: glfw.Window, focused: bool) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // Notify our render thread of the new state
    _ = win.renderer_thread.mailbox.push(.{
        .focus = focused,
    }, .{ .forever = {} });

    // Schedule render which also drains our mailbox
    win.queueRender() catch unreachable;
}

fn refreshCallback(window: glfw.Window) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // The point of this callback is to schedule a render, so do that.
    win.queueRender() catch unreachable;
}

fn scrollCallback(window: glfw.Window, xoff: f64, yoff: f64) void {
    const tracy = trace(@src());
    defer tracy.end();

    const win = window.getUserPointer(Window) orelse return;

    // If our dev mode window is visible then we always schedule a render on
    // cursor move because the cursor might touch our windows.
    if (DevMode.enabled and DevMode.instance.visible) {
        win.queueRender() catch |err|
            log.err("error scheduling render timer err={}", .{err});

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
    }

    //log.info("SCROLL: {} {}", .{ xoff, yoff });
    _ = xoff;

    // Positive is up
    const sign: isize = if (yoff > 0) -1 else 1;
    const delta: isize = sign * @max(@divFloor(win.grid_size.rows, 15), 1);
    log.info("scroll: delta={}", .{delta});

    {
        win.renderer_state.mutex.lock();
        defer win.renderer_state.mutex.unlock();

        // Modify our viewport, this requires a lock since it affects rendering
        win.io.terminal.scrollViewport(.{ .delta = delta }) catch |err|
            log.err("error scrolling viewport err={}", .{err});

        // If we're scrolling up or down, then send a mouse event. This requires
        // a lock since we read terminal state.
        if (yoff != 0) {
            const pos = window.getCursorPos() catch |err| {
                log.err("error reading cursor position: {}", .{err});
                return;
            };

            win.mouseReport(if (yoff < 0) .five else .four, .press, win.mouse.mods, pos) catch |err| {
                log.err("error reporting mouse event: {}", .{err});
                return;
            };
        }
    }

    win.queueRender() catch unreachable;
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
    switch (self.io.terminal.modes.mouse_event) {
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

    // Record our new point
    self.mouse.event_point = viewport_point;

    // Get the code we'll actually write
    const button_code: u8 = code: {
        var acc: u8 = 0;

        // Determine our initial button value
        if (button == null) {
            // Null button means motion without a button pressed
            acc = 3;
        } else if (action == .release and self.io.terminal.modes.mouse_format != .sgr) {
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
        if (self.io.terminal.modes.mouse_event != .x10) {
            if (mods.shift) acc += 4;
            if (mods.super) acc += 8;
            if (mods.ctrl) acc += 16;
        }

        // Motion adds another bit
        if (action == .motion) acc += 32;

        break :code acc;
    };

    switch (self.io.terminal.modes.mouse_format) {
        .x10 => {
            if (viewport_point.x > 222 or viewport_point.y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 below is because our x/y is 0-indexed and proto wants 1
            var data: termio.Message.WriteReq.Small.Array = undefined;
            assert(data.len >= 5);
            data[0] = '\x1b';
            data[1] = '[';
            data[2] = 'M';
            data[3] = 32 + button_code;
            data[4] = 32 + @intCast(u8, viewport_point.x) + 1;
            data[5] = 32 + @intCast(u8, viewport_point.y) + 1;

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = 5,
                },
            }, .{ .forever = {} });
        },

        .utf8 => {
            // Maximum of 12 because at most we have 2 fully UTF-8 encoded chars
            var data: termio.Message.WriteReq.Small.Array = undefined;
            assert(data.len >= 12);
            data[0] = '\x1b';
            data[1] = '[';
            data[2] = 'M';

            // The button code will always fit in a single u8
            data[3] = 32 + button_code;

            // UTF-8 encode the x/y
            var i: usize = 4;
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.x + 1), data[i..]);
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.y + 1), data[i..]);

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, i),
                },
            }, .{ .forever = {} });
        },

        .sgr => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
                final,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },

        .urxvt => {
            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[{d};{d};{d}M", .{
                32 + button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },

        .sgr_pixels => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                pos.xpos,
                pos.ypos,
                final,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },
    }

    // After sending all our messages we have to notify our IO thread
    try self.io_thread.wakeup.send();
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
        win.queueRender() catch |err|
            log.err("error scheduling render timer in cursorPosCallback err={}", .{err});

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
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

    win.renderer_state.mutex.lock();
    defer win.renderer_state.mutex.unlock();

    // Report mouse events if enabled
    if (win.io.terminal.modes.mouse_event != .none) {
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
        win.mouse.left_click_point = point.toScreen(&win.io.terminal.screen);
        win.mouse.left_click_xpos = pos.xpos;
        win.mouse.left_click_ypos = pos.ypos;

        // Selection is always cleared
        if (win.io.terminal.selection != null) {
            win.io.terminal.selection = null;
            win.queueRender() catch |err|
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
        win.queueRender() catch |err|
            log.err("error scheduling render timer in cursorPosCallback err={}", .{err});

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
    }

    // We are reading/writing state for the remainder
    win.renderer_state.mutex.lock();
    defer win.renderer_state.mutex.unlock();

    // Do a mouse report
    if (win.io.terminal.modes.mouse_event != .none) {
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
    win.queueRender() catch |err|
        log.err("error scheduling render timer in cursorPosCallback err={}", .{err});

    // Convert to pixels from screen coords
    const pos = win.cursorPosToPixels(.{ .xpos = unscaled_xpos, .ypos = unscaled_ypos });
    const xpos = pos.xpos;
    const ypos = pos.ypos;

    // Convert to points
    const viewport_point = win.posToViewport(xpos, ypos);
    const screen_point = viewport_point.toScreen(&win.io.terminal.screen);

    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    if (win.io.terminal.selection) |sel| {
        const reset: bool = if (sel.end.before(sel.start))
            sel.start.before(screen_point)
        else
            screen_point.before(sel.start);

        if (reset) win.io.terminal.selection = null;
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
    const cell_xboundary = win.cell_size.width * 0.6;

    // first xpos of the clicked cell
    const cell_xstart = @intToFloat(f32, win.mouse.left_click_point.x) * win.cell_size.width;
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

        win.io.terminal.selection = if (selected) .{
            .start = screen_point,
            .end = screen_point,
        } else null;

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (win.io.terminal.selection == null) {
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
                    .x = win.io.terminal.screen.cols - 1,
                    .y = click_point.y -| 1,
                };
            }
        } else start: {
            if (win.mouse.left_click_xpos < cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x < win.io.terminal.screen.cols - 1) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x + 1,
                } else terminal.point.ScreenPoint{
                    .y = click_point.y + 1,
                    .x = 0,
                };
            }
        };

        win.io.terminal.selection = .{ .start = start, .end = screen_point };
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(win.io.terminal.selection != null);
    win.io.terminal.selection.?.end = screen_point;
}

fn posToViewport(self: Window, xpos: f64, ypos: f64) terminal.point.Viewport {
    // xpos and ypos can be negative if while dragging, the user moves the
    // mouse off the window. Likewise, they can be larger than our window
    // width if the user drags out of the window positively.
    return .{
        .x = if (xpos < 0) 0 else x: {
            // Our cell is the mouse divided by cell width
            const cell_width = @floatCast(f64, self.cell_size.width);
            const x = @floatToInt(usize, xpos / cell_width);

            // Can be off the screen if the user drags it out, so max
            // it out on our available columns
            break :x @min(x, self.grid_size.columns - 1);
        },

        .y = if (ypos < 0) 0 else y: {
            const cell_height = @floatCast(f64, self.cell_size.height);
            const y = @floatToInt(usize, ypos / cell_height);
            break :y @min(y, self.grid_size.rows - 1);
        },
    };
}

const face_ttf = @embedFile("font/res/FiraCode-Regular.ttf");
const face_bold_ttf = @embedFile("font/res/FiraCode-Bold.ttf");
const face_emoji_ttf = @embedFile("font/res/NotoColorEmoji.ttf");
const face_emoji_text_ttf = @embedFile("font/res/NotoEmoji-Regular.ttf");
