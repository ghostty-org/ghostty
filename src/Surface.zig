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
const ziglyph = @import("ziglyph");
const main = @import("main.zig");
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const objc = @import("objc");
const imgui = @import("imgui");
const Pty = @import("pty.zig").Pty;
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const trace = @import("tracy").trace;
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const input = @import("input.zig");
const App = @import("App.zig");
const internal_os = @import("os/main.zig");
const inspector = @import("inspector/main.zig");

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
font_lib: font.Library,
font_group: *font.GroupCache,
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

/// Mouse state for the surface.
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
    /// stable during scrolling relative to the surface.
    left_click_xpos: f64 = 0,
    left_click_ypos: f64 = 0,

    /// The count of clicks to count double and triple clicks and so on.
    /// The left click time was the last time the left click was done. This
    /// is always set on the first left click.
    left_click_count: u8 = 0,
    left_click_time: std.time.Instant = undefined,

    /// The last x/y sent for mouse reports.
    event_point: ?terminal.point.Viewport = null,

    /// Pending scroll amounts for high-precision scrolls
    pending_scroll_x: f64 = 0,
    pending_scroll_y: f64 = 0,

    /// True if the mouse is hidden
    hidden: bool = false,

    /// True if the mouse position is currently over a link.
    over_link: bool = false,

    /// The last x/y in the cursor position for links. We use this to
    /// only process link hover events when the mouse actually moves cells.
    link_point: ?terminal.point.Viewport = null,
};

/// The configuration that a surface has, this is copied from the main
/// Config struct usually to prevent sharing a single value.
const DerivedConfig = struct {
    arena: ArenaAllocator,

    /// For docs for these, see the associated config they are derived from.
    original_font_size: u8,
    keybind: configpkg.Keybinds,
    clipboard_read: configpkg.ClipboardAccess,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_trim_trailing_spaces: bool,
    clipboard_paste_protection: bool,
    clipboard_paste_bracketed_safe: bool,
    copy_on_select: configpkg.CopyOnSelect,
    confirm_close_surface: bool,
    desktop_notifications: bool,
    mouse_interval: u64,
    mouse_hide_while_typing: bool,
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
            .desktop_notifications = config.@"desktop-notifications",
            .mouse_interval = config.@"click-repeat-interval" * 1_000_000, // 500ms
            .mouse_hide_while_typing = config.@"mouse-hide-while-typing",
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

    // Find all the fonts for this surface
    //
    // Future: we can share the font group amongst all surfaces to save
    // some new surface init time and some memory. This will require making
    // thread-safe changes to font structs.
    var font_lib = try font.Library.init();
    errdefer font_lib.deinit();
    var font_group = try alloc.create(font.GroupCache);
    errdefer alloc.destroy(font_group);
    font_group.* = try font.GroupCache.init(alloc, group: {
        var group = try font.Group.init(alloc, font_lib, font_size);
        errdefer group.deinit();

        // Setup our font metric modifiers if we have any.
        group.metric_modifiers = set: {
            var set: font.face.Metrics.ModifierSet = .{};
            errdefer set.deinit(alloc);
            if (config.@"adjust-cell-width") |m| try set.put(alloc, .cell_width, m);
            if (config.@"adjust-cell-height") |m| try set.put(alloc, .cell_height, m);
            if (config.@"adjust-font-baseline") |m| try set.put(alloc, .cell_baseline, m);
            if (config.@"adjust-underline-position") |m| try set.put(alloc, .underline_position, m);
            if (config.@"adjust-underline-thickness") |m| try set.put(alloc, .underline_thickness, m);
            if (config.@"adjust-strikethrough-position") |m| try set.put(alloc, .strikethrough_position, m);
            if (config.@"adjust-strikethrough-thickness") |m| try set.put(alloc, .strikethrough_thickness, m);
            break :set set;
        };

        // If we have codepoint mappings, set those.
        if (config.@"font-codepoint-map".map.list.len > 0) {
            group.codepoint_map = config.@"font-codepoint-map".map;
        }

        // Set our styles
        group.styles.set(.bold, config.@"font-style-bold" != .false);
        group.styles.set(.italic, config.@"font-style-italic" != .false);
        group.styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Search for fonts
        if (font.Discover != void) discover: {
            const disco = try app.fontDiscover() orelse {
                log.warn("font discovery not available, cannot search for fonts", .{});
                break :discover;
            };
            group.discover = disco;

            // A buffer we use to store the font names for logging.
            var name_buf: [256]u8 = undefined;

            if (config.@"font-family") |family| {
                var disco_it = try disco.discover(alloc, .{
                    .family = family,
                    .style = config.@"font-style".nameValue(),
                    .size = font_size.points,
                    .variations = config.@"font-variation".list.items,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font regular: {s}", .{try face.name(&name_buf)});
                    _ = try group.addFace(.regular, .{ .deferred = face });
                } else log.warn("font-family not found: {s}", .{family});
            }

            // In all the styled cases below, we prefer to specify an exact
            // style via the `font-style` configuration. If a style is not
            // specified, we use the discovery mechanism to search for a
            // style category such as bold, italic, etc. We can't specify both
            // because the latter will restrict the search to only that. If
            // a user says `font-style = italic` for the bold face for example,
            // no results would be found if we restrict to ALSO searching for
            // italic.
            if (config.@"font-family-bold") |family| {
                const style = config.@"font-style-bold".nameValue();
                var disco_it = try disco.discover(alloc, .{
                    .family = family,
                    .style = style,
                    .size = font_size.points,
                    .bold = style == null,
                    .variations = config.@"font-variation-bold".list.items,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font bold: {s}", .{try face.name(&name_buf)});
                    _ = try group.addFace(.bold, .{ .deferred = face });
                } else log.warn("font-family-bold not found: {s}", .{family});
            }
            if (config.@"font-family-italic") |family| {
                const style = config.@"font-style-italic".nameValue();
                var disco_it = try disco.discover(alloc, .{
                    .family = family,
                    .style = style,
                    .size = font_size.points,
                    .italic = style == null,
                    .variations = config.@"font-variation-italic".list.items,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font italic: {s}", .{try face.name(&name_buf)});
                    _ = try group.addFace(.italic, .{ .deferred = face });
                } else log.warn("font-family-italic not found: {s}", .{family});
            }
            if (config.@"font-family-bold-italic") |family| {
                const style = config.@"font-style-bold-italic".nameValue();
                var disco_it = try disco.discover(alloc, .{
                    .family = family,
                    .style = style,
                    .size = font_size.points,
                    .bold = style == null,
                    .italic = style == null,
                    .variations = config.@"font-variation-bold-italic".list.items,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font bold+italic: {s}", .{try face.name(&name_buf)});
                    _ = try group.addFace(.bold_italic, .{ .deferred = face });
                } else log.warn("font-family-bold-italic not found: {s}", .{family});
            }
        }

        // Our built-in font will be used as a backup
        _ = try group.addFace(
            .regular,
            .{ .fallback_loaded = try font.Face.init(font_lib, face_ttf, group.faceOptions()) },
        );
        _ = try group.addFace(
            .bold,
            .{ .fallback_loaded = try font.Face.init(font_lib, face_bold_ttf, group.faceOptions()) },
        );

        // Auto-italicize if we have to.
        try group.italicize();

        // Emoji fallback. We don't include this on Mac since Mac is expected
        // to always have the Apple Emoji available on the system.
        if (builtin.os.tag != .macos or font.Discover == void) {
            _ = try group.addFace(
                .regular,
                .{ .fallback_loaded = try font.Face.init(font_lib, face_emoji_ttf, group.faceOptions()) },
            );
            _ = try group.addFace(
                .regular,
                .{ .fallback_loaded = try font.Face.init(font_lib, face_emoji_text_ttf, group.faceOptions()) },
            );
        }

        break :group group;
    });
    errdefer font_group.deinit(alloc);

    log.info("font loading complete, any non-logged faces are using the built-in font", .{});

    // Pre-calculate our initial cell size ourselves.
    const cell_size = try renderer.CellSize.init(alloc, font_group);

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
        .font_group = font_group,
        .padding = .{
            .explicit = padding,
            .balance = config.@"window-padding-balance",
        },
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
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
        .font_lib = font_lib,
        .font_group = font_group,
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
        .config = try DerivedConfig.init(alloc, config),
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

    if (config.title) |title| try rt_surface.setTitle(title);
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

    self.font_group.deinit(self.alloc);
    self.font_lib.deinit();
    self.alloc.destroy(self.font_group);

    if (self.inspector) |v| {
        v.deinit();
        self.alloc.destroy(v);
    }

    self.alloc.destroy(self.renderer_state.mutex);
    self.config.deinit();

    log.info("surface closed addr={x}", .{@intFromPtr(self)});
}

/// Close this surface. This will trigger the runtime to start the
/// close process, which should ultimately deinitialize this surface.
pub fn close(self: *Surface) void {
    self.rt_surface.close(self.needsConfirmQuit());
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

        .cell_size => |size| try self.setCellSize(size),

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
    }
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

    // We need to store our configs in a heap-allocated pointer so that
    // our messages aren't huge.
    var renderer_config_ptr = try self.alloc.create(Renderer.DerivedConfig);
    errdefer self.alloc.destroy(renderer_config_ptr);
    var termio_config_ptr = try self.alloc.create(termio.Impl.DerivedConfig);
    errdefer self.alloc.destroy(termio_config_ptr);

    // Update our derived configurations for the renderer and termio,
    // then send them a message to update.
    renderer_config_ptr.* = try Renderer.DerivedConfig.init(self.alloc, config);
    errdefer renderer_config_ptr.deinit();
    termio_config_ptr.* = try termio.Impl.DerivedConfig.init(self.alloc, config);
    errdefer termio_config_ptr.deinit();
    _ = self.renderer_thread.mailbox.push(.{
        .change_config = .{
            .alloc = self.alloc,
            .ptr = renderer_config_ptr,
        },
    }, .{ .forever = {} });
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
fn setSelection(self: *Surface, sel_: ?terminal.Selection) void {
    const prev_ = self.io.terminal.screen.selection;
    self.io.terminal.screen.selection = sel_;

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
    if (prev_) |prev| if (std.meta.eql(sel, prev)) return;

    // Check if our runtime supports the selection clipboard at all.
    // We can save a lot of work if it doesn't.
    if (@hasDecl(apprt.runtime.Surface, "supportsClipboard")) {
        if (!self.rt_surface.supportsClipboard(clipboard)) {
            return;
        }
    }

    const buf = self.io.terminal.screen.selectionString(
        self.alloc,
        sel,
        self.config.clipboard_trim_trailing_spaces,
    ) catch |err| {
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
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) void {
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
fn queueRender(self: *Surface) !void {
    try self.renderer_thread.wakeup.notify();
}

pub fn sizeCallback(self: *Surface, size: apprt.SurfaceSize) !void {
    const tracy = trace(@src());
    defer tracy.end();

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
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // We always clear our prior preedit
    self.renderer_state.preedit = null;

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
    var preedit: renderer.State.Preedit = .{};
    while (it.nextCodepoint()) |cp| {
        const width = ziglyph.display_width.codePointWidth(cp, .half);

        // I've never seen a preedit text with a zero-width character. In
        // theory its possible but we can't really handle it right now.
        // Let's just ignore it.
        if (width <= 0) continue;

        preedit.codepoints[preedit.len] = .{ .codepoint = cp, .wide = width >= 2 };
        preedit.len += 1;

        // This is a strange edge case. We have a generous buffer for
        // preedit text but if we exceed it, we just truncate.
        if (preedit.len >= preedit.codepoints.len) {
            log.warn("preedit text is longer than our buffer, truncating", .{});
            break;
        }
    }

    // If we have no codepoints, then we're done.
    if (preedit.len == 0) return;

    self.renderer_state.preedit = preedit;
    try self.queueRender();
}

/// Called for any key events. This handles keybindings, encoding and
/// sending to the termianl, etc. The return value is true if the key
/// was handled and false if it was not.
pub fn keyCallback(
    self: *Surface,
    event: input.KeyEvent,
) !bool {
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
                .key = event.key,
            };

            const set = self.config.keybind.set;
            if (set.get(trigger)) |v| break :action .{
                v,
                trigger,
                set.getConsumed(trigger),
            };

            trigger.key = event.physical_key;
            trigger.physical = true;
            if (set.get(trigger)) |v| break :action .{
                v,
                trigger,
                set.getConsumed(trigger),
            };

            break :binding;
        };

        // We only execute the binding on press/repeat but we still consume
        // the key on release so that we don't send any release events.
        log.debug("key event binding consumed={} action={}", .{ consumed, binding_action });
        const performed = if (event.action == .press or event.action == .repeat) press: {
            self.last_binding_trigger = 0;
            break :press try self.performBindingAction(binding_action);
        } else false;

        // If we consume this event, then we are done. If we don't consume
        // it, we processed the action but we still want to process our
        // encodings, too.
        if (consumed and performed) {
            self.last_binding_trigger = binding_trigger.hash();
            if (insp_ev) |*ev| ev.binding = binding_action;
            return true;
        }

        // If we have a previous binding trigger and it matches this one,
        // then we handled the down event so we don't want to send any further
        // events.
        if (self.last_binding_trigger > 0 and
            self.last_binding_trigger == binding_trigger.hash())
        {
            return true;
        }
    }

    // If we allow KAM and KAM is enabled then we do nothing.
    if (self.config.vt_kam_allowed) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        if (self.io.terminal.modes.get(.disable_keyboard)) return true;
    }

    // If this input event has text, then we hide the mouse if configured.
    if (self.config.mouse_hide_while_typing and
        !self.mouse.hidden and
        event.utf8.len > 0)
    {
        self.hideMouse();
    }

    // If our mouse modifiers change, we run a cursor position event.
    // This handles the scenario where URL highlighting should be
    // toggled for example.
    if (!self.mouse.mods.equal(event.mods)) mouse_mods: {
        // We set this to null to force link reprocessing since
        // mod changes can affect link highlighting.
        self.mouse.link_point = null;
        self.mouse.mods = event.mods;
        const pos = self.rt_surface.getCursorPos() catch break :mouse_mods;
        self.cursorPosCallback(pos) catch {};
    }

    // When we are in the middle of a mouse event and we press shift,
    // we change the mouse to a text shape so that selection appears
    // possible.
    if (self.io.terminal.flags.mouse_event != .none and
        event.physical_key == .left_shift or
        event.physical_key == .right_shift)
    {
        switch (event.action) {
            .press => try self.rt_surface.setMouseShape(.text),
            .release => try self.rt_surface.setMouseShape(self.io.terminal.mouse_shape),
            .repeat => {},
        }
    }

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
            .modify_other_keys_state_2 = t.flags.modify_other_keys_2,
            .kitty_flags = t.screen.kitty_keyboard.current(),
        };
    };

    var data: termio.Message.WriteReq.Small.Array = undefined;
    const seq = try enc.encode(&data);
    if (seq.len == 0) return false;

    _ = self.io_thread.mailbox.push(.{
        .write_small = .{
            .data = data,
            .len = @intCast(seq.len),
        },
    }, .{ .forever = {} });
    if (insp_ev) |*ev| {
        ev.pty = self.alloc.dupe(u8, seq) catch |err| err: {
            log.warn("error copying pty data for inspector err={}", .{err});
            break :err "";
        };
    }
    try self.io_thread.wakeup.notify();

    // If our event is any keypress that isn't a modifier and we generated
    // some data to send to the pty, then we move the viewport down to the
    // bottom. We also clear the selection for any key other then modifiers.
    if (!event.key.modifier()) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.setSelection(null);
        try self.io.terminal.scrollViewport(.{ .bottom = {} });
        try self.queueRender();
    }

    return true;
}

/// Sends text as-is to the terminal without triggering any keyboard
/// protocol. This will treat the input text as if it was pasted
/// from the clipboard so the same logic will be applied. Namely,
/// if bracketed mode is on this will do a bracketed paste. Otherwise,
/// this will filter newlines to '\r'.
pub fn textCallback(self: *Surface, text: []const u8) !void {
    try self.completeClipboardPaste(text, true);
}

pub fn focusCallback(self: *Surface, focused: bool) !void {
    // Notify our render thread of the new state
    _ = self.renderer_thread.mailbox.push(.{
        .focus = focused,
    }, .{ .forever = {} });

    // Notify our app if we gained focus.
    if (focused) self.app.focusSurface(self);

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
    const tracy = trace(@src());
    defer tracy.end();

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
            const y_delta_unsigned: usize = @max(@divFloor(self.grid_size.rows, 15), 1);
            const y_delta: isize = y_sign * @as(isize, @intCast(y_delta_unsigned));
            break :y .{ .sign = y_sign, .delta_unsigned = y_delta_unsigned, .delta = y_delta };
        }

        // Precision scrolling is more complicated. We need to maintain state
        // to build up a pending scroll amount if we're only scrolling by a
        // tiny amount so that we can scroll by a full row when we have enough.

        // Add our previously saved pending amount to the offset to get the
        // new offset value.
        //
        // NOTE: we currently multiply by -1 because macOS sends the opposite
        // of what we expect. This is jank we should audit our sign usage and
        // carefully document what we expect so this can work cross platform.
        // Right now this isn't important because macOS is the only high-precision
        // scroller.
        const poff = self.mouse.pending_scroll_y + (yoff * -1);

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
            .sign = if (yoff > 0) 1 else -1,
            .delta_unsigned = @intFromFloat(@abs(amount)),
            .delta = @intFromFloat(amount),
        };
    };

    // For detailed comments see the y calculation above.
    const x: ScrollAmount = if (xoff == 0) .{} else x: {
        if (!scroll_mods.precision) {
            const x_sign: isize = if (xoff < 0) -1 else 1;
            const x_delta_unsigned: usize = 1;
            const x_delta: isize = x_sign * @as(isize, @intCast(x_delta_unsigned));
            break :x .{ .sign = x_sign, .delta_unsigned = x_delta_unsigned, .delta = x_delta };
        }

        const poff = self.mouse.pending_scroll_x + (xoff * -1);
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
            self.setSelection(null);
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
                self.setSelection(null);

                const seq = if (y.delta < 0) "\x1bOA" else "\x1bOB";
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

    self.setFontSize(size);

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

    const tracy = trace(@src());
    defer tracy.end();

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
            const cell = self.renderer_state.terminal.screen.getCell(
                .viewport,
                point.y,
                point.x,
            );

            insp.cell = .{ .selected = .{
                .row = point.y,
                .col = point.x,
                .cell = cell,
            } };
            return;
        }
    }

    // Always record our latest mouse state
    self.mouse.click_state[@intCast(@intFromEnum(button))] = action;
    self.mouse.mods = @bitCast(mods);

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

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
            self.setSelection(null);

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

    // For left button clicks we always record some information for
    // selection/highlighting purposes.
    if (button == .left and action == .press) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        const pos = try self.rt_surface.getCursorPos();

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

        // Store it
        const point = self.posToViewport(pos.x, pos.y);
        self.mouse.left_click_point = point.toScreen(&self.io.terminal.screen);
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
            // First mouse click, clear selection
            1 => if (self.io.terminal.screen.selection != null) {
                self.setSelection(null);
                try self.queueRender();
            },

            // Double click, select the word under our mouse
            2 => {
                const sel_ = self.io.terminal.screen.selectWord(self.mouse.left_click_point);
                if (sel_) |sel| {
                    self.setSelection(sel);
                    try self.queueRender();
                }
            },

            // Triple click, select the line under our mouse
            3 => {
                const sel_ = if (mods.ctrl)
                    self.io.terminal.screen.selectOutput(self.mouse.left_click_point)
                else
                    self.io.terminal.screen.selectLine(self.mouse.left_click_point);
                if (sel_) |sel| {
                    self.setSelection(sel);
                    try self.queueRender();
                }
            },

            // We should be bounded by 1 to 3
            else => unreachable,
        }
    }

    // Middle-click pastes from our selection clipboard
    if (button == .middle and action == .press) {
        if (self.config.copy_on_select != .false) {
            const clipboard: apprt.Clipboard = switch (self.config.copy_on_select) {
                .true => .selection,
                .clipboard => .standard,
                .false => unreachable,
            };

            try self.startClipboardRequest(clipboard, .{ .paste = {} });
        }
    }
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
    const mouse_pt = mouse_pt: {
        const viewport_point = self.posToViewport(pos.x, pos.y);
        break :mouse_pt viewport_point.toScreen(&self.io.terminal.screen);
    };

    // Get the line we're hovering over.
    const line = self.io.terminal.screen.getLine(mouse_pt) orelse
        return null;
    const strmap = try line.stringMap(self.alloc);
    defer strmap.deinit(self.alloc);

    // Go through each link and see if we clicked it
    for (self.config.links) |link| {
        var it = strmap.searchIterator(link.regex);
        while (true) {
            var match = (try it.next()) orelse break;
            defer match.deinit();
            const sel = match.selection();
            if (!sel.contains(mouse_pt)) continue;
            return .{ link, sel };
        }
    }

    return null;
}

/// Attempt to invoke the action of any link that is under the
/// given position.
///
/// Requires the renderer state mutex is held.
fn processLinks(self: *Surface, pos: apprt.CursorPos) !bool {
    const link, const sel = try self.linkAtPos(pos) orelse return false;
    switch (link.action) {
        .open => {
            const str = try self.io.terminal.screen.selectionString(
                self.alloc,
                sel,
                false,
            );
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
    const tracy = trace(@src());
    defer tracy.end();

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
        insp.mouse.last_point = pos_vp.toScreen(&self.io.terminal.screen);
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
    if (self.mouse.click_state[@intFromEnum(input.MouseButton.left)] == .press) {
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
        const screen_point = pos_vp.toScreen(&self.io.terminal.screen);

        // Handle dragging depending on click count
        switch (self.mouse.left_click_count) {
            1 => self.dragLeftClickSingle(screen_point, pos.x),
            2 => self.dragLeftClickDouble(screen_point),
            3 => self.dragLeftClickTriple(screen_point),
            else => unreachable,
        }

        return;
    }

    // Handle link hovering
    if (self.mouse.link_point) |last_vp| {
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
        try self.rt_surface.setMouseShape(.pointer);
        try self.queueRender();
    } else if (over_link) {
        try self.rt_surface.setMouseShape(self.io.terminal.mouse_shape);
        try self.queueRender();
    }
}

// Checks to see if super is on in mods (MacOS) or ctrl. We use this for
// rectangle select along with alt.
//
// Not to be confused with ctrlOrSuper in Config.
fn ctrlOrSuper(mods: input.Mods) bool {
    if (comptime builtin.target.isDarwin()) {
        return mods.super;
    }
    return mods.ctrl;
}

/// Double-click dragging moves the selection one "word" at a time.
fn dragLeftClickDouble(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
) void {
    // Get the word closest to our starting click.
    const word_start = self.io.terminal.screen.selectWordBetween(
        self.mouse.left_click_point,
        screen_point,
    ) orelse {
        self.setSelection(null);
        return;
    };

    // Get the word closest to our current point.
    const word_current = self.io.terminal.screen.selectWordBetween(
        screen_point,
        self.mouse.left_click_point,
    ) orelse {
        self.setSelection(null);
        return;
    };

    // If our current mouse position is before the starting position,
    // then the seletion start is the word nearest our current position.
    if (screen_point.before(self.mouse.left_click_point)) {
        self.setSelection(.{
            .start = word_current.start,
            .end = word_start.end,
            .rectangle = ctrlOrSuper(self.mouse.mods) and self.mouse.mods.alt,
        });
    } else {
        self.setSelection(.{
            .start = word_start.start,
            .end = word_current.end,
            .rectangle = ctrlOrSuper(self.mouse.mods) and self.mouse.mods.alt,
        });
    }
}

/// Triple-click dragging moves the selection one "line" at a time.
fn dragLeftClickTriple(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
) void {
    // Get the word under our current point. If there isn't a word, do nothing.
    const word = self.io.terminal.screen.selectLine(screen_point) orelse return;

    // Get our selection to grow it. If we don't have a selection, start it now.
    // We may not have a selection if we started our dbl-click in an area
    // that had no data, then we dragged our mouse into an area with data.
    var sel = self.io.terminal.screen.selectLine(self.mouse.left_click_point) orelse {
        self.setSelection(word);
        return;
    };

    // Grow our selection
    if (screen_point.before(self.mouse.left_click_point)) {
        sel.start = word.start;
    } else {
        sel.end = word.end;
    }
    self.setSelection(sel);
}

fn dragLeftClickSingle(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
    xpos: f64,
) void {
    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    if (self.io.terminal.screen.selection) |sel| {
        const reset: bool = if (sel.end.before(sel.start))
            sel.start.before(screen_point)
        else
            screen_point.before(sel.start);

        if (reset) self.setSelection(null);
    }

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

    // the boundary point at which we consider selection or non-selection
    const cell_width_f64: f64 = @floatFromInt(self.cell_size.width);
    const cell_xboundary = cell_width_f64 * 0.6;

    // first xpos of the clicked cell adjusted for padding
    const left_padding_f64: f64 = @as(f64, @floatFromInt(self.padding.left));
    const cell_xstart = @as(f64, @floatFromInt(self.mouse.left_click_point.x)) * cell_width_f64;
    const cell_start_xpos = self.mouse.left_click_xpos - cell_xstart - left_padding_f64;

    // If this is the same cell, then we only start the selection if weve
    // moved past the boundary point the opposite direction from where we
    // started.
    if (std.meta.eql(screen_point, self.mouse.left_click_point)) {
        // Ensuring to adjusting the cursor position for padding
        const cell_xpos = xpos - cell_xstart - left_padding_f64;
        const selected: bool = if (cell_start_xpos < cell_xboundary)
            cell_xpos >= cell_xboundary
        else
            cell_xpos < cell_xboundary;

        self.setSelection(if (selected) .{
            .start = screen_point,
            .end = screen_point,
            .rectangle = ctrlOrSuper(self.mouse.mods) and self.mouse.mods.alt,
        } else null);

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (self.io.terminal.screen.selection == null) {
        //   - If we're moving to a point before the start, then we select
        //     the starting cell if we started after the boundary, else
        //     we start selection of the prior cell.
        //   - Inverse logic for a point after the start.
        const click_point = self.mouse.left_click_point;
        const start: terminal.point.ScreenPoint = if (screen_point.before(click_point)) start: {
            if (cell_start_xpos >= cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x > 0) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x - 1,
                } else terminal.point.ScreenPoint{
                    .x = self.io.terminal.screen.cols - 1,
                    .y = click_point.y -| 1,
                };
            }
        } else start: {
            if (cell_start_xpos < cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x < self.io.terminal.screen.cols - 1) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x + 1,
                } else terminal.point.ScreenPoint{
                    .y = click_point.y + 1,
                    .x = 0,
                };
            }
        };

        self.setSelection(.{
            .start = start,
            .end = screen_point,
            .rectangle = ctrlOrSuper(self.mouse.mods) and self.mouse.mods.alt,
        });
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(self.io.terminal.screen.selection != null);
    var sel = self.io.terminal.screen.selection.?;
    sel.end = screen_point;
    self.setSelection(sel);
}

fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Viewport {
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

        .copy_to_clipboard => {
            // We can read from the renderer state without holding
            // the lock because only we will write to this field.
            if (self.io.terminal.screen.selection) |sel| {
                const buf = self.io.terminal.screen.selectionString(
                    self.alloc,
                    sel,
                    self.config.clipboard_trim_trailing_spaces,
                ) catch |err| {
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

        .increase_font_size => |delta| {
            log.debug("increase font size={}", .{delta});

            var size = self.font_size;
            size.points +|= delta;
            self.setFontSize(size);
        },

        .decrease_font_size => |delta| {
            log.debug("decrease font size={}", .{delta});

            var size = self.font_size;
            size.points = @max(1, size.points -| delta);
            self.setFontSize(size);
        },

        .reset_font_size => {
            log.debug("reset font size", .{});

            var size = self.font_size;
            size.points = self.config.original_font_size;
            self.setFontSize(size);
        },

        .clear_screen => {
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

                const history_max = terminal.Screen.RowIndexTag.history.maxLen(
                    &self.io.terminal.screen,
                );

                try self.io.terminal.screen.dumpString(file.writer(), .{
                    .start = .{ .history = 0 },
                    .end = .{ .history = history_max -| 1 },
                    .unwrap = true,
                });
            }

            // Get the final path
            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try tmp_dir.dir.realpath("scrollback", &path_buf);

            _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
                self.alloc,
                path,
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
                try self.rt_surface.newSplit(direction);
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
                self.setSelection(s);
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

        .quit => try self.app.setQuit(),
    }

    return true;
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
    if (@hasDecl(apprt.Surface, "showDesktopNotification")) {
        try self.rt_surface.showDesktopNotification(title, body);
    } else log.warn("runtime doesn't support desktop notifications", .{});
}

pub const face_ttf = @embedFile("font/res/FiraCode-Regular.ttf");
pub const face_bold_ttf = @embedFile("font/res/FiraCode-Bold.ttf");
pub const face_emoji_ttf = @embedFile("font/res/NotoColorEmoji.ttf");
pub const face_emoji_text_ttf = @embedFile("font/res/NotoEmoji-Regular.ttf");
