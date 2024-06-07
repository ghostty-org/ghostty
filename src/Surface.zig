//! Surface represents a single terminal "surface". A terminal surface is
//! a minimal "widget" where the terminal is drawn and responds to events
//! such as keyboard and mouse. Each surface also creates and owns its pty
//! session.
//!
//! The word "surface" is used because it is left to the higher level
//! application runtime to determine if the surface is a window, a tab,
//! a split, a preview pane in a larger window, etc. This struct doesn't care:
//! it just draws and responds to events. The events come from the application
//! runtime so the runtime can determine when and how those are delivered
//! (i.e. with focus, without focus, and so on).
const Surface = @This();

const apprt = @import("apprt.zig");
pub const Mailbox = apprt.surface.Mailbox;
pub const Message = apprt.surface.Message;

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const oni = @import("oniguruma");
const unicode = @import("unicode/main.zig");
const main = @import("main.zig");
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const objc = @import("objc");
const imgui = @import("imgui");
const Pty = @import("pty.zig").Pty;
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const input = @import("input.zig");
const App = @import("App.zig");
const internal_os = @import("os/main.zig");
const inspector = @import("inspector/main.zig");
const SurfaceMouse = @import("surface_mouse.zig");

const log = std.log.scoped(.surface);

// The renderer implementation to use.
const Renderer = renderer.Renderer;

/// Allocator
alloc: Allocator,

/// The app that this surface is attached to.
app: *App,

/// The windowing system surface and app.
rt_app: *apprt.runtime.App,
rt_surface: *apprt.runtime.Surface,

/// The font structures
font_grid_key: font.SharedGridSet.Key,
font_size: font.face.DesiredSize,

/// The renderer for this surface.
renderer: Renderer,

/// The render state
renderer_state: renderer.State,

/// The renderer thread manager
renderer_thread: renderer.Thread,

/// The actual thread
renderer_thr: std.Thread,

/// Mouse state.
mouse: Mouse,

/// A currently pressed key. This is used so that we can send a keyboard
/// release event when the surface is unfocused. Note that when the surface
/// is refocused, a key press event may not be sent again -- this depends
/// on the apprt (UI framework) in use, but we want to consistently send
/// a release.
///
/// This is only sent when a keypress event results in a key event being
/// sent to the pty. If it is consumed by a keybinding or other action,
/// this is not set.
///
/// Also note the utf8 value is not valid for this event so some unfocused
/// release events may not send exactly the right data within Kitty keyboard
/// events. This seems unspecificed in the spec so for now I'm okay with
/// this. Plus, its only for release events where the key text is far
/// less important.
pressed_key: ?input.KeyEvent = null,

/// The current color scheme of the GUI element containing this surface.
/// This will default to light until the apprt sends us the actual color
/// scheme. This is used by mode 3031 and CSI 996 n.
color_scheme: apprt.ColorScheme = .light,

/// The hash value of the last keybinding trigger that we performed. This
/// is only set if the last key input matched a keybinding, consumed it,
/// and performed it. This is used to prevent sending release/repeat events
/// for handled bindings.
last_binding_trigger: u64 = 0,

/// The terminal IO handler.
io: termio.Impl,
io_thread: termio.Thread,
io_thr: std.Thread,

/// Terminal inspector
inspector: ?*inspector.Inspector = null,

/// All the cached sizes since we need them at various times.
screen_size: renderer.ScreenSize,
grid_size: renderer.GridSize,
cell_size: renderer.CellSize,

/// Explicit padding due to configuration
padding: renderer.Padding,

/// The configuration derived from the main config. We "derive" it so that
/// we don't have a shared pointer hanging around that we need to worry about
/// the lifetime of. This makes updating config at runtime easier.
config: DerivedConfig,

/// This is set to true if our IO thread notifies us our child exited.
/// This is used to determine if we need to confirm, hold open, etc.
child_exited: bool = false,

/// The effect of an input event. This can be used by callers to take
/// the appropriate action after an input event. For example, key
/// input can be forwarded to the OS for further processing if it
/// wasn't handled in any way by Ghostty.
pub const InputEffect = enum {
    /// The input was not handled in any way by Ghostty and should be
    /// forwarded to other subsystems (i.e. the OS) for further
    /// processing.
    ignored,

    /// The input was handled and consumed by Ghostty.
    consumed,

    /// The input resulted in a close event for this surface so
    /// the surface, runtime surface, etc. pointers may all be
    /// unsafe to use so exit immediately.
    closed,
};

/// Mouse state for the surface.
const Mouse = struct {
    /// The last tracked mouse button state by button.
    click_state: [input.MouseButton.max]input.MouseButtonState = .{.release} ** input.MouseButton.max,

    /// The last mods state when the last mouse button (whatever it was) was
    /// pressed or release.
    mods: input.Mods = .{},

    /// The point at which the left mouse click happened. This is in screen
    /// coordinates so that scrolling preserves the location.
    left_click_pin: ?*terminal.Pin = null,
    left_click_screen: terminal.ScreenType = .primary,

    /// The starting xpos/ypos of the left click. Note that if scrolling occurs,
    /// these will point to different "cells", but the xpos/ypos will stay
    /// stable during scrolling relative to the surface.
    left_click_xpos: f64 = 0,
    left_click_ypos: f64 = 0,

    /// The count of clicks to count double and triple clicks and so on.
    /// The left click time was the last time the left click was done. This
    /// is always set on the first left click.
    left_click_count: u8 = 0,
    left_click_time: std.time.Instant = undefined,

    /// The last x/y sent for mouse reports.
    event_point: ?terminal.point.Coordinate = null,

    /// Pending scroll amounts for high-precision scrolls
    pending_scroll_x: f64 = 0,
    pending_scroll_y: f64 = 0,

    /// True if the mouse is hidden
    hidden: bool = false,

    /// True if the mouse position is currently over a link.
    over_link: bool = false,

    /// The last x/y in the cursor position for links. We use this to
    /// only process link hover events when the mouse actually moves cells.
    link_point: ?terminal.point.Coordinate = null,
};

/// The configuration that a surface has, this is copied from the main
/// Config struct usually to prevent sharing a single value.
const DerivedConfig = struct {
    arena: ArenaAllocator,

    /// For docs for these, see the associated config they are derived from.
    original_font_size: f32,
    keybind: configpkg.Keybinds,
    clipboard_read: configpkg.ClipboardAccess,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_trim_trailing_spaces: bool,
    clipboard_paste_protection: bool,
    clipboard_paste_bracketed_safe: bool,
    copy_on_select: configpkg.CopyOnSelect,
    confirm_close_surface: bool,
    cursor_click_to_move: bool,
    desktop_notifications: bool,
    font: font.SharedGridSet.DerivedConfig,
    mouse_interval: u64,
    mouse_hide_while_typing: bool,
    mouse_scroll_multiplier: f64,
    mouse_shift_capture: configpkg.MouseShiftCapture,
    macos_non_native_fullscreen: configpkg.NonNativeFullscreen,
    macos_option_as_alt: configpkg.OptionAsAlt,
    vt_kam_allowed: bool,
    window_padding_x: u32,
    window_padding_y: u32,
    window_padding_balance: bool,
    title: ?[:0]const u8,
    links: []const Link,

    const Link = struct {
        regex: oni.Regex,
        action: input.Link.Action,
        highlight: input.Link.Highlight,
    };

    pub fn init(alloc_gpa: Allocator, config: *const configpkg.Config) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Build all of our links
        const links = links: {
            var links = std.ArrayList(Link).init(alloc);
            defer links.deinit();
            for (config.link.links.items) |link| {
                var regex = try link.oniRegex();
                errdefer regex.deinit();
                try links.append(.{
                    .regex = regex,
                    .action = link.action,
                    .highlight = link.highlight,
                });
            }

            break :links try links.toOwnedSlice();
        };
        errdefer {
            for (links) |*link| link.regex.deinit();
            alloc.free(links);
        }

        return .{
            .original_font_size = config.@"font-size",
            .keybind = try config.keybind.clone(alloc),
            .clipboard_read = config.@"clipboard-read",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_trim_trailing_spaces = config.@"clipboard-trim-trailing-spaces",
            .clipboard_paste_protection = config.@"clipboard-paste-protection",
            .clipboard_paste_bracketed_safe = config.@"clipboard-paste-bracketed-safe",
            .copy_on_select = config.@"copy-on-select",
            .confirm_close_surface = config.@"confirm-close-surface",
            .cursor_click_to_move = config.@"cursor-click-to-move",
            .desktop_notifications = config.@"desktop-notifications",
            .font = try font.SharedGridSet.DerivedConfig.init(alloc, config),
            .mouse_interval = config.@"click-repeat-interval" * 1_000_000, // 500ms
            .mouse_hide_while_typing = config.@"mouse-hide-while-typing",
            .mouse_scroll_multiplier = config.@"mouse-scroll-multiplier",
            .mouse_shift_capture = config.@"mouse-shift-capture",
            .macos_non_native_fullscreen = config.@"macos-non-native-fullscreen",
            .macos_option_as_alt = config.@"macos-option-as-alt",
            .vt_kam_allowed = config.@"vt-kam-allowed",
            .window_padding_x = config.@"window-padding-x",
            .window_padding_y = config.@"window-padding-y",
            .window_padding_balance = config.@"window-padding-balance",
            .title = config.title,
            .links = links,

            // Assignments happen sequentially so we have to do this last
            // so that the memory is captured from allocs above.
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Create a new surface. This must be called from the main thread. The
/// pointer to the memory for the surface must be provided and must be
/// stable due to interfacing with various callbacks.
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config: *const configpkg.Config,
    app: *App,
    rt_app: *apprt.runtime.App,
    rt_surface: *apprt.runtime.Surface,
) !void {
    // Get our configuration
    var derived_config = try DerivedConfig.init(alloc, config);
    errdefer derived_config.deinit();

    // Initialize our renderer with our initialized surface.
    try Renderer.surfaceInit(rt_surface);

    // Determine our DPI configurations so we can properly configure
    // font points to pixels and handle other high-DPI scaling factors.
    const content_scale = try rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    log.debug("xscale={} yscale={} xdpi={} ydpi={}", .{
        content_scale.x,
        content_scale.y,
        x_dpi,
        y_dpi,
    });

    // The font size we desire along with the DPI determined for the surface
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @intFromFloat(x_dpi),
        .ydpi = @intFromFloat(y_dpi),
    };

    // Setup our font group. This will reuse an existing font group if
    // it was already loaded.
    const font_grid_key, const font_grid = try app.font_grid_set.ref(
        &derived_config.font,
        font_size,
    );

    // Pre-calculate our initial cell size ourselves.
    const cell_size = font_grid.cellSize();

    // Convert our padding from points to pixels
    const padding_x: u32 = padding_x: {
        const padding_x: f32 = @floatFromInt(config.@"window-padding-x");
        break :padding_x @intFromFloat(@floor(padding_x * x_dpi / 72));
    };
    const padding_y: u32 = padding_y: {
        const padding_y: f32 = @floatFromInt(config.@"window-padding-y");
        break :padding_y @intFromFloat(@floor(padding_y * y_dpi / 72));
    };
    const padding: renderer.Padding = .{
        .top = padding_y,
        .bottom = padding_y,
        .right = padding_x,
        .left = padding_x,
    };

    // Create our terminal grid with the initial size
    const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };
    var renderer_impl = try Renderer.init(alloc, .{
        .config = try Renderer.DerivedConfig.init(alloc, config),
        .font_grid = font_grid,
        .padding = .{
            .explicit = padding,
            .balance = config.@"window-padding-balance",
        },
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        .rt_surface = rt_surface,
    });
    errdefer renderer_impl.deinit();

    // Calculate our grid size based on known dimensions.
    const surface_size = try rt_surface.getSize();
    const screen_size: renderer.ScreenSize = .{
        .width = surface_size.width,
        .height = surface_size.height,
    };
    const grid_size = renderer.GridSize.init(
        screen_size.subPadding(padding),
        cell_size,
    );

    // The mutex used to protect our renderer state.
    const mutex = try alloc.create(std.Thread.Mutex);
    mutex.* = .{};
    errdefer alloc.destroy(mutex);

    // Create the renderer thread
    var render_thread = try renderer.Thread.init(
        alloc,
        config,
        rt_surface,
        &self.renderer,
        &self.renderer_state,
        app_mailbox,
    );
    errdefer render_thread.deinit();

    // Start our IO implementation
    var io = try termio.Impl.init(alloc, .{
        .grid_size = grid_size,
        .screen_size = screen_size,
        .padding = padding,
        .full_config = config,
        .config = try termio.Impl.DerivedConfig.init(alloc, config),
        .resources_dir = main.state.resources_dir,
        .renderer_state = &self.renderer_state,
        .renderer_wakeup = render_thread.wakeup,
        .renderer_mailbox = render_thread.mailbox,
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },

        // Get the cgroup if we're on linux and have the decl. I'd love
        // to change this from a decl to a surface options struct because
        // then we can do memory management better (don't need to retain
        // the string around).
        .linux_cgroup = if (comptime builtin.os.tag == .linux and
            @hasDecl(apprt.runtime.Surface, "cgroup"))
            rt_surface.cgroup()
        else
            termio.Options.linux_cgroup_default,
    });
    errdefer io.deinit();

    // Create the IO thread
    var io_thread = try termio.Thread.init(alloc, &self.io);
    errdefer io_thread.deinit();

    self.* = .{
        .alloc = alloc,
        .app = app,
        .rt_app = rt_app,
        .rt_surface = rt_surface,
        .font_grid_key = font_grid_key,
        .font_size = font_size,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .terminal = &self.io.terminal,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .io = io,
        .io_thread = io_thread,
        .io_thr = undefined,
        .screen_size = .{ .width = 0, .height = 0 },
        .grid_size = .{},
        .cell_size = cell_size,
        .padding = padding,
        .config = derived_config,
    };

    // Report initial cell size on surface creation
    try rt_surface.setCellSize(cell_size.width, cell_size.height);

    // Set a minimum size that is cols=10 h=4. This matches Mac's Terminal.app
    // but is otherwise somewhat arbitrary.
    try rt_surface.setSizeLimits(.{
        .width = cell_size.width * 10,
        .height = cell_size.height * 4,
    }, null);

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the surface
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    try self.sizeCallback(surface_size);

    // Give the renderer one more opportunity to finalize any surface
    // setup on the main thread prior to spinning up the rendering thread.
    try renderer_impl.finalizeSurfaceInit(rt_surface);

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

    // Determine our initial window size if configured. We need to do this
    // quite late in the process because our height/width are in grid dimensions,
    // so we need to know our cell sizes first.
    //
    // Note: it is important to do this after the renderer is setup above.
    // This allows the apprt to fully initialize the surface before we
    // start messing with the window.
    if (config.@"window-height" > 0 and config.@"window-width" > 0) init: {
        const scale = rt_surface.getContentScale() catch break :init;
        const height = @max(config.@"window-height" * cell_size.height, 480);
        const width = @max(config.@"window-width" * cell_size.width, 640);
        const width_f32: f32 = @floatFromInt(width);
        const height_f32: f32 = @floatFromInt(height);

        // The final values are affected by content scale and we need to
        // account for the padding so we get the exact correct grid size.
        const final_width: u32 =
            @as(u32, @intFromFloat(@ceil(width_f32 / scale.x))) +
            padding.left +
            padding.right;
        const final_height: u32 =
            @as(u32, @intFromFloat(@ceil(height_f32 / scale.y))) +
            padding.top +
            padding.bottom;

        rt_surface.setInitialWindowSize(final_width, final_height) catch |err| {
            log.warn("unable to set initial window size: {s}", .{err});
        };
    }

    if (config.title) |title| {
        try rt_surface.setTitle(title);
    } else if ((comptime builtin.os.tag == .linux) and
        config.@"_xdg-terminal-exec")
    xdg: {
        // For xdg-terminal-exec execution we special-case and set the window
        // title to the command being executed. This allows window managers
        // to set custom styling based on the command being executed.
        const command = config.command orelse break :xdg;
        if (command.len > 0) {
            const title = alloc.dupeZ(u8, command) catch |err| {
                log.warn(
                    "error copying command for title, title will not be set err={}",
                    .{err},
                );
                break :xdg;
            };
            defer alloc.free(title);
            try rt_surface.setTitle(title);
        }
    }
}

pub fn deinit(self: *Surface) void {
    // Stop rendering thread
    {
        self.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop, may stall err={}", .{err});
        self.renderer_thr.join();

        // We need to become the active rendering thread again
        self.renderer.threadEnter(self.rt_surface) catch unreachable;
    }

    // Stop our IO thread
    {
        self.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        self.io_thr.join();
    }

    // We need to deinit AFTER everything is stopped, since there are
    // shared values between the two threads.
    self.renderer_thread.deinit();
    self.renderer.deinit();
    self.io_thread.deinit();
    self.io.deinit();

    if (self.inspector) |v| {
        v.deinit();
        self.alloc.destroy(v);
    }

    // Clean up our font grid
    self.app.font_grid_set.deref(self.font_grid_key);

    // Clean up our render state
    if (self.renderer_state.preedit) |p| self.alloc.free(p.codepoints);
    self.alloc.destroy(self.renderer_state.mutex);
    self.config.deinit();

    log.info("surface closed addr={x}", .{@intFromPtr(self)});
}

/// Close this surface. This will trigger the runtime to start the
/// close process, which should ultimately deinitialize this surface.
pub fn close(self: *Surface) void {
    self.rt_surface.close(self.needsConfirmQuit());
}

/// Forces the surface to render. This is useful for when the surface
/// is in the middle of animation (such as a resize, etc.) or when
/// the render timer is managed manually by the apprt.
pub fn draw(self: *Surface) !void {
    try self.renderer_thread.draw_now.notify();
}

/// Activate the inspector. This will begin collecting inspection data.
/// This will not affect the GUI. The GUI must use performAction to
/// show/hide the inspector UI.
pub fn activateInspector(self: *Surface) !void {
    if (self.inspector != null) return;

    // Setup the inspector
    const ptr = try self.alloc.create(inspector.Inspector);
    errdefer self.alloc.destroy(ptr);
    ptr.* = try inspector.Inspector.init(self);
    self.inspector = ptr;

    // Put the inspector onto the render state
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        assert(self.renderer_state.inspector == null);
        self.renderer_state.inspector = self.inspector;
    }

    // Notify our components we have an inspector active
    _ = self.renderer_thread.mailbox.push(.{ .inspector = true }, .{ .forever = {} });
    _ = self.io_thread.mailbox.push(.{ .inspector = true }, .{ .forever = {} });
}

/// Deactivate the inspector and stop collecting any information.
pub fn deactivateInspector(self: *Surface) void {
    const insp = self.inspector orelse return;

    // Remove the inspector from the render state
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        assert(self.renderer_state.inspector != null);
        self.renderer_state.inspector = null;
    }

    // Notify our components we have deactivated inspector
    _ = self.renderer_thread.mailbox.push(.{ .inspector = false }, .{ .forever = {} });
    _ = self.io_thread.mailbox.push(.{ .inspector = false }, .{ .forever = {} });

    // Deinit the inspector
    insp.deinit();
    self.alloc.destroy(insp);
    self.inspector = null;
}

/// True if the surface requires confirmation to quit. This should be called
/// by apprt to determine if the surface should confirm before quitting.
pub fn needsConfirmQuit(self: *Surface) bool {
    // If the child has exited then our process is certainly not alive.
    // We check this first to avoid the locking overhead below.
    if (self.child_exited) return false;

    // If we are configured to not hold open surfaces explicitly, just
    // always say there is nothing alive.
    if (!self.config.confirm_close_surface) return false;

    // We have to talk to the terminal.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    return !self.io.terminal.cursorIsAtPrompt();
}

/// Called from the app thread to handle mailbox messages to our specific
/// surface.
pub fn handleMessage(self: *Surface, msg: Message) !void {
    switch (msg) {
        .change_config => |config| try self.changeConfig(config),

        .set_title => |*v| {
            // We ignore the message in case the title was set via config.
            if (self.config.title != null) {
                log.debug("ignoring title change request since static title is set via config", .{});
                return;
            }

            // The ptrCast just gets sliceTo to return the proper type.
            // We know that our title should end in 0.
            const slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(v)), 0);
            log.debug("changing title \"{s}\"", .{slice});
            try self.rt_surface.setTitle(slice);
        },

        .set_mouse_shape => |shape| {
            log.debug("changing mouse shape: {}", .{shape});
            try self.rt_surface.setMouseShape(shape);
        },

        .clipboard_read => |clipboard| {
            if (self.config.clipboard_read == .deny) {
                log.info("application attempted to read clipboard, but 'clipboard-read' is set to deny", .{});
                return;
            }

            try self.startClipboardRequest(.standard, .{ .osc_52_read = clipboard });
        },

        .clipboard_write => |w| switch (w.req) {
            .small => |v| try self.clipboardWrite(v.data[0..v.len], w.clipboard_type),
            .stable => |v| try self.clipboardWrite(v, w.clipboard_type),
            .alloc => |v| {
                defer v.alloc.free(v.data);
                try self.clipboardWrite(v.data, w.clipboard_type);
            },
        },

        .close => self.close(),

        // Close without confirmation.
        .child_exited => {
            self.child_exited = true;
            self.close();
        },

        .desktop_notification => |notification| {
            if (!self.config.desktop_notifications) {
                log.info("application attempted to display a desktop notification, but 'desktop-notifications' is disabled", .{});
                return;
            }

            const title = std.mem.sliceTo(&notification.title, 0);
            const body = std.mem.sliceTo(&notification.body, 0);
            try self.showDesktopNotification(title, body);
        },

        .renderer_health => |health| self.updateRendererHealth(health),

        .report_color_scheme => try self.reportColorScheme(),
    }
}

/// Sends a DSR response for the current color scheme to the pty.
fn reportColorScheme(self: *Surface) !void {
    const output = switch (self.color_scheme) {
        .light => "\x1B[?997;2n",
        .dark => "\x1B[?997;1n",
    };

    _ = self.io_thread.mailbox.push(.{ .write_stable = output }, .{ .forever = {} });
    try self.io_thread.wakeup.notify();
}

/// Call this when modifiers change. This is safe to call even if modifiers
/// match the previous state.
///
/// This is not publicly exported because modifier changes happen implicitly
/// on mouse callbacks, key callbacks, etc.
///
/// The renderer state mutex MUST NOT be held.
fn modsChanged(self: *Surface, mods: input.Mods) void {
    // The only place we keep track of mods currently is on the mouse.
    if (!self.mouse.mods.equal(mods)) {
        // The mouse mods only contain binding modifiers since we don't
        // want caps/num lock or sided modifiers to affect the mouse.
        self.mouse.mods = mods.binding();

        // We also need to update the renderer so it knows if it should
        // highlight links. Additionally, mark the screen as dirty so
        // that the highlight state of all links is properly updated.
        {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();
            self.renderer_state.mouse.mods = self.mouseModsWithCapture(self.mouse.mods);

            // We use the clear screen dirty flag to force a rebuild of all
            // rows because changing mouse mods can affect the highlight state
            // of a link. If there is no link this seems very wasteful but
            // its really only one frame so it's not so bad.
            self.renderer_state.terminal.flags.dirty.clear = true;
        }

        self.queueRender() catch |err| {
            // Not a big deal if this fails.
            log.warn("failed to notify renderer of mods change err={}", .{err});
        };
    }
}

/// Called when our renderer health state changes.
fn updateRendererHealth(self: *Surface, health: renderer.Health) void {
    log.warn("renderer health status change status={}", .{health});
    if (!@hasDecl(apprt.runtime.Surface, "updateRendererHealth")) return;
    self.rt_surface.updateRendererHealth(health);
}

/// Update our configuration at runtime.
fn changeConfig(self: *Surface, config: *const configpkg.Config) !void {
    // Update our new derived config immediately
    const derived = DerivedConfig.init(self.alloc, config) catch |err| {
        // If the derivation fails then we just log and return. We don't
        // hard fail in this case because we don't want to error the surface
        // when config fails we just want to keep using the old config.
        log.err("error updating configuration err={}", .{err});
        return;
    };
    self.config.deinit();
    self.config = derived;

    // If our mouse is hidden but we disabled mouse hiding, then show it again.
    if (!self.config.mouse_hide_while_typing and self.mouse.hidden) {
        self.showMouse();
    }

    // Before sending any other config changes, we give the renderer a new font
    // grid. We could check to see if there was an actual change to the font,
    // but this is easier and pretty rare so it's not a performance concern.
    //
    // (Calling setFontSize builds and sends a new font grid to the renderer.)
    try self.setFontSize(self.font_size);

    // We need to store our configs in a heap-allocated pointer so that
    // our messages aren't huge.
    var renderer_message = try renderer.Message.initChangeConfig(self.alloc, config);
    errdefer renderer_message.deinit();
    var termio_config_ptr = try self.alloc.create(termio.Impl.DerivedConfig);
    errdefer self.alloc.destroy(termio_config_ptr);
    termio_config_ptr.* = try termio.Impl.DerivedConfig.init(self.alloc, config);
    errdefer termio_config_ptr.deinit();

    _ = self.renderer_thread.mailbox.push(renderer_message, .{ .forever = {} });
    _ = self.io_thread.mailbox.push(.{
        .change_config = .{
            .alloc = self.alloc,
            .ptr = termio_config_ptr,
        },
    }, .{ .forever = {} });

    // With mailbox messages sent, we have to wake them up so they process it.
    self.queueRender() catch |err| {
        log.warn("failed to notify renderer of config change err={}", .{err});
    };
    self.io_thread.wakeup.notify() catch |err| {
        log.warn("failed to notify io thread of config change err={}", .{err});
    };
}

/// Returns true if the terminal has a selection.
pub fn hasSelection(self: *const Surface) bool {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    return self.io.terminal.screen.selection != null;
}

/// Returns the selected text. This is allocated.
pub fn selectionString(self: *Surface, alloc: Allocator) !?[]const u8 {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const sel = self.io.terminal.screen.selection orelse return null;
    return try self.io.terminal.screen.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
}

/// Returns the pwd of the terminal, if any. This is always copied because
/// the pwd can change at any point from termio. If we are calling from the IO
/// thread you should just check the terminal directly.
pub fn pwd(self: *const Surface, alloc: Allocator) !?[]const u8 {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const terminal_pwd = self.io.terminal.getPwd() orelse return null;
    return try alloc.dupe(u8, terminal_pwd);
}

/// Returns the x/y coordinate of where the IME (Input Method Editor)
/// keyboard should be rendered.
pub fn imePoint(self: *const Surface) apprt.IMEPos {
    self.renderer_state.mutex.lock();
    const cursor = self.renderer_state.terminal.screen.cursor;
    self.renderer_state.mutex.unlock();

    // TODO: need to handle when scrolling and the cursor is not
    // in the visible portion of the screen.

    // Our sizes are all scaled so we need to send the unscaled values back.
    const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };

    const x: f64 = x: {
        // Simple x * cell width gives the top-left corner
        var x: f64 = @floatFromInt(cursor.x * self.cell_size.width);

        // We want the midpoint
        x += @as(f64, @floatFromInt(self.cell_size.width)) / 2;

        // And scale it
        x /= content_scale.x;

        break :x x;
    };

    const y: f64 = y: {
        // Simple x * cell width gives the top-left corner
        var y: f64 = @floatFromInt(cursor.y * self.cell_size.height);

        // We want the bottom
        y += @floatFromInt(self.cell_size.height);

        // And scale it
        y /= content_scale.y;

        break :y y;
    };

    return .{ .x = x, .y = y };
}

fn clipboardWrite(self: *const Surface, data: []const u8, loc: apprt.Clipboard) !void {
    if (self.config.clipboard_write == .deny) {
        log.info("application attempted to write clipboard, but 'clipboard-write' is set to deny", .{});
        return;
    }

    const dec = std.base64.standard.Decoder;

    // Build buffer
    const size = dec.calcSizeForSlice(data) catch |err| switch (err) {
        error.InvalidPadding => {
            log.info("application sent invalid base64 data for OSC 52", .{});
            return;
        },

        // Should not be reachable but don't want to risk it.
        else => return,
    };
    var buf = try self.alloc.allocSentinel(u8, size, 0);
    defer self.alloc.free(buf);
    buf[buf.len] = 0;

    // Decode
    dec.decode(buf, data) catch |err| switch (err) {
        // Ignore this. It is possible to actually have valid data and
        // get this error, so we allow it.
        error.InvalidPadding => {},

        else => {
            log.info("application sent invalid base64 data for OSC 52", .{});
            return;
        },
    };
    assert(buf[buf.len] == 0);

    // When clipboard-write is "ask" a prompt is displayed to the user asking
    // them to confirm the clipboard access. Each app runtime handles this
    // differently.
    const confirm = self.config.clipboard_write == .ask;
    self.rt_surface.setClipboardString(buf, loc, confirm) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}

/// Set the selection contents.
///
/// This must be called with the renderer mutex held.
fn setSelection(self: *Surface, sel_: ?terminal.Selection) !void {
    const prev_ = self.io.terminal.screen.selection;
    try self.io.terminal.screen.select(sel_);

    // Determine the clipboard we want to copy selection to, if it is enabled.
    const clipboard: apprt.Clipboard = switch (self.config.copy_on_select) {
        .false => return,
        .true => .selection,
        .clipboard => .standard,
    };

    // Set our selection clipboard. If the selection is cleared we do not
    // clear the clipboard. If the selection is set, we only set the clipboard
    // again if it changed, since setting the clipboard can be an expensive
    // operation.
    const sel = sel_ orelse return;
    if (prev_) |prev| if (sel.eql(prev)) return;

    // Check if our runtime supports the selection clipboard at all.
    // We can save a lot of work if it doesn't.
    if (@hasDecl(apprt.runtime.Surface, "supportsClipboard")) {
        if (!self.rt_surface.supportsClipboard(clipboard)) {
            return;
        }
    }

    const buf = self.io.terminal.screen.selectionString(self.alloc, .{
        .sel = sel,
        .trim = self.config.clipboard_trim_trailing_spaces,
    }) catch |err| {
        log.err("error reading selection string err={}", .{err});
        return;
    };
    defer self.alloc.free(buf);

    self.rt_surface.setClipboardString(buf, clipboard, false) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}

/// Change the cell size for the terminal grid. This can happen as
/// a result of changing the font size at runtime.
fn setCellSize(self: *Surface, size: renderer.CellSize) !void {
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
    self.io_thread.wakeup.notify() catch {};

    // Notify the window
    try self.rt_surface.setCellSize(size.width, size.height);
}

/// Change the font size.
///
/// This can only be called from the main thread.
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) !void {
    // Update our font size so future changes work
    self.font_size = size;

    // We need to build up a new font stack for this font size.
    const font_grid_key, const font_grid = try self.app.font_grid_set.ref(
        &self.config.font,
        self.font_size,
    );
    errdefer self.app.font_grid_set.deref(font_grid_key);

    // Set our cell size
    try self.setCellSize(.{
        .width = font_grid.metrics.cell_width,
        .height = font_grid.metrics.cell_height,
    });

    // Notify our render thread of the new font stack. The renderer
    // MUST accept the new font grid and deref the old.
    _ = self.renderer_thread.mailbox.push(.{
        .font_grid = .{
            .grid = font_grid,
            .set = &self.app.font_grid_set,
            .old_key = self.font_grid_key,
            .new_key = font_grid_key,
        },
    }, .{ .forever = {} });

    // Once we've sent the key we can replace our key
    self.font_grid_key = font_grid_key;

    // Schedule render which also drains our mailbox
    self.queueRender() catch unreachable;
}

/// This queues a render operation with the renderer thread. The render
/// isn't guaranteed to happen immediately but it will happen as soon as
/// practical.
fn queueRender(self: *Surface) !void {
    try self.renderer_thread.wakeup.notify();
}

pub fn sizeCallback(self: *Surface, size: apprt.SurfaceSize) !void {
    const new_screen_size: renderer.ScreenSize = .{
        .width = size.width,
        .height = size.height,
    };

    // Update our screen size, but only if it actually changed. And if
    // the screen size didn't change, then our grid size could not have
    // changed, so we just return.
    if (self.screen_size.equals(new_screen_size)) return;

    try self.resize(new_screen_size);
}

fn resize(self: *Surface, size: renderer.ScreenSize) !void {
    // Save our screen size
    self.screen_size = size;

    // Mail the renderer so that it can update the GPU and re-render
    _ = self.renderer_thread.mailbox.push(.{
        .resize = .{
            .screen_size = self.screen_size,
            .padding = self.padding,
        },
    }, .{ .forever = {} });
    try self.queueRender();

    // Recalculate our grid size. Because Ghostty supports fluid resizing,
    // its possible the grid doesn't change at all even if the screen size changes.
    // We have to update the IO thread no matter what because we send
    // pixel-level sizing to the subprocess.
    self.grid_size = renderer.GridSize.init(
        self.screen_size.subPadding(self.padding),
        self.cell_size,
    );
    if (self.grid_size.columns < 5 and (self.padding.left > 0 or self.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (self.grid_size.rows < 2 and (self.padding.top > 0 or self.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }

    // Mail the IO thread
    _ = self.io_thread.mailbox.push(.{
        .resize = .{
            .grid_size = self.grid_size,
            .screen_size = self.screen_size,
            .padding = self.padding,
        },
    }, .{ .forever = {} });
    try self.io_thread.wakeup.notify();
}

/// Called to set the preedit state for character input. Preedit is used
/// with dead key states, for example, when typing an accent character.
/// This should be called with null to reset the preedit state.
///
/// The core surface will NOT reset the preedit state on charCallback or
/// keyCallback and we rely completely on the apprt implementation to track
/// the preedit state correctly.
///
/// The preedit input must be UTF-8 encoded.
pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) !void {
    // log.debug("text preeditCallback value={any}", .{preedit_});

    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // We always clear our prior preedit
    if (self.renderer_state.preedit) |p| {
        self.alloc.free(p.codepoints);
        self.renderer_state.preedit = null;
    }

    // Mark preedit dirty flag
    self.io.terminal.flags.dirty.preedit = true;

    // If we have no text, we're done. We queue a render in case we cleared
    // a prior preedit (likely).
    const text = preedit_ orelse {
        try self.queueRender();
        return;
    };

    // We convert the UTF-8 text to codepoints.
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();

    // Allocate the codepoints slice
    const Codepoint = renderer.State.Preedit.Codepoint;
    var codepoints: std.ArrayListUnmanaged(Codepoint) = .{};
    defer codepoints.deinit(self.alloc);
    while (it.nextCodepoint()) |cp| {
        const width: usize = @intCast(unicode.table.get(cp).width);

        // I've never seen a preedit text with a zero-width character. In
        // theory its possible but we can't really handle it right now.
        // Let's just ignore it.
        if (width <= 0) continue;

        try codepoints.append(
            self.alloc,
            .{ .codepoint = cp, .wide = width >= 2 },
        );
    }

    // If we have no codepoints, then we're done.
    if (codepoints.items.len == 0) {
        try self.queueRender();
        return;
    }

    self.renderer_state.preedit = .{
        .codepoints = try codepoints.toOwnedSlice(self.alloc),
    };
    try self.queueRender();
}

/// Called for any key events. This handles keybindings, encoding and
/// sending to the termianl, etc. The return value is true if the key
/// was handled and false if it was not.
pub fn keyCallback(
    self: *Surface,
    event: input.KeyEvent,
) !InputEffect {
    // log.debug("text keyCallback event={}", .{event});

    // Setup our inspector event if we have an inspector.
    var insp_ev: ?inspector.key.Event = if (self.inspector != null) ev: {
        var copy = event;
        copy.utf8 = "";
        if (event.utf8.len > 0) copy.utf8 = try self.alloc.dupe(u8, event.utf8);
        break :ev .{ .event = copy };
    } else null;

    // When we're done processing, we always want to add the event to
    // the inspector.
    defer if (insp_ev) |ev| ev: {
        // We have to check for the inspector again because our keybinding
        // might close it.
        const insp = self.inspector orelse {
            ev.deinit(self.alloc);
            break :ev;
        };

        if (insp.recordKeyEvent(ev)) {
            self.queueRender() catch {};
        } else |err| {
            log.warn("error adding key event to inspector err={}", .{err});
        }
    };

    // Before encoding, we see if we have any keybindings for this
    // key. Those always intercept before any encoding tasks.
    binding: {
        const binding_action: input.Binding.Action, const binding_trigger: input.Binding.Trigger, const consumed = action: {
            const binding_mods = event.mods.binding();
            var trigger: input.Binding.Trigger = .{
                .mods = binding_mods,
                .key = .{ .translated = event.key },
            };

            const set = self.config.keybind.set;
            if (set.get(trigger)) |v| break :action .{
                v,
                trigger,
                set.getConsumed(trigger),
            };

            trigger.key = .{ .physical = event.physical_key };
            if (set.get(trigger)) |v| break :action .{
                v,
                trigger,
                set.getConsumed(trigger),
            };

            if (event.unshifted_codepoint > 0) {
                trigger.key = .{ .unicode = event.unshifted_codepoint };
                if (set.get(trigger)) |v| break :action .{
                    v,
                    trigger,
                    set.getConsumed(trigger),
                };
            }

            break :binding;
        };

        // We only execute the binding on press/repeat but we still consume
        // the key on release so that we don't send any release events.
        log.debug("key event binding consumed={} action={}", .{ consumed, binding_action });
        const performed = if (event.action == .press or event.action == .repeat) press: {
            self.last_binding_trigger = 0;
            break :press try self.performBindingAction(binding_action);
        } else false;

        // If we performed an action and it was a closing action,
        // our "self" pointer is not safe to use anymore so we need to
        // just exit immediately.
        if (performed and closingAction(binding_action)) {
            log.debug("key binding is a closing binding, halting key event processing", .{});
            return .closed;
        }

        // If we consume this event, then we are done. If we don't consume
        // it, we processed the action but we still want to process our
        // encodings, too.
        if (consumed and performed) {
            self.last_binding_trigger = binding_trigger.hash();
            if (insp_ev) |*ev| ev.binding = binding_action;
            return .consumed;
        }

        // If we have a previous binding trigger and it matches this one,
        // then we handled the down event so we don't want to send any further
        // events.
        if (self.last_binding_trigger > 0 and
            self.last_binding_trigger == binding_trigger.hash())
        {
            return .consumed;
        }
    }

    // Expand selection if one exists and event is shift + <arrows, home, end, pg up/down>
    if (event.mods.shift) adjust_selection: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        var screen = &self.io.terminal.screen;
        const sel = if (screen.selection) |*sel| sel else break :adjust_selection;

        // Silently consume key releases. We only want to process selection
        // adjust on press.
        if (event.action != .press and event.action != .repeat) return .consumed;

        sel.adjust(screen, switch (event.key) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
            .page_up => .page_up,
            .page_down => .page_down,
            .home => .home,
            .end => .end,
            else => break :adjust_selection,
        });

        // If the selection endpoint is outside of the current viewpoint,
        // scroll it in to view. Note we always specifically use sel.end
        // because that is what adjust modifies.
        scroll: {
            const viewport_tl = screen.pages.getTopLeft(.viewport);
            const viewport_br = screen.pages.getBottomRight(.viewport).?;
            if (sel.end().isBetween(viewport_tl, viewport_br))
                break :scroll;

            // Our end point is not within the viewport. If the end
            // point is after the br then we need to adjust the end so
            // that it is at the bottom right of the viewport.
            const target = if (sel.end().before(viewport_tl))
                sel.end()
            else
                sel.end().up(screen.pages.rows - 1) orelse sel.end();

            screen.scroll(.{ .pin = target });
        }

        // Queue a render so its shown
        try self.queueRender();
        return .consumed;
    }

    // If we allow KAM and KAM is enabled then we do nothing.
    if (self.config.vt_kam_allowed) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        if (self.io.terminal.modes.get(.disable_keyboard)) return .consumed;
    }

    // If this input event has text, then we hide the mouse if configured.
    // We only do this on pressed events to avoid hiding the mouse when we
    // change focus due to a keybinding (i.e. switching tabs).
    if (self.config.mouse_hide_while_typing and
        event.action == .press and
        !self.mouse.hidden and
        event.utf8.len > 0)
    {
        self.hideMouse();
    }

    // If our mouse modifiers change, we run a cursor position event.
    // This handles the scenario where URL highlighting should be
    // toggled for example.
    if (!self.mouse.mods.equal(event.mods)) mouse_mods: {
        // This is a hacky way to prevent cursorPosCallback from
        // showing our hidden mouse: we just pretend the mouse isn't hidden.
        // We used to re-call `self.hideMouse()` but this causes flickering
        // in some cases in GTK.
        const rehide = self.mouse.hidden;
        self.mouse.hidden = false;

        // Update our modifiers, this will update mouse mods too
        self.modsChanged(event.mods);

        // We set this to null to force link reprocessing since
        // mod changes can affect link highlighting.
        self.mouse.link_point = null;
        const pos = self.rt_surface.getCursorPos() catch break :mouse_mods;
        self.cursorPosCallback(pos) catch {};
        if (rehide) self.mouse.hidden = true;
    }

    // Process the cursor state logic. This will update the cursor shape if
    // needed, depending on the key state.
    if ((SurfaceMouse{
        .physical_key = event.physical_key,
        .mouse_event = self.io.terminal.flags.mouse_event,
        .mouse_shape = self.io.terminal.mouse_shape,
        .mods = self.mouse.mods,
        .over_link = self.mouse.over_link,
        .hidden = self.mouse.hidden,
    }).keyToMouseShape()) |shape|
        try self.rt_surface.setMouseShape(shape);

    // No binding, so we have to perform an encoding task. This
    // may still result in no encoding. Under different modes and
    // inputs there are many keybindings that result in no encoding
    // whatsoever.
    const enc: input.KeyEncoder = enc: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        const t = &self.io.terminal;
        break :enc .{
            .event = event,
            .macos_option_as_alt = self.config.macos_option_as_alt,
            .alt_esc_prefix = t.modes.get(.alt_esc_prefix),
            .cursor_key_application = t.modes.get(.cursor_keys),
            .keypad_key_application = t.modes.get(.keypad_keys),
            .ignore_keypad_with_numlock = t.modes.get(.ignore_keypad_with_numlock),
            .modify_other_keys_state_2 = t.flags.modify_other_keys_2,
            .kitty_flags = t.screen.kitty_keyboard.current(),
        };
    };

    // We've processed a key event that produced some data so we want to
    // track the last pressed key.
    self.pressed_key = event: {
        // We need to unset the allocated fields that will become invalid
        var copy = event;
        copy.utf8 = "";

        // If we have a previous pressed key and we're releasing it
        // then we set it to invalid to prevent repeating the release event.
        if (event.action == .release) {
            // if we didn't have a previous event and this is a release
            // event then we just want to set it to null.
            const prev = self.pressed_key orelse break :event null;
            if (prev.key == copy.key) copy.key = .invalid;
        }

        // If our key is invalid and we have no mods, then we're done!
        // This helps catch the state that we naturally released all keys.
        if (copy.key == .invalid and copy.mods.empty()) break :event null;

        break :event copy;
    };

    const write_req: termio.Message.WriteReq = req: {
        // Try to write the input into a small array. This fits almost
        // every scenario. Larger situations can happen due to long
        // pre-edits.
        var data: termio.Message.WriteReq.Small.Array = undefined;
        if (enc.encode(&data)) |seq| {
            // Special-case: we did nothing.
            if (seq.len == 0) return .ignored;

            break :req .{ .small = .{
                .data = data,
                .len = @intCast(seq.len),
            } };
        } else |err| switch (err) {
            // Means we need to allocate
            error.OutOfMemory => {},
            else => return err,
        }

        // We need to allocate. We allocate double the UTF-8 length
        // or double the small array size, whichever is larger. That's
        // a heuristic that should work. The only scenario I know while
        // typing this where we don't have enough space is a long preedit,
        // and in that case the size we need is exactly the UTF-8 length,
        // so the double is being safe.
        const buf = try self.alloc.alloc(u8, @max(
            event.utf8.len * 2,
            data.len * 2,
        ));
        defer self.alloc.free(buf);

        // This results in a double allocation but this is such an unlikely
        // path the performance impact is unimportant.
        const seq = try enc.encode(buf);
        break :req try termio.Message.WriteReq.init(self.alloc, seq);
    };

    // Copy the encoded data into the inspector event if we have one.
    // We do this before the mailbox because the IO thread could
    // release the memory before we get a chance to copy it.
    if (insp_ev) |*ev| pty: {
        const slice = write_req.slice();
        const copy = self.alloc.alloc(u8, slice.len) catch |err| {
            log.warn("error allocating pty data for inspector err={}", .{err});
            break :pty;
        };
        errdefer self.alloc.free(copy);
        @memcpy(copy, slice);
        ev.pty = copy;
    }

    _ = self.io_thread.mailbox.push(switch (write_req) {
        .small => |v| .{ .write_small = v },
        .stable => |v| .{ .write_stable = v },
        .alloc => |v| .{ .write_alloc = v },
    }, .{ .forever = {} });
    try self.io_thread.wakeup.notify();

    // If our event is any keypress that isn't a modifier and we generated
    // some data to send to the pty, then we move the viewport down to the
    // bottom. We also clear the selection for any key other then modifiers.
    if (!event.key.modifier()) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        try self.setSelection(null);
        try self.io.terminal.scrollViewport(.{ .bottom = {} });
        try self.queueRender();
    }

    return .consumed;
}

/// Sends text as-is to the terminal without triggering any keyboard
/// protocol. This will treat the input text as if it was pasted
/// from the clipboard so the same logic will be applied. Namely,
/// if bracketed mode is on this will do a bracketed paste. Otherwise,
/// this will filter newlines to '\r'.
pub fn textCallback(self: *Surface, text: []const u8) !void {
    try self.completeClipboardPaste(text, true);
}

/// Callback for when the surface is fully visible or not, regardless
/// of focus state. This is used to pause rendering when the surface
/// is not visible, and also re-render when it becomes visible again.
pub fn occlusionCallback(self: *Surface, visible: bool) !void {
    _ = self.renderer_thread.mailbox.push(.{
        .visible = visible,
    }, .{ .forever = {} });
    try self.queueRender();
}

pub fn focusCallback(self: *Surface, focused: bool) !void {
    // Notify our render thread of the new state
    _ = self.renderer_thread.mailbox.push(.{
        .focus = focused,
    }, .{ .forever = {} });

    if (focused) {
        // Notify our app if we gained focus.
        self.app.focusSurface(self);
    } else unfocused: {
        // If we lost focus and we have a keypress, then we want to send a key
        // release event for it. Depending on the apprt, this CAN result in
        // duplicate key release events, but that is better than not sending
        // a key release event at all.
        var pressed_key = self.pressed_key orelse break :unfocused;
        self.pressed_key = null;

        // All our actions will be releases
        pressed_key.action = .release;

        // Release the full key first
        if (pressed_key.key != .invalid) {
            assert(self.keyCallback(pressed_key) catch |err| err: {
                log.warn("error releasing key on focus loss err={}", .{err});
                break :err .ignored;
            } != .closed);
        }

        // Release any modifiers if set
        if (pressed_key.mods.empty()) break :unfocused;

        // This is kind of nasty comptime meta programming but all we're doing
        // here is going through all the modifiers and if they're set, releasing
        // both the left and right sides of the modifier. This may not match
        // the exact input event but it ensures a full reset.
        const keys = &.{ "shift", "ctrl", "alt", "super" };
        const original_key = pressed_key.key;
        inline for (keys) |key| {
            if (@field(pressed_key.mods, key)) {
                @field(pressed_key.mods, key) = false;
                inline for (&.{ "right", "left" }) |side| {
                    const keyname = if (comptime std.mem.eql(u8, key, "ctrl")) "control" else key;
                    pressed_key.key = @field(input.Key, side ++ "_" ++ keyname);
                    if (pressed_key.key != original_key) {
                        assert(self.keyCallback(pressed_key) catch |err| err: {
                            log.warn("error releasing key on focus loss err={}", .{err});
                            break :err .ignored;
                        } != .closed);
                    }
                }
            }
        }
    }

    // Schedule render which also drains our mailbox
    try self.queueRender();

    // Notify the app about focus in/out if it is requesting it
    {
        self.renderer_state.mutex.lock();
        const focus_event = self.io.terminal.modes.get(.focus_event);
        self.renderer_state.mutex.unlock();

        if (focus_event) {
            const seq = if (focused) "\x1b[I" else "\x1b[O";
            _ = self.io_thread.mailbox.push(.{
                .write_stable = seq,
            }, .{ .forever = {} });

            try self.io_thread.wakeup.notify();
        }
    }
}

pub fn refreshCallback(self: *Surface) !void {
    // The point of this callback is to schedule a render, so do that.
    try self.queueRender();
}

pub fn scrollCallback(
    self: *Surface,
    xoff: f64,
    yoff: f64,
    scroll_mods: input.ScrollMods,
) !void {
    // log.info("SCROLL: xoff={} yoff={} mods={}", .{ xoff, yoff, scroll_mods });

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    const ScrollAmount = struct {
        // Positive is up, right
        sign: isize = 1,
        delta_unsigned: usize = 0,
        delta: isize = 0,
    };

    const y: ScrollAmount = if (yoff == 0) .{} else y: {
        // Non-precision scrolling is easy to calculate.
        if (!scroll_mods.precision) {
            const y_sign: isize = if (yoff > 0) -1 else 1;
            const grid_rows: f64 = @floatFromInt(self.grid_size.rows);
            const y_delta_f64 = @round((grid_rows * self.config.mouse_scroll_multiplier) / 15.0);
            const y_delta_unsigned: usize = @max(1, @as(usize, @intFromFloat(y_delta_f64)));
            const y_delta: isize = y_sign * @as(isize, @intCast(y_delta_unsigned));
            break :y .{ .sign = y_sign, .delta_unsigned = y_delta_unsigned, .delta = y_delta };
        }

        // Precision scrolling is more complicated. We need to maintain state
        // to build up a pending scroll amount if we're only scrolling by a
        // tiny amount so that we can scroll by a full row when we have enough.

        // Adjust our offset by the multiplier
        const yoff_adjusted = yoff * self.config.mouse_scroll_multiplier;

        // Add our previously saved pending amount to the offset to get the
        // new offset value.
        //
        // NOTE: we currently multiply by -1 because macOS sends the opposite
        // of what we expect. This is jank we should audit our sign usage and
        // carefully document what we expect so this can work cross platform.
        // Right now this isn't important because macOS is the only high-precision
        // scroller.
        const poff = self.mouse.pending_scroll_y + (yoff_adjusted * -1);

        // If the new offset is less than a single unit of scroll, we save
        // the new pending value and do not scroll yet.
        const cell_size: f64 = @floatFromInt(self.cell_size.height);
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_y = poff;
            break :y .{};
        }

        // We scroll by the number of rows in the offset and save the remainder
        const amount = poff / cell_size;
        self.mouse.pending_scroll_y = poff - (amount * cell_size);

        break :y .{
            .sign = if (yoff_adjusted > 0) 1 else -1,
            .delta_unsigned = @intFromFloat(@abs(amount)),
            .delta = @intFromFloat(amount),
        };
    };

    // For detailed comments see the y calculation above.
    const x: ScrollAmount = if (xoff == 0) .{} else x: {
        if (!scroll_mods.precision) {
            const x_sign: isize = if (xoff < 0) -1 else 1;
            const x_delta_unsigned: usize = @intFromFloat(@round(1 * self.config.mouse_scroll_multiplier));
            const x_delta: isize = x_sign * @as(isize, @intCast(x_delta_unsigned));
            break :x .{ .sign = x_sign, .delta_unsigned = x_delta_unsigned, .delta = x_delta };
        }

        const xoff_adjusted = xoff * self.config.mouse_scroll_multiplier;
        const poff = self.mouse.pending_scroll_x + (xoff_adjusted * -1);
        const cell_size: f64 = @floatFromInt(self.cell_size.width);
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_x = poff;
            break :x .{};
        }

        const amount = poff / cell_size;
        self.mouse.pending_scroll_x = poff - (amount * cell_size);

        break :x .{
            .delta_unsigned = @intFromFloat(@abs(amount)),
            .delta = @intFromFloat(amount),
        };
    };

    log.info("scroll: delta_y={} delta_x={}", .{ y.delta, x.delta });

    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we have an active mouse reporting mode, clear the selection.
        // The selection can occur if the user uses the shift mod key to
        // override mouse grabbing from the window.
        if (self.io.terminal.flags.mouse_event != .none) {
            try self.setSelection(null);
        }

        // If we're in alternate screen with alternate scroll enabled, then
        // we convert to cursor keys. This only happens if we're:
        // (1) alt screen (2) no explicit mouse reporting and (3) alt
        // scroll mode enabled.
        if (self.io.terminal.active_screen == .alternate and
            self.io.terminal.flags.mouse_event == .none and
            self.io.terminal.modes.get(.mouse_alternate_scroll))
        {
            if (y.delta_unsigned > 0) {
                // When we send mouse events as cursor keys we always
                // clear the selection.
                try self.setSelection(null);

                const seq = if (self.io.terminal.modes.get(.cursor_keys)) seq: {
                    // cursor key: application mode
                    break :seq if (y.delta < 0) "\x1bOA" else "\x1bOB";
                } else seq: {
                    // cursor key: normal mode
                    break :seq if (y.delta < 0) "\x1b[A" else "\x1b[B";
                };
                for (0..y.delta_unsigned) |_| {
                    _ = self.io_thread.mailbox.push(.{
                        .write_stable = seq,
                    }, .{ .instant = {} });
                }
            }

            // After sending all our messages we have to notify our IO thread
            try self.io_thread.wakeup.notify();
            return;
        }

        // We have mouse events, are not in an alternate scroll buffer,
        // or have alternate scroll disabled. In this case, we just run
        // the normal logic.

        // If we're scrolling up or down, then send a mouse event.
        if (self.io.terminal.flags.mouse_event != .none) {
            if (y.delta != 0) {
                const pos = try self.rt_surface.getCursorPos();
                try self.mouseReport(if (y.delta < 0) .four else .five, .press, self.mouse.mods, pos);
            }

            if (x.delta != 0) {
                const pos = try self.rt_surface.getCursorPos();
                try self.mouseReport(if (x.delta > 0) .six else .seven, .press, self.mouse.mods, pos);
            }

            // If mouse reporting is on, we do not want to scroll the
            // viewport.
            return;
        }

        // Modify our viewport, this requires a lock since it affects rendering
        try self.io.terminal.scrollViewport(.{ .delta = y.delta });
    }

    try self.queueRender();
}

/// This is called when the content scale of the surface changes. The surface
/// can then update any DPI-sensitive state.
pub fn contentScaleCallback(self: *Surface, content_scale: apprt.ContentScale) !void {
    // Calculate the new DPI
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;

    // Update our font size which is dependent on the DPI
    const size = size: {
        var size = self.font_size;
        size.xdpi = @intFromFloat(x_dpi);
        size.ydpi = @intFromFloat(y_dpi);
        break :size size;
    };

    // If our DPI didn't actually change, save a lot of work by doing nothing.
    if (size.xdpi == self.font_size.xdpi and size.ydpi == self.font_size.ydpi) {
        return;
    }

    try self.setFontSize(size);

    // Update our padding which is dependent on DPI.
    self.padding = padding: {
        const padding_x: u32 = padding_x: {
            const padding_x: f32 = @floatFromInt(self.config.window_padding_x);
            break :padding_x @intFromFloat(@floor(padding_x * x_dpi / 72));
        };
        const padding_y: u32 = padding_y: {
            const padding_y: f32 = @floatFromInt(self.config.window_padding_y);
            break :padding_y @intFromFloat(@floor(padding_y * y_dpi / 72));
        };

        break :padding .{
            .top = padding_y,
            .bottom = padding_y,
            .right = padding_x,
            .left = padding_x,
        };
    };

    // Force a resize event because the change in padding will affect
    // pixel-level changes to the renderer and viewport.
    try self.resize(self.screen_size);
}

/// The type of action to report for a mouse event.
const MouseReportAction = enum { press, release, motion };

fn mouseReport(
    self: *Surface,
    button: ?input.MouseButton,
    action: MouseReportAction,
    mods: input.Mods,
    pos: apprt.CursorPos,
) !void {
    // Depending on the event, we may do nothing at all.
    switch (self.io.terminal.flags.mouse_event) {
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

    // Handle scenarios where the mouse position is outside the viewport.
    // We always report release events no matter where they happen.
    if (action != .release) {
        const pos_out_viewport = pos_out_viewport: {
            const max_x: f32 = @floatFromInt(self.screen_size.width);
            const max_y: f32 = @floatFromInt(self.screen_size.height);
            break :pos_out_viewport pos.x < 0 or pos.y < 0 or
                pos.x > max_x or pos.y > max_y;
        };
        if (pos_out_viewport) outside_viewport: {
            // If we don't have a motion-tracking event mode, do nothing.
            if (!self.io.terminal.flags.mouse_event.motion()) return;

            // If any button is pressed, we still do the report. Otherwise,
            // we do not do the report.
            for (self.mouse.click_state) |state| {
                if (state != .release) break :outside_viewport;
            }

            return;
        }
    }

    // This format reports X/Y
    const viewport_point = self.posToViewport(pos.x, pos.y);

    // Record our new point. We only want to send a mouse event if the
    // cell changed, unless we're tracking raw pixels.
    if (action == .motion and self.io.terminal.flags.mouse_format != .sgr_pixels) {
        if (self.mouse.event_point) |last_point| {
            if (last_point.eql(viewport_point)) return;
        }
    }
    self.mouse.event_point = viewport_point;

    // Get the code we'll actually write
    const button_code: u8 = code: {
        var acc: u8 = 0;

        // Determine our initial button value
        if (button == null) {
            // Null button means motion without a button pressed
            acc = 3;
        } else if (action == .release and
            self.io.terminal.flags.mouse_format != .sgr and
            self.io.terminal.flags.mouse_format != .sgr_pixels)
        {
            // Release is 3. It is NOT 3 in SGR mode because SGR can tell
            // the application what button was released.
            acc = 3;
        } else {
            acc = switch (button.?) {
                .left => 0,
                .middle => 1,
                .right => 2,
                .four => 64,
                .five => 65,
                else => return, // unsupported
            };
        }

        // X10 doesn't have modifiers
        if (self.io.terminal.flags.mouse_event != .x10) {
            if (mods.shift) acc += 4;
            if (mods.alt) acc += 8;
            if (mods.ctrl) acc += 16;
        }

        // Motion adds another bit
        if (action == .motion) acc += 32;

        break :code acc;
    };

    switch (self.io.terminal.flags.mouse_format) {
        .x10 => {
            if (viewport_point.x > 222 or viewport_point.y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 below is because our x/y is 0-indexed and the protocol wants 1
            var data: termio.Message.WriteReq.Small.Array = undefined;
            assert(data.len >= 6);
            data[0] = '\x1b';
            data[1] = '[';
            data[2] = 'M';
            data[3] = 32 + button_code;
            data[4] = 32 + @as(u8, @intCast(viewport_point.x)) + 1;
            data[5] = 32 + @as(u8, @intCast(viewport_point.y)) + 1;

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = 6,
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
            i += try std.unicode.utf8Encode(@intCast(32 + viewport_point.x + 1), data[i..]);
            i += try std.unicode.utf8Encode(@intCast(32 + viewport_point.y + 1), data[i..]);

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(i),
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
                    .len = @intCast(resp.len),
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
                    .len = @intCast(resp.len),
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
                @as(i32, @intFromFloat(@round(pos.x))),
                @as(i32, @intFromFloat(@round(pos.y))),
                final,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(resp.len),
                },
            }, .{ .forever = {} });
        },
    }

    // After sending all our messages we have to notify our IO thread
    try self.io_thread.wakeup.notify();
}

/// Returns true if the shift modifier is allowed to be captured by modifier
/// events. It is up to the caller to still verify it is a situation in which
/// shift capture makes sense (i.e. left button, mouse click, etc.)
fn mouseShiftCapture(self: *const Surface, lock: bool) bool {
    // Handle our never/always case where we don't need a lock.
    switch (self.config.mouse_shift_capture) {
        .never => return false,
        .always => return true,
        .false, .true => {},
    }

    if (lock) self.renderer_state.mutex.lock();
    defer if (lock) self.renderer_state.mutex.unlock();

    // If thet terminal explicitly requests it then we always allow it
    // since we processed never/always at this point.
    switch (self.io.terminal.flags.mouse_shift_capture) {
        .false => return false,
        .true => return true,
        .null => {},
    }

    // Otherwise, go with the user's preference
    return switch (self.config.mouse_shift_capture) {
        .false => false,
        .true => true,
        .never, .always => unreachable, // handled earlier
    };
}

pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) !void {
    // log.debug("mouse action={} button={} mods={}", .{ action, button, mods });

    // If we have an inspector, we always queue a render
    if (self.inspector) |insp| {
        defer self.queueRender() catch {};

        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If the inspector is requesting a cell, then we intercept
        // left mouse clicks and send them to the inspector.
        if (insp.cell == .requested and
            button == .left and
            action == .press)
        {
            const pos = try self.rt_surface.getCursorPos();
            const point = self.posToViewport(pos.x, pos.y);
            const screen = &self.renderer_state.terminal.screen;
            const p = screen.pages.pin(.{ .viewport = point }) orelse {
                log.warn("failed to get pin for clicked point", .{});
                return;
            };

            insp.cell.select(
                self.alloc,
                p,
                point.x,
                point.y,
            ) catch |err| {
                log.warn("error selecting cell for inspector err={}", .{err});
            };
            return;
        }
    }

    // Always record our latest mouse state
    self.mouse.click_state[@intCast(@intFromEnum(button))] = action;

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // Update our modifiers if they changed
    self.modsChanged(mods);

    // This is set to true if the terminal is allowed to capture the shift
    // modifer. Note we can do this more efficiently probably with less
    // locking/unlocking but clicking isn't that frequent enough to be a
    // bottleneck.
    const shift_capture = self.mouseShiftCapture(true);

    // Shift-click continues the previous mouse state if we have a selection.
    // cursorPosCallback will also do a mouse report so we don't need to do any
    // of the logic below.
    if (button == .left and action == .press) {
        if (mods.shift and
            self.mouse.left_click_count > 0 and
            !shift_capture)
        {
            // Checking for selection requires the renderer state mutex which
            // sucks but this should be pretty rare of an event so it won't
            // cause a ton of contention.
            const selection = selection: {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();
                break :selection self.io.terminal.screen.selection != null;
            };

            if (selection) {
                const pos = try self.rt_surface.getCursorPos();
                try self.cursorPosCallback(pos);
                return;
            }
        }
    }

    // Handle link clicking. We want to do this before we do mouse
    // reporting or any other mouse handling because a successfully
    // clicked link will swallow the event.
    if (button == .left and action == .release and self.mouse.over_link) {
        const pos = try self.rt_surface.getCursorPos();
        if (self.processLinks(pos)) |processed| {
            if (processed) return;
        } else |err| {
            log.warn("error processing links err={}", .{err});
        }
    }

    // Report mouse events if enabled
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        if (self.io.terminal.flags.mouse_event != .none) report: {
            // If we have shift-pressed and we aren't allowed to capture it,
            // then we do not do a mouse report.
            if (mods.shift and button == .left and !shift_capture) break :report;

            // In any other mouse button scenario without shift pressed we
            // clear the selection since the underlying application can handle
            // that in any way (i.e. "scrolling").
            try self.setSelection(null);

            // We also set the left click count to 0 so that if mouse reporting
            // is disabled in the middle of press (before release) we don't
            // suddenly start selecting text.
            self.mouse.left_click_count = 0;

            const pos = try self.rt_surface.getCursorPos();

            const report_action: MouseReportAction = switch (action) {
                .press => .press,
                .release => .release,
            };

            try self.mouseReport(
                button,
                report_action,
                self.mouse.mods,
                pos,
            );

            // If we're doing mouse reporting, we do not support any other
            // selection or highlighting.
            return;
        }
    }

    // For left button click release we check if we are moving our cursor.
    if (button == .left and action == .release and mods.alt) click_move: {
        // Moving always resets the click count so that we don't highlight.
        self.mouse.left_click_count = 0;
        const pin = self.mouse.left_click_pin orelse break :click_move;
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        try self.clickMoveCursor(pin.*);
        return;
    }

    // For left button clicks we always record some information for
    // selection/highlighting purposes.
    if (button == .left and action == .press) click: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        const t: *terminal.Terminal = self.renderer_state.terminal;
        const screen = &self.renderer_state.terminal.screen;

        const pos = try self.rt_surface.getCursorPos();
        const pin = pin: {
            const pt_viewport = self.posToViewport(pos.x, pos.y);
            const pin = screen.pages.pin(.{
                .viewport = .{
                    .x = pt_viewport.x,
                    .y = pt_viewport.y,
                },
            }) orelse {
                // Weird... our viewport x/y that we just converted isn't
                // found in our pages. This is probably a bug but we don't
                // want to crash in releases because its harmless. So, we
                // only assert in debug mode.
                if (comptime std.debug.runtime_safety) unreachable;
                break :click;
            };

            break :pin try screen.pages.trackPin(pin);
        };
        errdefer screen.pages.untrackPin(pin);

        // If we move our cursor too much between clicks then we reset
        // the multi-click state.
        if (self.mouse.left_click_count > 0) {
            const max_distance: f64 = @floatFromInt(self.cell_size.width);
            const distance = @sqrt(
                std.math.pow(f64, pos.x - self.mouse.left_click_xpos, 2) +
                    std.math.pow(f64, pos.y - self.mouse.left_click_ypos, 2),
            );

            if (distance > max_distance) self.mouse.left_click_count = 0;
        }

        if (self.mouse.left_click_pin) |prev| {
            const pin_screen = t.getScreen(self.mouse.left_click_screen);
            pin_screen.pages.untrackPin(prev);
            self.mouse.left_click_pin = null;
        }

        // Store it
        self.mouse.left_click_pin = pin;
        self.mouse.left_click_screen = t.active_screen;
        self.mouse.left_click_xpos = pos.x;
        self.mouse.left_click_ypos = pos.y;

        // Setup our click counter and timer
        if (std.time.Instant.now()) |now| {
            // If we have mouse clicks, then we check if the time elapsed
            // is less than and our interval and if so, increase the count.
            if (self.mouse.left_click_count > 0) {
                const since = now.since(self.mouse.left_click_time);
                if (since > self.config.mouse_interval) {
                    self.mouse.left_click_count = 0;
                }
            }

            self.mouse.left_click_time = now;
            self.mouse.left_click_count += 1;

            // We only support up to triple-clicks.
            if (self.mouse.left_click_count > 3) self.mouse.left_click_count = 1;
        } else |err| {
            self.mouse.left_click_count = 1;
            log.err("error reading time, mouse multi-click won't work err={}", .{err});
        }

        switch (self.mouse.left_click_count) {
            // Single click
            1 => {
                // If we have a selection, clear it. This always happens.
                if (self.io.terminal.screen.selection != null) {
                    try self.setSelection(null);
                    try self.queueRender();
                }
            },

            // Double click, select the word under our mouse
            2 => {
                const sel_ = self.io.terminal.screen.selectWord(pin.*);
                if (sel_) |sel| {
                    try self.setSelection(sel);
                    try self.queueRender();
                }
            },

            // Triple click, select the line under our mouse
            3 => {
                const sel_ = if (mods.ctrl)
                    self.io.terminal.screen.selectOutput(pin.*)
                else
                    self.io.terminal.screen.selectLine(.{ .pin = pin.* });
                if (sel_) |sel| {
                    try self.setSelection(sel);
                    try self.queueRender();
                }
            },

            // We should be bounded by 1 to 3
            else => unreachable,
        }
    }

    // Middle-click pastes from our selection clipboard
    if (button == .middle and action == .press) {
        if (comptime builtin.target.isDarwin()) {
            // Fast-path for MacOS - always paste from clipboard on
            // middle-click.
            try self.startClipboardRequest(.standard, .{ .paste = {} });
        } else if (self.config.copy_on_select != .false) {
            const clipboard: apprt.Clipboard = switch (self.config.copy_on_select) {
                .true => .selection,
                .clipboard => .standard,
                .false => unreachable,
            };

            try self.startClipboardRequest(clipboard, .{ .paste = {} });
        }
    }
}

/// Performs the "click-to-move" logic to move the cursor to the given
/// screen point if possible. This works by converting the path to the
/// given point into a series of arrow key inputs.
fn clickMoveCursor(self: *Surface, to: terminal.Pin) !void {
    // If click-to-move is disabled then we're done.
    if (!self.config.cursor_click_to_move) return;

    const t = &self.io.terminal;

    // Click to move cursor only works on the primary screen where prompts
    // exist. This means that alt screen multiplexers like tmux will not
    // support this feature. It is just too messy.
    if (t.active_screen != .primary) return;

    // This flag is only set if we've seen at least one semantic prompt
    // OSC sequence. If we've never seen that sequence, we can't possibly
    // move the cursor so we can fast path out of here.
    if (!t.flags.shell_redraws_prompt) return;

    // Get our path
    const from = t.screen.cursor.page_pin.*;
    const path = t.screen.promptPath(from, to);
    log.debug("click-to-move-cursor from={} to={} path={}", .{ from, to, path });

    // If we aren't moving at all, fast path out of here.
    if (path.x == 0 and path.y == 0) return;

    // Convert our path to arrow key inputs. Yes, that is how this works.
    // Yes, that is pretty sad. Yes, this could backfire in various ways.
    // But its the best we can do.

    // We do Y first because it prevents any weird wrap behavior.
    if (path.y != 0) {
        const arrow = if (path.y < 0) arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOA" else "\x1b[A";
        } else arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOB" else "\x1b[B";
        };
        for (0..@abs(path.y)) |_| {
            _ = self.io_thread.mailbox.push(.{
                .write_stable = arrow,
            }, .{ .instant = {} });
        }
    }
    if (path.x != 0) {
        const arrow = if (path.x < 0) arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D";
        } else arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C";
        };
        for (0..@abs(path.x)) |_| {
            _ = self.io_thread.mailbox.push(.{
                .write_stable = arrow,
            }, .{ .instant = {} });
        }
    }

    try self.io_thread.wakeup.notify();
}

/// Returns the link at the given cursor position, if any.
fn linkAtPos(
    self: *Surface,
    pos: apprt.CursorPos,
) !?struct {
    DerivedConfig.Link,
    terminal.Selection,
} {
    // If we have no configured links we can save a lot of work
    if (self.config.links.len == 0) return null;

    // Convert our cursor position to a screen point.
    const screen = &self.renderer_state.terminal.screen;
    const mouse_pin: terminal.Pin = mouse_pin: {
        const point = self.posToViewport(pos.x, pos.y);
        const pin = screen.pages.pin(.{ .viewport = point }) orelse {
            log.warn("failed to get pin for clicked point", .{});
            return null;
        };
        break :mouse_pin pin;
    };

    // Get our comparison mods
    const mouse_mods = self.mouseModsWithCapture(self.mouse.mods);

    // Get the line we're hovering over.
    const line = screen.selectLine(.{
        .pin = mouse_pin,
        .whitespace = null,
        .semantic_prompt_boundary = false,
    }) orelse return null;

    var strmap: terminal.StringMap = undefined;
    self.alloc.free(try screen.selectionString(self.alloc, .{
        .sel = line,
        .trim = false,
        .map = &strmap,
    }));
    defer strmap.deinit(self.alloc);

    // Go through each link and see if we clicked it
    for (self.config.links) |link| {
        switch (link.highlight) {
            .always, .hover => {},
            .always_mods, .hover_mods => |v| if (!v.equal(mouse_mods)) continue,
        }

        var it = strmap.searchIterator(link.regex);
        while (true) {
            var match = (try it.next()) orelse break;
            defer match.deinit();
            const sel = match.selection();
            if (!sel.contains(screen, mouse_pin)) continue;
            return .{ link, sel };
        }
    }

    return null;
}

/// This returns the mouse mods to consider for link highlighting or
/// other purposes taking into account when shift is pressed for releasing
/// the mouse from capture.
///
/// The renderer state mutex must be held.
fn mouseModsWithCapture(self: *Surface, mods: input.Mods) input.Mods {
    // In any of these scenarios, whatever mods are set (even shift)
    // are preserved.
    if (self.io.terminal.flags.mouse_event == .none) return mods;
    if (!mods.shift) return mods;
    if (self.mouseShiftCapture(false)) return mods;

    // We have mouse capture, shift set, and we're not allowed to capture
    // shift, so we can clear shift.
    var final = mods;
    final.shift = false;
    return final;
}

/// Attempt to invoke the action of any link that is under the
/// given position.
///
/// Requires the renderer state mutex is held.
fn processLinks(self: *Surface, pos: apprt.CursorPos) !bool {
    const link, const sel = try self.linkAtPos(pos) orelse return false;
    switch (link.action) {
        .open => {
            const str = try self.io.terminal.screen.selectionString(self.alloc, .{
                .sel = sel,
                .trim = false,
            });
            defer self.alloc.free(str);
            try internal_os.open(self.alloc, str);
        },
    }

    return true;
}

pub fn cursorPosCallback(
    self: *Surface,
    pos: apprt.CursorPos,
) !void {
    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // The mouse position in the viewport
    const pos_vp = self.posToViewport(pos.x, pos.y);

    // We always reset the over link status because it will be reprocessed
    // below. But we need the old value to know if we need to undo mouse
    // shape changes.
    const over_link = self.mouse.over_link;
    self.mouse.over_link = false;

    // We are reading/writing state for the remainder
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Update our mouse state. We set this to null initially because we only
    // want to set it when we're not selecting or doing any other mouse
    // event.
    self.renderer_state.mouse.point = null;

    // If we have an inspector, we need to always record position information
    if (self.inspector) |insp| {
        insp.mouse.last_xpos = pos.x;
        insp.mouse.last_ypos = pos.y;

        const screen = &self.renderer_state.terminal.screen;
        insp.mouse.last_point = screen.pages.pin(.{ .viewport = .{
            .x = pos_vp.x,
            .y = pos_vp.y,
        } });
        try self.queueRender();
    }

    // Do a mouse report
    if (self.io.terminal.flags.mouse_event != .none) report: {
        // Shift overrides mouse "grabbing" in the window, taken from Kitty.
        if (self.mouse.mods.shift and
            !self.mouseShiftCapture(false)) break :report;

        // We use the first mouse button we find pressed in order to report
        // since the spec (afaict) does not say...
        const button: ?input.MouseButton = button: for (self.mouse.click_state, 0..) |state, i| {
            if (state == .press)
                break :button @enumFromInt(i);
        } else null;

        try self.mouseReport(button, .motion, self.mouse.mods, pos);

        // If we were previously over a link, we need to queue a
        // render to undo the link state.
        if (over_link) try self.queueRender();

        // If we're doing mouse motion tracking, we do not support text
        // selection.
        return;
    }

    // Handle cursor position for text selection
    if (self.mouse.click_state[@intFromEnum(input.MouseButton.left)] == .press) select: {
        // Left click pressed but count zero can happen if mouse reporting is on.
        // In this scenario, we mark the click state because we need that to
        // properly make some mouse reports, but we don't keep track of the
        // count because we don't want to handle selection.
        if (self.mouse.left_click_count == 0) break :select;

        // All roads lead to requiring a re-render at this point.
        try self.queueRender();

        // If our y is negative, we're above the window. In this case, we scroll
        // up. The amount we scroll up is dependent on how negative we are.
        // Note: one day, we can change this from distance to time based if we want.
        //log.warn("CURSOR POS: {} {}", .{ pos, self.screen_size });
        const max_y: f32 = @floatFromInt(self.screen_size.height);
        if (pos.y < 0 or pos.y > max_y) {
            const delta: isize = if (pos.y < 0) -1 else 1;
            try self.io.terminal.scrollViewport(.{ .delta = delta });

            // TODO: We want a timer or something to repeat while we're still
            // at this cursor position. Right now, the user has to jiggle their
            // mouse in order to scroll.
        }

        // Convert to points
        const screen = &self.renderer_state.terminal.screen;
        const pin = screen.pages.pin(.{
            .viewport = .{
                .x = pos_vp.x,
                .y = pos_vp.y,
            },
        }) orelse {
            if (comptime std.debug.runtime_safety) unreachable;
            return;
        };

        // Handle dragging depending on click count
        switch (self.mouse.left_click_count) {
            1 => try self.dragLeftClickSingle(pin, pos.x),
            2 => try self.dragLeftClickDouble(pin),
            3 => try self.dragLeftClickTriple(pin),
            0 => unreachable, // handled above
            else => unreachable,
        }

        return;
    }

    // Handle link hovering
    if (self.mouse.link_point) |last_vp| {
        // Mark the link's row as dirty.
        if (over_link) {
            // TODO: This doesn't handle soft-wrapped links. Ideally this would
            // be storing the link's start and end points and marking all rows
            // between and including those as dirty, instead of just the row
            // containing the part the cursor is hovering. This can result in
            // a bit of jank.
            if (self.renderer_state.terminal.screen.pages.pin(.{
                .viewport = last_vp,
            })) |pin| {
                pin.markDirty();
            }
        }

        // If our last link viewport point is unchanged, then don't process
        // links. This avoids constantly reprocessing regular expressions
        // for every pixel change.
        if (last_vp.eql(pos_vp)) {
            // We have to restore old values that are always cleared
            if (over_link) {
                self.mouse.over_link = over_link;
                self.renderer_state.mouse.point = pos_vp;
            }

            return;
        }
    }
    self.mouse.link_point = pos_vp;

    if (try self.linkAtPos(pos)) |_| {
        self.renderer_state.mouse.point = pos_vp;
        self.mouse.over_link = true;
        // Mark the new link's row as dirty.
        if (self.renderer_state.terminal.screen.pages.pin(.{ .viewport = pos_vp })) |pin| {
            pin.markDirty();
        }
        try self.rt_surface.setMouseShape(.pointer);
        try self.queueRender();
    } else if (over_link) {
        try self.rt_surface.setMouseShape(self.io.terminal.mouse_shape);
        try self.queueRender();
    }
}

/// Double-click dragging moves the selection one "word" at a time.
fn dragLeftClickDouble(
    self: *Surface,
    drag_pin: terminal.Pin,
) !void {
    const screen = &self.io.terminal.screen;
    const click_pin = self.mouse.left_click_pin.?.*;

    // Get the word closest to our starting click.
    const word_start = screen.selectWordBetween(click_pin, drag_pin) orelse {
        try self.setSelection(null);
        return;
    };

    // Get the word closest to our current point.
    const word_current = screen.selectWordBetween(
        drag_pin,
        click_pin,
    ) orelse {
        try self.setSelection(null);
        return;
    };

    // If our current mouse position is before the starting position,
    // then the seletion start is the word nearest our current position.
    if (drag_pin.before(click_pin)) {
        try self.setSelection(terminal.Selection.init(
            word_current.start(),
            word_start.end(),
            false,
        ));
    } else {
        try self.setSelection(terminal.Selection.init(
            word_start.start(),
            word_current.end(),
            false,
        ));
    }
}

/// Triple-click dragging moves the selection one "line" at a time.
fn dragLeftClickTriple(
    self: *Surface,
    drag_pin: terminal.Pin,
) !void {
    const screen = &self.io.terminal.screen;
    const click_pin = self.mouse.left_click_pin.?.*;

    // Get the word under our current point. If there isn't a word, do nothing.
    const word = screen.selectLine(.{ .pin = drag_pin }) orelse return;

    // Get our selection to grow it. If we don't have a selection, start it now.
    // We may not have a selection if we started our dbl-click in an area
    // that had no data, then we dragged our mouse into an area with data.
    var sel = screen.selectLine(.{ .pin = click_pin }) orelse {
        try self.setSelection(word);
        return;
    };

    // Grow our selection
    if (drag_pin.before(click_pin)) {
        sel.startPtr().* = word.start();
    } else {
        sel.endPtr().* = word.end();
    }
    try self.setSelection(sel);
}

fn dragLeftClickSingle(
    self: *Surface,
    drag_pin: terminal.Pin,
    xpos: f64,
) !void {
    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    self.checkResetSelSwitch(drag_pin);

    // Our logic for determining if the starting cell is selected:
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

    // Our clicking point
    const click_pin = self.mouse.left_click_pin.?.*;

    // the boundary point at which we consider selection or non-selection
    const cell_width_f64: f64 = @floatFromInt(self.cell_size.width);
    const cell_xboundary = cell_width_f64 * 0.6;

    // first xpos of the clicked cell adjusted for padding
    const left_padding_f64: f64 = @as(f64, @floatFromInt(self.padding.left));
    const cell_xstart = @as(f64, @floatFromInt(click_pin.x)) * cell_width_f64;
    const cell_start_xpos = self.mouse.left_click_xpos - cell_xstart - left_padding_f64;

    // If this is the same cell, then we only start the selection if weve
    // moved past the boundary point the opposite direction from where we
    // started.
    if (click_pin.eql(drag_pin)) {
        // Ensuring to adjusting the cursor position for padding
        const cell_xpos = xpos - cell_xstart - left_padding_f64;
        const selected: bool = if (cell_start_xpos < cell_xboundary)
            cell_xpos >= cell_xboundary
        else
            cell_xpos < cell_xboundary;

        try self.setSelection(if (selected) terminal.Selection.init(
            drag_pin,
            drag_pin,
            self.mouse.mods.ctrlOrSuper() and self.mouse.mods.alt,
        ) else null);

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (self.io.terminal.screen.selection == null) {
        //   - If we're moving to a point before the start, then we select
        //     the starting cell if we started after the boundary, else
        //     we start selection of the prior cell.
        //   - Inverse logic for a point after the start.
        const start: terminal.Pin = if (dragLeftClickBefore(
            drag_pin,
            click_pin,
            self.mouse.mods,
        )) start: {
            if (cell_start_xpos >= cell_xboundary) break :start click_pin;
            if (click_pin.x > 0) break :start click_pin.left(1);
            var start = click_pin.up(1) orelse click_pin;
            start.x = self.io.terminal.screen.pages.cols - 1;
            break :start start;
        } else start: {
            if (cell_start_xpos < cell_xboundary) break :start click_pin;
            if (click_pin.x < self.io.terminal.screen.pages.cols - 1)
                break :start click_pin.right(1);
            var start = click_pin.down(1) orelse click_pin;
            start.x = 0;
            break :start start;
        };

        try self.setSelection(terminal.Selection.init(
            start,
            drag_pin,
            self.mouse.mods.ctrlOrSuper() and self.mouse.mods.alt,
        ));
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(self.io.terminal.screen.selection != null);
    const sel = self.io.terminal.screen.selection.?;
    try self.setSelection(terminal.Selection.init(
        sel.start(),
        drag_pin,
        sel.rectangle,
    ));
}

// Resets the selection if we switched directions, depending on the select
// mode. See dragLeftClickSingle for more details.
fn checkResetSelSwitch(
    self: *Surface,
    drag_pin: terminal.Pin,
) void {
    const screen = &self.io.terminal.screen;
    const sel = screen.selection orelse return;
    const sel_start = sel.start();
    const sel_end = sel.end();

    var reset: bool = false;
    if (sel.rectangle) {
        // When we're in rectangle mode, we reset the selection relative to
        // the click point depending on the selection mode we're in, with
        // the exception of single-column selections, which we always reset
        // on if we drift.
        if (sel_start.x == sel_end.x) {
            reset = drag_pin.x != sel_start.x;
        } else {
            reset = switch (sel.order(screen)) {
                .forward => drag_pin.x < sel_start.x or drag_pin.before(sel_start),
                .reverse => drag_pin.x > sel_start.x or sel_start.before(drag_pin),
                .mirrored_forward => drag_pin.x > sel_start.x or drag_pin.before(sel_start),
                .mirrored_reverse => drag_pin.x < sel_start.x or sel_start.before(drag_pin),
            };
        }
    } else {
        // Normal select uses simpler logic that is just based on the
        // selection start/end.
        reset = if (sel_end.before(sel_start))
            sel_start.before(drag_pin)
        else
            drag_pin.before(sel_start);
    }

    // Nullifying a selection can't fail.
    if (reset) self.setSelection(null) catch unreachable;
}

// Handles how whether or not the drag screen point is before the click point.
// When we are in rectangle select, we only interpret the x axis to determine
// where to start the selection (before or after the click point). See
// dragLeftClickSingle for more details.
fn dragLeftClickBefore(
    drag_pin: terminal.Pin,
    click_pin: terminal.Pin,
    mods: input.Mods,
) bool {
    if (mods.ctrlOrSuper() and mods.alt) {
        return drag_pin.x < click_pin.x;
    }

    return drag_pin.before(click_pin);
}

/// Call to notify Ghostty that the color scheme for the terminal has
/// changed.
pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) !void {
    // If our scheme didn't change, then we don't do anything.
    if (self.color_scheme == scheme) return;

    // Set our new scheme
    self.color_scheme = scheme;

    // If mode 2031 is on, then we report the change live.
    const report = report: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        break :report self.renderer_state.terminal.modes.get(.report_color_scheme);
    };
    if (report) try self.reportColorScheme();
}

fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Coordinate {
    // xpos/ypos need to be adjusted for window padding
    // (i.e. "window-padding-*" settings.
    const pad = if (self.config.window_padding_balance)
        renderer.Padding.balanced(self.screen_size, self.grid_size, self.cell_size)
    else
        self.padding;

    const xpos_adjusted: f64 = xpos - @as(f64, @floatFromInt(pad.left));
    const ypos_adjusted: f64 = ypos - @as(f64, @floatFromInt(pad.top));

    // xpos and ypos can be negative if while dragging, the user moves the
    // mouse off the surface. Likewise, they can be larger than our surface
    // width if the user drags out of the surface positively.
    return .{
        .x = if (xpos_adjusted < 0) 0 else x: {
            // Our cell is the mouse divided by cell width
            const cell_width: f64 = @floatFromInt(self.cell_size.width);
            const x: usize = @intFromFloat(xpos_adjusted / cell_width);

            // Can be off the screen if the user drags it out, so max
            // it out on our available columns
            break :x @min(x, self.grid_size.columns - 1);
        },

        .y = if (ypos_adjusted < 0) 0 else y: {
            const cell_height: f64 = @floatFromInt(self.cell_size.height);
            const y: usize = @intFromFloat(ypos_adjusted / cell_height);
            break :y @min(y, self.grid_size.rows - 1);
        },
    };
}

/// Scroll to the bottom of the viewport.
///
/// Precondition: the render_state mutex must be held.
fn scrollToBottom(self: *Surface) !void {
    try self.io.terminal.scrollViewport(.{ .bottom = {} });
    try self.queueRender();
}

fn hideMouse(self: *Surface) void {
    if (self.mouse.hidden) return;
    self.mouse.hidden = true;
    self.rt_surface.setMouseVisibility(false);
}

fn showMouse(self: *Surface) void {
    if (!self.mouse.hidden) return;
    self.mouse.hidden = false;
    self.rt_surface.setMouseVisibility(true);
}

/// Perform a binding action. A binding is a keybinding. This function
/// must be called from the GUI thread.
///
/// This function returns true if the binding action was performed. This
/// may return false if the binding action is not supported or if the
/// binding action would do nothing (i.e. previous tab with no tabs).
///
/// NOTE: At the time of writing this comment, only previous/next tab
/// will ever return false. We can expand this in the future if it becomes
/// useful. We did previous/next tab so we could implement #498.
pub fn performBindingAction(self: *Surface, action: input.Binding.Action) !bool {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},

        .open_config => try self.app.openConfig(self.rt_app),

        .reload_config => try self.app.reloadConfig(self.rt_app),

        .csi, .esc => |data| {
            // We need to send the CSI/ESC sequence as a single write request.
            // If you split it across two then the shell can interpret it
            // as two literals.
            var buf: [128]u8 = undefined;
            const full_data = switch (action) {
                .csi => try std.fmt.bufPrint(&buf, "\x1b[{s}", .{data}),
                .esc => try std.fmt.bufPrint(&buf, "\x1b{s}", .{data}),
                else => unreachable,
            };
            _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
                self.alloc,
                full_data,
            ), .{ .forever = {} });
            try self.io_thread.wakeup.notify();

            // CSI/ESC triggers a scroll.
            {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },

        .text => |data| {
            // For text we always allocate just because its easier to
            // handle all cases that way.
            const buf = try self.alloc.alloc(u8, data.len);
            defer self.alloc.free(buf);
            const text = configpkg.string.parse(buf, data) catch |err| {
                log.warn(
                    "error parsing text binding text={s} err={}",
                    .{ data, err },
                );
                return true;
            };
            _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
                self.alloc,
                text,
            ), .{ .forever = {} });
            try self.io_thread.wakeup.notify();

            // Text triggers a scroll.
            {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };
            }
        },

        .cursor_key => |ck| {
            // We send a different sequence depending on if we're
            // in cursor keys mode. We're in "normal" mode if cursor
            // keys mode is NOT set.
            const normal = normal: {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();

                // With the lock held, we must scroll to the bottom.
                // We always scroll to the bottom for these inputs.
                self.scrollToBottom() catch |err| {
                    log.warn("error scrolling to bottom err={}", .{err});
                };

                break :normal !self.io.terminal.modes.get(.cursor_keys);
            };

            if (normal) {
                _ = self.io_thread.mailbox.push(.{
                    .write_stable = ck.normal,
                }, .{ .forever = {} });
            } else {
                _ = self.io_thread.mailbox.push(.{
                    .write_stable = ck.application,
                }, .{ .forever = {} });
            }

            try self.io_thread.wakeup.notify();
        },

        .reset => {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();
            self.renderer_state.terminal.fullReset();
        },

        .copy_to_clipboard => {
            // We can read from the renderer state without holding
            // the lock because only we will write to this field.
            if (self.io.terminal.screen.selection) |sel| {
                const buf = self.io.terminal.screen.selectionString(self.alloc, .{
                    .sel = sel,
                    .trim = self.config.clipboard_trim_trailing_spaces,
                }) catch |err| {
                    log.err("error reading selection string err={}", .{err});
                    return true;
                };
                defer self.alloc.free(buf);

                self.rt_surface.setClipboardString(buf, .standard, false) catch |err| {
                    log.err("error setting clipboard string err={}", .{err});
                    return true;
                };
            }
        },

        .paste_from_clipboard => try self.startClipboardRequest(
            .standard,
            .{ .paste = {} },
        ),

        .paste_from_selection => try self.startClipboardRequest(
            .selection,
            .{ .paste = {} },
        ),

        .increase_font_size => |delta| {
            // Max delta is somewhat arbitrary.
            const clamped_delta = @max(0, @min(255, delta));

            log.debug("increase font size={}", .{clamped_delta});

            var size = self.font_size;
            // Max point size is somewhat arbitrary.
            size.points = @min(size.points + clamped_delta, 255);
            try self.setFontSize(size);
        },

        .decrease_font_size => |delta| {
            // Max delta is somewhat arbitrary.
            const clamped_delta = @max(0, @min(255, delta));

            log.debug("decrease font size={}", .{clamped_delta});

            var size = self.font_size;
            size.points = @max(1, size.points - clamped_delta);
            try self.setFontSize(size);
        },

        .reset_font_size => {
            log.debug("reset font size", .{});

            var size = self.font_size;
            size.points = self.config.original_font_size;
            try self.setFontSize(size);
        },

        .clear_screen => {
            // This is a duplicate of some of the logic in termio.clearScreen
            // but we need to do this here so we can know the answer before
            // we send the message. If the currently active screen is on the
            // alternate screen then clear screen does nothing so we want to
            // return false so the keybind can be unconsumed.
            {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();
                if (self.io.terminal.active_screen == .alternate) return false;
            }

            _ = self.io_thread.mailbox.push(.{
                .clear_screen = .{ .history = true },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_to_top => {
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .top = {} },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_to_bottom => {
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .bottom = {} },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_page_up => {
            const rows: isize = @intCast(self.grid_size.rows);
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .delta = -1 * rows },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_page_down => {
            const rows: isize = @intCast(self.grid_size.rows);
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .delta = rows },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_page_fractional => |fraction| {
            const rows: f32 = @floatFromInt(self.grid_size.rows);
            const delta: isize = @intFromFloat(@floor(fraction * rows));
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .delta = delta },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .scroll_page_lines => |lines| {
            _ = self.io_thread.mailbox.push(.{
                .scroll_viewport = .{ .delta = lines },
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .jump_to_prompt => |delta| {
            _ = self.io_thread.mailbox.push(.{
                .jump_to_prompt = @intCast(delta),
            }, .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .write_scrollback_file => write_scrollback_file: {
            // Create a temporary directory to store our scrollback.
            var tmp_dir = try internal_os.TempDir.init();
            errdefer tmp_dir.deinit();

            // Open our scrollback file
            var file = try tmp_dir.dir.createFile("scrollback", .{});
            defer file.close();
            // Screen.dumpString writes byte-by-byte, so buffer it
            var buf_writer = std.io.bufferedWriter(file.writer());

            // Write the scrollback contents. This requires a lock.
            {
                self.renderer_state.mutex.lock();
                defer self.renderer_state.mutex.unlock();

                // We do not support this for alternate screens
                // because they don't have scrollback anyways.
                if (self.io.terminal.active_screen == .alternate) {
                    tmp_dir.deinit();
                    break :write_scrollback_file;
                }

                // We only dump history if we have history. We still keep
                // the file and write the empty file to the pty so that this
                // command always works on the primary screen.
                const pages = &self.io.terminal.screen.pages;
                if (pages.getBottomRight(.active)) |br| {
                    const tl = pages.getTopLeft(.history);
                    try self.io.terminal.screen.dumpString(
                        buf_writer.writer(),
                        .{ .tl = tl, .br = br, .unwrap = true },
                    );
                }
            }
            try buf_writer.flush();

            // Get the final path
            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try tmp_dir.dir.realpath("scrollback", &path_buf);

            var cmd_buf: [std.fs.MAX_PATH_BYTES + 1024]u8 = undefined;
            const cmd = try std.fmt.bufPrint(&cmd_buf, "\nless --chop-long-lines --RAW-CONTROL-CHARS +G '{s}'; rm -f '{s}'\n?", .{ path, path });

            _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
                self.alloc,
                cmd,
            ), .{ .forever = {} });
            try self.io_thread.wakeup.notify();
        },

        .new_window => try self.app.newWindow(self.rt_app, .{ .parent = self }),

        .new_tab => {
            if (@hasDecl(apprt.Surface, "newTab")) {
                try self.rt_surface.newTab();
            } else log.warn("runtime doesn't implement newTab", .{});
        },

        .previous_tab => {
            if (@hasDecl(apprt.Surface, "hasTabs")) {
                if (!self.rt_surface.hasTabs()) {
                    log.debug("surface has no tabs, ignoring previous_tab binding", .{});
                    return false;
                }
            }

            if (@hasDecl(apprt.Surface, "gotoPreviousTab")) {
                self.rt_surface.gotoPreviousTab();
            } else log.warn("runtime doesn't implement gotoPreviousTab", .{});
        },

        .next_tab => {
            if (@hasDecl(apprt.Surface, "hasTabs")) {
                if (!self.rt_surface.hasTabs()) {
                    log.debug("surface has no tabs, ignoring next_tab binding", .{});
                    return false;
                }
            }

            if (@hasDecl(apprt.Surface, "gotoNextTab")) {
                self.rt_surface.gotoNextTab();
            } else log.warn("runtime doesn't implement gotoNextTab", .{});
        },

        .goto_tab => |n| {
            if (@hasDecl(apprt.Surface, "gotoTab")) {
                self.rt_surface.gotoTab(n);
            } else log.warn("runtime doesn't implement gotoTab", .{});
        },

        .new_split => |direction| {
            if (@hasDecl(apprt.Surface, "newSplit")) {
                try self.rt_surface.newSplit(switch (direction) {
                    .right => .right,
                    .down => .down,
                    .auto => if (self.screen_size.width > self.screen_size.height)
                        .right
                    else
                        .down,
                });
            } else log.warn("runtime doesn't implement newSplit", .{});
        },

        .goto_split => |direction| {
            if (@hasDecl(apprt.Surface, "gotoSplit")) {
                self.rt_surface.gotoSplit(direction);
            } else log.warn("runtime doesn't implement gotoSplit", .{});
        },

        .resize_split => |param| {
            if (@hasDecl(apprt.Surface, "resizeSplit")) {
                const direction = param[0];
                const amount = param[1];
                self.rt_surface.resizeSplit(direction, amount);
            } else log.warn("runtime doesn't implement resizeSplit", .{});
        },

        .equalize_splits => {
            if (@hasDecl(apprt.Surface, "equalizeSplits")) {
                self.rt_surface.equalizeSplits();
            } else log.warn("runtime doesn't implement equalizeSplits", .{});
        },

        .toggle_split_zoom => {
            if (@hasDecl(apprt.Surface, "toggleSplitZoom")) {
                self.rt_surface.toggleSplitZoom();
            } else log.warn("runtime doesn't implement toggleSplitZoom", .{});
        },

        .toggle_fullscreen => {
            if (@hasDecl(apprt.Surface, "toggleFullscreen")) {
                self.rt_surface.toggleFullscreen(self.config.macos_non_native_fullscreen);
            } else log.warn("runtime doesn't implement toggleFullscreen", .{});
        },

        .select_all => {
            const sel = self.io.terminal.screen.selectAll();
            if (sel) |s| {
                try self.setSelection(s);
                try self.queueRender();
            }
        },

        .inspector => |mode| {
            if (@hasDecl(apprt.Surface, "controlInspector")) {
                self.rt_surface.controlInspector(mode);
            } else log.warn("runtime doesn't implement controlInspector", .{});
        },

        .close_surface => self.close(),

        .close_window => try self.app.closeSurface(self),

        .close_all_windows => {
            if (@hasDecl(apprt.Surface, "closeAllWindows")) {
                self.rt_surface.closeAllWindows();
            } else log.warn("runtime doesn't implement closeAllWindows", .{});
        },

        .quit => try self.app.setQuit(),
    }

    return true;
}

/// Returns true if performing the given action result in closing
/// the surface. This is used to determine if our self pointer is
/// still valid after performing some binding action.
fn closingAction(action: input.Binding.Action) bool {
    return switch (action) {
        .close_surface,
        .close_window,
        => true,

        else => false,
    };
}

/// Call this to complete a clipboard request sent to apprt. This should
/// only be called once for each request. The data is immediately copied so
/// it is safe to free the data after this call.
///
/// If `confirmed` is true then any clipboard confirmation prompts are skipped:
///
///   - For "regular" pasting this means that unsafe pastes are allowed. Unsafe
///     data is defined as data that contains newlines, though this definition
///     may change later to detect other scenarios.
///
///   - For OSC 52 reads and writes no prompt is shown to the user if
///     `confirmed` is true.
///
/// If `confirmed` is false then this may return either an UnsafePaste or
/// UnauthorizedPaste error, depending on the type of clipboard request.
pub fn completeClipboardRequest(
    self: *Surface,
    req: apprt.ClipboardRequest,
    data: [:0]const u8,
    confirmed: bool,
) !void {
    switch (req) {
        .paste => try self.completeClipboardPaste(data, confirmed),

        .osc_52_read => |clipboard| try self.completeClipboardReadOSC52(
            data,
            clipboard,
            confirmed,
        ),

        .osc_52_write => |clipboard| try self.rt_surface.setClipboardString(
            data,
            clipboard,
            !confirmed,
        ),
    }
}

/// This starts a clipboard request, with some basic validation. For example,
/// an OSC 52 request is not actually requested if OSC 52 is disabled.
fn startClipboardRequest(
    self: *Surface,
    loc: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !void {
    switch (req) {
        .paste => {}, // always allowed
        .osc_52_read => if (self.config.clipboard_read == .deny) {
            log.info(
                "application attempted to read clipboard, but 'clipboard-read' is set to deny",
                .{},
            );
            return;
        },

        // No clipboard write code paths travel through this function
        .osc_52_write => unreachable,
    }

    try self.rt_surface.clipboardRequest(loc, req);
}

fn completeClipboardPaste(
    self: *Surface,
    data: []const u8,
    allow_unsafe: bool,
) !void {
    if (data.len == 0) return;

    const critical: struct {
        bracketed: bool,
    } = critical: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        const bracketed = self.io.terminal.modes.get(.bracketed_paste);

        // If we have paste protection enabled, we detect unsafe pastes and return
        // an error. The error approach allows apprt to attempt to complete the paste
        // before falling back to requesting confirmation.
        //
        // We do not do this for bracketed pastes because bracketed pastes are
        // by definition safe since they're framed.
        if ((!self.config.clipboard_paste_bracketed_safe or !bracketed) and
            self.config.clipboard_paste_protection and
            !allow_unsafe and
            !terminal.isSafePaste(data))
        {
            log.info("potentially unsafe paste detected, rejecting until confirmation", .{});
            return error.UnsafePaste;
        }

        // With the lock held, we must scroll to the bottom.
        // We always scroll to the bottom for these inputs.
        self.scrollToBottom() catch |err| {
            log.warn("error scrolling to bottom err={}", .{err});
        };

        break :critical .{
            .bracketed = bracketed,
        };
    };

    if (critical.bracketed) {
        // If we're bracketd we write the data as-is to the terminal with
        // the bracketed paste escape codes around it.
        _ = self.io_thread.mailbox.push(.{
            .write_stable = "\x1B[200~",
        }, .{ .forever = {} });
        _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
            self.alloc,
            data,
        ), .{ .forever = {} });
        _ = self.io_thread.mailbox.push(.{
            .write_stable = "\x1B[201~",
        }, .{ .forever = {} });
    } else {
        // If its not bracketed the input bytes are indistinguishable from
        // keystrokes, so we must be careful. For example, we must replace
        // any newlines with '\r'.

        // We just do a heap allocation here because its easy and I don't think
        // worth the optimization of using small messages.
        var buf = try self.alloc.alloc(u8, data.len);
        defer self.alloc.free(buf);

        // This is super, super suboptimal. We can easily make use of SIMD
        // here, but maybe LLVM in release mode is smart enough to figure
        // out something clever. Either way, large non-bracketed pastes are
        // increasingly rare for modern applications.
        var len: usize = 0;
        for (data, 0..) |ch, i| {
            const dch = switch (ch) {
                '\n' => '\r',
                '\r' => if (i + 1 < data.len and data[i + 1] == '\n') continue else ch,
                else => ch,
            };

            buf[len] = dch;
            len += 1;
        }

        _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
            self.alloc,
            buf[0..len],
        ), .{ .forever = {} });
    }

    try self.io_thread.wakeup.notify();
}

fn completeClipboardReadOSC52(
    self: *Surface,
    data: []const u8,
    clipboard_type: apprt.Clipboard,
    confirmed: bool,
) !void {
    // We should never get here if clipboard-read is set to deny
    assert(self.config.clipboard_read != .deny);

    // If clipboard-read is set to ask and we haven't confirmed with the user,
    // do that now
    if (self.config.clipboard_read == .ask and !confirmed) {
        return error.UnauthorizedPaste;
    }

    // Even if the clipboard data is empty we reply, since presumably
    // the client app is expecting a reply. We first allocate our buffer.
    // This must hold the base64 encoded data PLUS the OSC code surrounding it.
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    var buf = try self.alloc.alloc(u8, size + 9); // const for OSC
    defer self.alloc.free(buf);

    const kind: u8 = switch (clipboard_type) {
        .standard => 'c',
        .selection => 's',
        .primary => 'p',
    };

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
    self.io_thread.wakeup.notify() catch {};
}

fn showDesktopNotification(self: *Surface, title: [:0]const u8, body: [:0]const u8) !void {
    if (comptime !@hasDecl(apprt.Surface, "showDesktopNotification")) {
        log.warn("runtime doesn't support desktop notifications", .{});
        return;
    }

    // Wyhash is used to hash the contents of the desktop notification to limit
    // how fast identical notifications can be sent sequentially.
    const hash_algorithm = std.hash.Wyhash;

    const now = try std.time.Instant.now();

    // Set a limit of one desktop notification per second so that the OS
    // doesn't kill us when we run out of resources.
    if (self.app.last_notification_time) |last| {
        if (now.since(last) < 1 * std.time.ns_per_s) {
            log.warn("rate limiting desktop notifications", .{});
            return;
        }
    }

    const new_digest = d: {
        var hash = hash_algorithm.init(0);
        hash.update(title);
        hash.update(body);
        break :d hash.final();
    };

    // Set a limit of one notification per five seconds for desktop
    // notifications with identical content.
    if (self.app.last_notification_time) |last| {
        if (self.app.last_notification_digest == new_digest) {
            if (now.since(last) < 5 * std.time.ns_per_s) {
                log.warn("suppressing identical desktop notification", .{});
                return;
            }
        }
    }

    self.app.last_notification_time = now;
    self.app.last_notification_digest = new_digest;
    try self.rt_surface.showDesktopNotification(title, body);
}

pub const face_ttf = @embedFile("font/res/JetBrainsMono-Regular.ttf");
pub const face_bold_ttf = @embedFile("font/res/JetBrainsMono-Bold.ttf");
pub const face_emoji_ttf = @embedFile("font/res/NotoColorEmoji.ttf");
pub const face_emoji_text_ttf = @embedFile("font/res/NotoEmoji-Regular.ttf");
