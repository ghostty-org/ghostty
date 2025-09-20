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
const global_state = &@import("global.zig").state;
const oni = @import("oniguruma");
const crash = @import("crash/main.zig");
const unicode = @import("unicode/main.zig");
const rendererpkg = @import("renderer.zig");
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
const inspectorpkg = @import("inspector/main.zig");
const SurfaceMouse = @import("surface_mouse.zig");

const log = std.log.scoped(.surface);

// The renderer implementation to use.
const Renderer = rendererpkg.Renderer;

/// Minimum window size in cells. This is used to prevent the window from
/// being resized to a size that is too small to be useful. These defaults
/// are chosen to match the default size of Mac's Terminal.app, but is
/// otherwise somewhat arbitrary.
const min_window_width_cells: u32 = 10;
const min_window_height_cells: u32 = 4;

/// Unique ID used to identify this surface for IPC purposes. It is
/// exposed to the commands running in surfaces as the environment variable
/// GHOSTTY_SURFACE.
id: u64,

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
font_metrics: font.Metrics,

/// This keeps track of if the font size was ever modified. If it wasn't,
/// then config reloading will change the font. If it was manually adjusted,
/// we don't change it on config reload since we assume the user wants
/// a specific size.
font_size_adjusted: bool,

/// The renderer for this surface.
renderer: Renderer,

/// The render state
renderer_state: rendererpkg.State,

/// The renderer thread manager
renderer_thread: rendererpkg.Thread,

/// The actual thread
renderer_thr: std.Thread,

/// Mouse state.
mouse: Mouse,

/// Keyboard input state.
keyboard: Keyboard,

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
/// events. This seems unspecified in the spec so for now I'm okay with
/// this. Plus, its only for release events where the key text is far
/// less important.
pressed_key: ?input.KeyEvent = null,

/// The hash value of the last keybinding trigger that we performed. This
/// is only set if the last key input matched a keybinding, consumed it,
/// and performed it. This is used to prevent sending release/repeat events
/// for handled bindings.
last_binding_trigger: u64 = 0,

/// The terminal IO handler.
io: termio.Termio,
io_thread: termio.Thread,
io_thr: std.Thread,

/// Terminal inspector
inspector: ?*inspectorpkg.Inspector = null,

/// All our sizing information.
size: rendererpkg.Size,

/// The configuration derived from the main config. We "derive" it so that
/// we don't have a shared pointer hanging around that we need to worry about
/// the lifetime of. This makes updating config at runtime easier.
config: DerivedConfig,

/// The conditional state of the configuration. This can affect
/// how certain configurations take effect such as light/dark mode.
/// This is managed completely by Ghostty core but an apprt action
/// is sent whenever this changes.
config_conditional_state: configpkg.ConditionalState,

/// This is set to true if our IO thread notifies us our child exited.
/// This is used to determine if we need to confirm, hold open, etc.
child_exited: bool = false,

/// We maintain our focus state and assume we're focused by default.
/// If we're not initially focused then apprts can call focusCallback
/// to let us know.
focused: bool = true,

/// Used to determine whether to continuously scroll.
selection_scroll_active: bool = false,

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
    click_state: [input.MouseButton.max]input.MouseButtonState = @splat(.release),

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

    /// The pressure stage for the mouse. This should always be none if
    /// the mouse is not pressed.
    pressure_stage: input.MousePressureStage = .none,

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

/// Keyboard state for the surface.
pub const Keyboard = struct {
    /// The currently active keybindings for the surface. This is used to
    /// implement sequences: as leader keys are pressed, the active bindings
    /// set is updated to reflect the current leader key sequence. If this is
    /// null then the root bindings are used.
    bindings: ?*const input.Binding.Set = null,

    /// The last handled binding. This is used to prevent encoding release
    /// events for handled bindings. We only need to keep track of one because
    /// at least at the time of writing this, its impossible for two keys of
    /// a combination to be handled by different bindings before the release
    /// of the prior (namely since you can't bind modifier-only).
    last_trigger: ?u64 = null,

    /// The queued keys when we're in the middle of a sequenced binding.
    /// These are flushed when the sequence is completed and unconsumed or
    /// invalid.
    ///
    /// This is naturally bounded due to the configuration maximum
    /// length of a sequence.
    queued: std.ArrayListUnmanaged(termio.Message.WriteReq) = .{},
};

/// The configuration that a surface has, this is copied from the main
/// Config struct usually to prevent sharing a single value.
const DerivedConfig = struct {
    arena: ArenaAllocator,

    /// For docs for these, see the associated config they are derived from.
    original_font_size: f32,
    keybind: configpkg.Keybinds,
    abnormal_command_exit_runtime_ms: u32,
    clipboard_read: configpkg.ClipboardAccess,
    clipboard_write: configpkg.ClipboardAccess,
    clipboard_trim_trailing_spaces: bool,
    clipboard_paste_protection: bool,
    clipboard_paste_bracketed_safe: bool,
    copy_on_select: configpkg.CopyOnSelect,
    right_click_action: configpkg.RightClickAction,
    confirm_close_surface: configpkg.ConfirmCloseSurface,
    cursor_click_to_move: bool,
    desktop_notifications: bool,
    font: font.SharedGridSet.DerivedConfig,
    mouse_interval: u64,
    mouse_hide_while_typing: bool,
    mouse_scroll_multiplier: f64,
    mouse_shift_capture: configpkg.MouseShiftCapture,
    macos_non_native_fullscreen: configpkg.NonNativeFullscreen,
    macos_option_as_alt: ?configpkg.OptionAsAlt,
    selection_clear_on_copy: bool,
    selection_clear_on_typing: bool,
    vt_kam_allowed: bool,
    wait_after_command: bool,
    window_padding_top: u32,
    window_padding_bottom: u32,
    window_padding_left: u32,
    window_padding_right: u32,
    window_padding_balance: bool,
    window_height: u32,
    window_width: u32,
    title: ?[:0]const u8,
    title_report: bool,
    links: []Link,
    link_previews: configpkg.LinkPreviews,
    scroll_to_bottom: configpkg.Config.ScrollToBottom,

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
            .abnormal_command_exit_runtime_ms = config.@"abnormal-command-exit-runtime",
            .clipboard_read = config.@"clipboard-read",
            .clipboard_write = config.@"clipboard-write",
            .clipboard_trim_trailing_spaces = config.@"clipboard-trim-trailing-spaces",
            .clipboard_paste_protection = config.@"clipboard-paste-protection",
            .clipboard_paste_bracketed_safe = config.@"clipboard-paste-bracketed-safe",
            .copy_on_select = config.@"copy-on-select",
            .right_click_action = config.@"right-click-action",
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
            .selection_clear_on_copy = config.@"selection-clear-on-copy",
            .selection_clear_on_typing = config.@"selection-clear-on-typing",
            .vt_kam_allowed = config.@"vt-kam-allowed",
            .wait_after_command = config.@"wait-after-command",
            .window_padding_top = config.@"window-padding-y".top_left,
            .window_padding_bottom = config.@"window-padding-y".bottom_right,
            .window_padding_left = config.@"window-padding-x".top_left,
            .window_padding_right = config.@"window-padding-x".bottom_right,
            .window_padding_balance = config.@"window-padding-balance",
            .window_height = config.@"window-height",
            .window_width = config.@"window-width",
            .title = config.title,
            .title_report = config.@"title-report",
            .links = links,
            .link_previews = config.@"link-previews",
            .scroll_to_bottom = config.@"scroll-to-bottom",

            // Assignments happen sequentially so we have to do this last
            // so that the memory is captured from allocs above.
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        for (self.links) |*link| link.regex.deinit();
        self.arena.deinit();
    }

    fn scaledPadding(self: *const DerivedConfig, x_dpi: f32, y_dpi: f32) rendererpkg.Padding {
        const padding_top: u32 = padding_top: {
            const padding_top: f32 = @floatFromInt(self.window_padding_top);
            break :padding_top @intFromFloat(@floor(padding_top * y_dpi / 72));
        };
        const padding_bottom: u32 = padding_bottom: {
            const padding_bottom: f32 = @floatFromInt(self.window_padding_bottom);
            break :padding_bottom @intFromFloat(@floor(padding_bottom * y_dpi / 72));
        };
        const padding_left: u32 = padding_left: {
            const padding_left: f32 = @floatFromInt(self.window_padding_left);
            break :padding_left @intFromFloat(@floor(padding_left * x_dpi / 72));
        };
        const padding_right: u32 = padding_right: {
            const padding_right: f32 = @floatFromInt(self.window_padding_right);
            break :padding_right @intFromFloat(@floor(padding_right * x_dpi / 72));
        };

        return .{
            .top = padding_top,
            .bottom = padding_bottom,
            .left = padding_left,
            .right = padding_right,
        };
    }
};

/// Create a new surface. This must be called from the main thread. The
/// pointer to the memory for the surface must be provided and must be
/// stable due to interfacing with various callbacks.
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config_original: *const configpkg.Config,
    app: *App,
    rt_app: *apprt.runtime.App,
    rt_surface: *apprt.runtime.Surface,
) !void {
    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    var config_: ?configpkg.Config = config_original.changeConditionalState(
        app.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();

    // We want a config pointer for everything so we get that either
    // based on our conditional state or the original config.
    const config: *const configpkg.Config = if (config_) |*c| config: {
        // We want to preserve our original working directory. We
        // don't need to dupe memory here because termio will derive
        // it. We preserve this so directory inheritance works.
        c.@"working-directory" = config_original.@"working-directory";
        break :config c;
    } else config_original;

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

    // Build our size struct which has all the sizes we need.
    const size: rendererpkg.Size = size: {
        var size: rendererpkg.Size = .{
            .screen = screen: {
                const surface_size = try rt_surface.getSize();
                break :screen .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
            },

            .cell = font_grid.cellSize(),
            .padding = .{},
        };

        const explicit: rendererpkg.Padding = derived_config.scaledPadding(
            x_dpi,
            y_dpi,
        );
        if (derived_config.window_padding_balance) {
            size.balancePadding(explicit);
        } else {
            size.padding = explicit;
        }

        break :size size;
    };

    // Create our terminal grid with the initial size
    const app_mailbox: App.Mailbox = .{ .rt_app = rt_app, .mailbox = &app.mailbox };
    var renderer_impl = try Renderer.init(alloc, .{
        .config = try .init(alloc, config),
        .font_grid = font_grid,
        .size = size,
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        .rt_surface = rt_surface,
        .thread = &self.renderer_thread,
    });
    errdefer renderer_impl.deinit();

    // The mutex used to protect our renderer state.
    const mutex = try alloc.create(std.Thread.Mutex);
    mutex.* = .{};
    errdefer alloc.destroy(mutex);

    // Create the renderer thread
    var render_thread = try rendererpkg.Thread.init(
        alloc,
        config,
        rt_surface,
        &self.renderer,
        &self.renderer_state,
        app_mailbox,
    );
    errdefer render_thread.deinit();

    // Create the IO thread
    var io_thread = try termio.Thread.init(alloc);
    errdefer io_thread.deinit();

    self.* = .{
        .id = std.crypto.random.int(u64),
        .alloc = alloc,
        .app = app,
        .rt_app = rt_app,
        .rt_surface = rt_surface,
        .font_grid_key = font_grid_key,
        .font_size = font_size,
        .font_size_adjusted = false,
        .font_metrics = font_grid.metrics,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .terminal = &self.io.terminal,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .keyboard = .{},
        .io = undefined,
        .io_thread = io_thread,
        .io_thr = undefined,
        .size = size,
        .config = derived_config,

        // Our conditional state is initialized to the app state. This
        // lets us get the most likely correct color theme and so on.
        .config_conditional_state = app.config_conditional_state,
    };

    // The command we're going to execute
    const command: ?configpkg.Command = if (app.first)
        config.@"initial-command" orelse config.command
    else
        config.command;

    // Start our IO implementation
    // This separate block ({}) is important because our errdefers must
    // be scoped here to be valid.
    {
        var env = rt_surface.defaultTermioEnv() catch |err| env: {
            // If an error occurs, we don't want to block surface startup.
            log.warn("error getting env map for surface err={}", .{err});
            break :env internal_os.getEnvMap(alloc) catch
                std.process.EnvMap.init(alloc);
        };
        errdefer env.deinit();

        var buf: [18]u8 = undefined;
        try env.put(
            "GHOSTTY_SURFACE",
            std.fmt.bufPrint(&buf, "0x{x:0>16}", .{self.id}) catch unreachable,
        );

        // Initialize our IO backend
        var io_exec = try termio.Exec.init(alloc, .{
            .command = command,
            .env = env,
            .env_override = config.env,
            .shell_integration = config.@"shell-integration",
            .shell_integration_features = config.@"shell-integration-features",
            .working_directory = config.@"working-directory",
            .resources_dir = global_state.resources_dir.host(),
            .term = config.term,

            // Get the cgroup if we're on linux and have the decl. I'd love
            // to change this from a decl to a surface options struct because
            // then we can do memory management better (don't need to retain
            // the string around).
            .linux_cgroup = if (comptime builtin.os.tag == .linux and
                @hasDecl(apprt.runtime.Surface, "cgroup"))
                rt_surface.cgroup()
            else
                Command.linux_cgroup_default,
        });
        errdefer io_exec.deinit();

        // Initialize our IO mailbox
        var io_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer io_mailbox.deinit(alloc);

        try termio.Termio.init(&self.io, alloc, .{
            .size = size,
            .full_config = config,
            .config = try termio.Termio.DerivedConfig.init(alloc, config),
            .backend = .{ .exec = io_exec },
            .mailbox = io_mailbox,
            .renderer_state = &self.renderer_state,
            .renderer_wakeup = render_thread.wakeup,
            .renderer_mailbox = render_thread.mailbox,
            .surface_mailbox = .{ .surface = self, .app = app_mailbox },
        });
    }
    // Outside the block, IO has now taken ownership of our temporary state
    // so we can just defer this and not the subcomponents.
    errdefer self.io.deinit();

    // Report initial cell size on surface creation
    _ = try rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.cell.width, .height = size.cell.height },
    );

    _ = try rt_app.performAction(
        .{ .surface = self },
        .size_limit,
        .{
            .min_width = size.cell.width * min_window_width_cells,
            .min_height = size.cell.height * min_window_height_cells,
            // No max:
            .max_width = 0,
            .max_height = 0,
        },
    );

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the surface
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    try self.resize(self.size.screen);

    // Give the renderer one more opportunity to finalize any surface
    // setup on the main thread prior to spinning up the rendering thread.
    try renderer_impl.finalizeSurfaceInit(rt_surface);

    // Start our renderer thread
    self.renderer_thr = try std.Thread.spawn(
        .{},
        rendererpkg.Thread.threadMain,
        .{&self.renderer_thread},
    );
    self.renderer_thr.setName("renderer") catch {};

    // Start our IO thread
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{ &self.io_thread, &self.io },
    );
    self.io_thr.setName("io") catch {};

    // Determine our initial window size if configured. We need to do this
    // quite late in the process because our height/width are in grid dimensions,
    // so we need to know our cell sizes first.
    //
    // Note: it is important to do this after the renderer is setup above.
    // This allows the apprt to fully initialize the surface before we
    // start messing with the window.
    self.recomputeInitialSize() catch |err| {
        // We don't treat this as a fatal error because not setting
        // an initial size shouldn't stop our terminal from working.
        log.warn("unable to set initial window size: {}", .{err});
    };

    if (config.title) |title| {
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    } else if ((comptime builtin.os.tag == .linux) and
        config.@"_xdg-terminal-exec")
    xdg: {
        // For xdg-terminal-exec execution we special-case and set the window
        // title to the command being executed. This allows window managers
        // to set custom styling based on the command being executed.
        const v = command orelse break :xdg;
        const title = v.string(alloc) catch |err| {
            log.warn(
                "error copying command for title, title will not be set err={}",
                .{err},
            );
            break :xdg;
        };
        defer alloc.free(title);
        _ = try rt_app.performAction(
            .{ .surface = self },
            .set_title,
            .{ .title = title },
        );
    }

    // We are no longer the first surface
    app.first = false;
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

    // Clean up our keyboard state
    for (self.keyboard.queued.items) |req| req.deinit();
    self.keyboard.queued.deinit(self.alloc);

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
    // Renderers are required to support `drawFrame` being called from
    // the main thread, so that they can update contents during resize.
    try self.renderer.drawFrame(true);
}

/// Activate the inspector. This will begin collecting inspection data.
/// This will not affect the GUI. The GUI must use performAction to
/// show/hide the inspector UI.
pub fn activateInspector(self: *Surface) !void {
    if (self.inspector != null) return;

    // Setup the inspector
    const ptr = try self.alloc.create(inspectorpkg.Inspector);
    errdefer self.alloc.destroy(ptr);
    ptr.* = try inspectorpkg.Inspector.init(self);
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
    self.io.queueMessage(.{ .inspector = true }, .unlocked);
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
    self.io.queueMessage(.{ .inspector = false }, .unlocked);

    // Deinit the inspector
    insp.deinit();
    self.alloc.destroy(insp);
    self.inspector = null;
}

/// True if the surface requires confirmation to quit. This should be called
/// by apprt to determine if the surface should confirm before quitting.
pub fn needsConfirmQuit(self: *Surface) bool {
    // If the child has exited, then our process is certainly not alive.
    // We check this first to avoid the locking overhead below.
    if (self.child_exited) return false;

    // Check the configuration for confirming close behavior.
    return switch (self.config.confirm_close_surface) {
        .always => true,
        .false => false,
        .true => true: {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();
            break :true !self.io.terminal.cursorIsAtPrompt();
        },
    };
}

/// Called from the app thread to handle mailbox messages to our specific
/// surface.
pub fn handleMessage(self: *Surface, msg: Message) !void {
    switch (msg) {
        .change_config => |config| try self.updateConfig(config),

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
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .set_title,
                .{ .title = slice },
            );
        },

        .report_title => |style| report_title: {
            if (!self.config.title_report) {
                log.info("report_title requested, but disabled via config", .{});
                break :report_title;
            }

            const title: ?[:0]const u8 = self.rt_surface.getTitle();
            const data = switch (style) {
                .csi_21_t => try std.fmt.allocPrint(
                    self.alloc,
                    "\x1b]l{s}\x1b\\",
                    .{title orelse ""},
                ),
            };

            // We always use an allocating message because we don't know
            // the length of the title and this isn't a performance critical
            // path.
            self.io.queueMessage(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = data,
                },
            }, .unlocked);
        },

        .color_change => |change| color_change: {
            // Notify our apprt, but don't send a mode 2031 DSR report
            // because VT sequences were used to change the color.
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .color_change,
                .{
                    .kind = switch (change.target) {
                        .palette => |v| @enumFromInt(v),
                        .dynamic => |dyn| switch (dyn) {
                            .foreground => .foreground,
                            .background => .background,
                            .cursor => .cursor,
                            // Unsupported dynamic color change notification type
                            else => break :color_change,
                        },
                        // Special colors aren't supported for change notification
                        .special => break :color_change,
                    },
                    .r = change.color.r,
                    .g = change.color.g,
                    .b = change.color.b,
                },
            );
        },

        .set_mouse_shape => |shape| {
            log.debug("changing mouse shape: {}", .{shape});
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                shape,
            );
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

        .pwd_change => |w| {
            defer w.deinit();

            // We always allocate for this because we need to null-terminate.
            const str = try self.alloc.dupeZ(u8, w.slice());
            defer self.alloc.free(str);

            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .pwd,
                .{ .pwd = str },
            );
        },

        .close => self.close(),

        .child_exited => |v| self.childExited(v),

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

        .report_color_scheme => |force| self.reportColorScheme(force),

        .present_surface => try self.presentSurface(),

        .password_input => |v| try self.passwordInput(v),

        .ring_bell => {
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .ring_bell,
                {},
            ) catch |err| {
                log.warn("apprt failed to ring bell={}", .{err});
            };
        },

        .progress_report => |v| {
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .progress_report,
                v,
            ) catch |err| {
                log.warn("apprt failed to report progress err={}", .{err});
            };
        },

        .selection_scroll_tick => |active| {
            self.selection_scroll_active = active;
            try self.selectionScrollTick();
        },
    }
}

fn selectionScrollTick(self: *Surface) !void {
    // If we're no longer active then we don't do anything.
    if (!self.selection_scroll_active) return;

    // If we don't have a left mouse button down then we
    // don't do anything.
    if (self.mouse.left_click_count == 0) return;

    const pos = try self.rt_surface.getCursorPos();
    const pos_vp = self.posToViewport(pos.x, pos.y);
    const delta: isize = if (pos.y < 0) -1 else 1;

    // We need our locked state for the remainder
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const t: *terminal.Terminal = self.renderer_state.terminal;

    // Scroll the viewport as required
    try t.scrollViewport(.{ .delta = delta });

    // Next, trigger our drag behavior
    const pin = t.screen.pages.pin(.{
        .viewport = .{
            .x = pos_vp.x,
            .y = pos_vp.y,
        },
    }) orelse {
        if (comptime std.debug.runtime_safety) unreachable;
        return;
    };
    try self.dragLeftClickSingle(pin, pos.x);

    // We modified our viewport and selection so we need to queue
    // a render.
    try self.queueRender();
}

fn childExited(self: *Surface, info: apprt.surface.Message.ChildExited) void {
    // Mark our flag that we exited immediately
    self.child_exited = true;

    // If our runtime was below some threshold then we assume that this
    // was an abnormal exit and we show an error message.
    if (info.runtime_ms <= self.config.abnormal_command_exit_runtime_ms) runtime: {
        // On macOS, our exit code detection doesn't work, possibly
        // because of our `login` wrapper. More investigation required.
        if (comptime !builtin.target.os.tag.isDarwin()) {
            // If the exit code is 0 then it was a good exit.
            if (info.exit_code == 0) break :runtime;
        }

        log.warn("abnormal process exit detected, showing error message", .{});

        // Try and show a GUI message. If it returns true, don't do anything else.
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) return;

        // If a native GUI notification was not showm. update our terminal to
        // note the abnormal exit.
        self.childExitedAbnormally(info) catch |err| {
            log.err("error handling abnormal child exit err={}", .{err});
            return;
        };

        return;
    }

    // We output a message so that the user knows whats going on and
    // doesn't think their terminal just froze. We show this unconditionally
    // on close even if `wait_after_command` is false and the surface closes
    // immediately because if a user does an `undo` to restore a closed
    // surface then they will see this message and know the process has
    // completed.
    terminal: {
        // First try and show a native GUI message.
        if (self.rt_app.performAction(
            .{ .surface = self },
            .show_child_exited,
            info,
        ) catch |err| gui: {
            log.err("error trying to show native child exited GUI err={}", .{err});
            break :gui false;
        }) break :terminal;

        // If the native GUI can't be shown, display a text message in the
        // terminal.
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        const t: *terminal.Terminal = self.renderer_state.terminal;
        t.carriageReturn();
        t.linefeed() catch break :terminal;
        t.printString("Process exited. Press any key to close the terminal.") catch
            break :terminal;
        t.modes.set(.cursor_visible, false);

        // We also want to ensure that normal keyboard encoding is on
        // so that we can close the terminal. We close the terminal on
        // any key press that encodes a character.
        t.modes.set(.disable_keyboard, false);
        t.screen.kitty_keyboard.set(.set, .{});
    }

    // Waiting after command we stop here. The terminal is updated, our
    // state is updated, and now its up to the user to decide what to do.
    if (self.config.wait_after_command) return;

    // If we aren't waiting after the command, then we exit immediately
    // with no confirmation.
    self.close();
}

/// Called when the child process exited abnormally.
fn childExitedAbnormally(
    self: *Surface,
    info: apprt.surface.Message.ChildExited,
) !void {
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build up our command for the error message
    const command = try std.mem.join(alloc, " ", switch (self.io.backend) {
        .exec => |*exec| exec.subprocess.args,
    });
    const runtime_str = try std.fmt.allocPrint(alloc, "{d} ms", .{info.runtime_ms});

    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    const t: *terminal.Terminal = self.renderer_state.terminal;

    // No matter what move the cursor back to the column 0.
    t.carriageReturn();

    // Reset styles
    try t.setAttribute(.{ .unset = {} });

    // If there is data in the viewport, we want to scroll down
    // a little bit and write a horizontal rule before writing
    // our message. This lets the use see the error message the
    // command may have output.
    const viewport_str = try t.plainString(alloc);
    if (viewport_str.len > 0) {
        try t.linefeed();
        for (0..t.cols) |_| try t.print(0x2501);
        t.carriageReturn();
        try t.linefeed();
        try t.linefeed();
    }

    // Output our error message
    try t.setAttribute(.{ .@"8_fg" = .bright_red });
    try t.setAttribute(.{ .bold = {} });
    try t.printString("Ghostty failed to launch the requested command:");
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString(command);
    try t.setAttribute(.{ .unset = {} });

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Runtime: ");
    try t.setAttribute(.{ .@"8_fg" = .red });
    try t.printString(runtime_str);
    try t.setAttribute(.{ .unset = {} });

    // We don't print this on macOS because the exit code is always 0
    // due to the way we launch the process.
    if (comptime !builtin.target.os.tag.isDarwin()) {
        const exit_code_str = try std.fmt.allocPrint(alloc, "{d}", .{info.exit_code});
        t.carriageReturn();
        try t.linefeed();
        try t.printString("Exit Code: ");
        try t.setAttribute(.{ .@"8_fg" = .red });
        try t.printString(exit_code_str);
        try t.setAttribute(.{ .unset = {} });
    }

    t.carriageReturn();
    try t.linefeed();
    try t.linefeed();
    try t.printString("Press any key to close the window.");

    // Hide the cursor
    t.modes.set(.cursor_visible, false);
}

/// Called when the terminal detects there is a password input prompt.
fn passwordInput(self: *Surface, v: bool) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If our password input state is unchanged then we don't
        // waste time doing anything more.
        const old = self.io.terminal.flags.password_input;
        if (old == v) return;

        self.io.terminal.flags.password_input = v;
    }

    // Notify our apprt so it can do whatever it wants.
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .secure_input,
        if (v) .on else .off,
    ) catch |err| {
        // We ignore this error because we don't want to fail this
        // entire operation just because the apprt failed to set
        // the secure input state.
        log.warn("apprt failed to set secure input state err={}", .{err});
    };

    try self.queueRender();
}

/// Sends a DSR response for the current color scheme to the pty. If
/// force is false then we only send the response if the terminal mode
/// 2031 is enabled.
fn reportColorScheme(self: *Surface, force: bool) void {
    if (!force) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        if (!self.renderer_state.terminal.modes.get(.report_color_scheme)) {
            return;
        }
    }

    const output = switch (self.config_conditional_state.theme) {
        .light => "\x1B[?997;2n",
        .dark => "\x1B[?997;1n",
    };

    self.io.queueMessage(.{ .write_stable = output }, .unlocked);
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

/// Call this whenever the mouse moves or mods changed. The time
/// at which this is called may matter for the correctness of other
/// mouse events (see cursorPosCallback) but this is shared logic
/// for multiple events.
fn mouseRefreshLinks(
    self: *Surface,
    pos: apprt.CursorPos,
    pos_vp: terminal.point.Coordinate,
    over_link: bool,
) !void {
    // If the position is outside our viewport, do nothing
    if (pos.x < 0 or pos.y < 0) return;

    // Update the last point that we checked for links so we don't
    // recheck if the mouse moves some pixels to the same point.
    self.mouse.link_point = pos_vp;

    // We use an arena for everything below to make things easy to clean up.
    // In the case we don't do any allocs this is very cheap to setup
    // (effectively just struct init).
    var arena = ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Get our link at the current position. This returns null if there
    // isn't a link OR if we shouldn't be showing links for some reason
    // (see further comments for cases).
    const link_: ?apprt.action.MouseOverLink, const preview: bool = link: {
        // If we clicked and our mouse moved cells then we never
        // highlight links until the mouse is unclicked. This follows
        // standard macOS and Linux behavior where a click and drag cancels
        // mouse actions.
        const left_idx = @intFromEnum(input.MouseButton.left);
        if (self.mouse.click_state[left_idx] == .press) click: {
            const pin = self.mouse.left_click_pin orelse break :click;
            const click_pt = self.io.terminal.screen.pages.pointFromPin(
                .viewport,
                pin.*,
            ) orelse break :click;

            if (!click_pt.coord().eql(pos_vp)) {
                log.debug("mouse moved while left click held, ignoring link hover", .{});
                break :link .{ null, false };
            }
        }

        const link = (try self.linkAtPos(pos)) orelse break :link .{ null, false };
        switch (link[0]) {
            .open => {
                const str = try self.io.terminal.screen.selectionString(alloc, .{
                    .sel = link[1],
                    .trim = false,
                });
                break :link .{
                    .{ .url = str },
                    self.config.link_previews == .true,
                };
            },

            ._open_osc8 => {
                // Show the URL in the status bar
                const pin = link[1].start();
                const uri = self.osc8URI(pin) orelse {
                    log.warn("failed to get URI for OSC8 hyperlink", .{});
                    break :link .{ null, false };
                };
                break :link .{
                    .{ .url = try alloc.dupeZ(u8, uri) },
                    self.config.link_previews != .false,
                };
            },
        }
    };

    // If we found a link, setup our internal state and notify the
    // apprt so it can highlight it.
    if (link_) |link| {
        self.renderer_state.mouse.point = pos_vp;
        self.mouse.over_link = true;
        self.renderer_state.terminal.screen.dirty.hyperlink_hover = true;
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            .pointer,
        );

        if (preview) {
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                link,
            );
        }

        try self.queueRender();
        return;
    }

    // No link, if we're previously over a link then we need to clear
    // the over-link apprt state.
    if (over_link) {
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_shape,
            self.io.terminal.mouse_shape,
        );
        _ = try self.rt_app.performAction(
            .{ .surface = self },
            .mouse_over_link,
            .{ .url = "" },
        );
        try self.queueRender();
        return;
    }
}

/// Called when our renderer health state changes.
fn updateRendererHealth(self: *Surface, health: rendererpkg.Health) void {
    log.warn("renderer health status change status={}", .{health});
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .renderer_health,
        health,
    ) catch |err| {
        log.warn("failed to notify app of renderer health change err={}", .{err});
    };
}

/// This should be called anytime `config_conditional_state` changes
/// so that the apprt can reload the configuration.
fn notifyConfigConditionalState(self: *Surface) void {
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .reload_config,
        .{ .soft = true },
    ) catch |err| {
        log.warn("failed to notify app of config state change err={}", .{err});
    };
}

/// Update our configuration at runtime. This can be called by the apprt
/// to set a surface-specific configuration that differs from the app
/// or other surfaces.
pub fn updateConfig(
    self: *Surface,
    original: *const configpkg.Config,
) !void {
    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    var config_: ?configpkg.Config = original.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (config_) |*c| c.deinit();

    // We want a config pointer for everything so we get that either
    // based on our conditional state or the original config.
    const config: *const configpkg.Config = if (config_) |*c| c else original;

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

    // If we are in the middle of a key sequence, clear it.
    self.endKeySequence(.drop, .free);

    // Before sending any other config changes, we give the renderer a new font
    // grid. We could check to see if there was an actual change to the font,
    // but this is easier and pretty rare so it's not a performance concern.
    //
    // (Calling setFontSize builds and sends a new font grid to the renderer.)
    try self.setFontSize(font_size: {
        // If we have manually adjusted the font size, keep it that way.
        if (self.font_size_adjusted) {
            log.info("font size manually adjusted, preserving previous size on config reload", .{});
            break :font_size self.font_size;
        }

        // If we haven't, then we update to the configured font size.
        // This allows config changes to update the font size. We used to
        // never do this but it was a common source of confusion and people
        // assumed that Ghostty was broken! This logic makes more sense.
        var size = self.font_size;
        size.points = std.math.clamp(config.@"font-size", 1.0, 255.0);
        break :font_size size;
    });

    // We need to store our configs in a heap-allocated pointer so that
    // our messages aren't huge.
    var renderer_message = try rendererpkg.Message.initChangeConfig(self.alloc, config);
    errdefer renderer_message.deinit();
    var termio_config_ptr = try self.alloc.create(termio.Termio.DerivedConfig);
    errdefer self.alloc.destroy(termio_config_ptr);
    termio_config_ptr.* = try termio.Termio.DerivedConfig.init(self.alloc, config);
    errdefer termio_config_ptr.deinit();

    _ = self.renderer_thread.mailbox.push(renderer_message, .{ .forever = {} });
    self.io.queueMessage(.{
        .change_config = .{
            .alloc = self.alloc,
            .ptr = termio_config_ptr,
        },
    }, .unlocked);

    // With mailbox messages sent, we have to wake them up so they process it.
    self.queueRender() catch |err| {
        log.warn("failed to notify renderer of config change err={}", .{err});
    };

    // If we have a title set then we update our window to have the
    // newly configured title.
    if (config.title) |title| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .set_title,
        .{ .title = title },
    );

    // Notify the window
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .config_change,
        .{ .config = config },
    );
}

const InitialSizeError = error{
    ContentScaleUnavailable,
    AppActionFailed,
};

/// Recalculate the initial size of the window based on the
/// configuration and invoke the apprt `initial_size` action if
/// necessary.
fn recomputeInitialSize(
    self: *Surface,
) InitialSizeError!void {
    // Both width and height must be set for this to work, as
    // documented on the config options.
    if (self.config.window_height <= 0 or
        self.config.window_width <= 0) return;

    const scale = self.rt_surface.getContentScale() catch
        return error.ContentScaleUnavailable;
    const height = @max(
        self.config.window_height,
        min_window_height_cells,
    ) * self.size.cell.height;
    const width = @max(
        self.config.window_width,
        min_window_width_cells,
    ) * self.size.cell.width;
    const width_f32: f32 = @floatFromInt(width);
    const height_f32: f32 = @floatFromInt(height);

    // The final values are affected by content scale and we need to
    // account for the padding so we get the exact correct grid size.
    const final_width: u32 =
        @as(u32, @intFromFloat(@ceil(width_f32 / scale.x))) +
        self.size.padding.left +
        self.size.padding.right;
    const final_height: u32 =
        @as(u32, @intFromFloat(@ceil(height_f32 / scale.y))) +
        self.size.padding.top +
        self.size.padding.bottom;

    _ = self.rt_app.performAction(
        .{ .surface = self },
        .initial_size,
        .{ .width = final_width, .height = final_height },
    ) catch return error.AppActionFailed;
}

/// Represents text read from the terminal and some metadata about it
/// that is often useful to apprts.
pub const Text = struct {
    /// The text that was read from the terminal.
    text: [:0]const u8,

    /// The viewport information about this text, if it is visible in
    /// the viewport.
    viewport: ?Viewport = null,

    pub const Viewport = struct {
        /// The top-left corner of the selection in pixels within the viewport.
        tl_px_x: f64,
        tl_px_y: f64,

        /// The linear offset of the start of the selection and the length.
        /// This is "linear" in the sense that it is the offset in the
        /// flattened viewport as a single array of text.
        ///
        /// Note: these values are currently wrong if there is a partially
        /// visible selection in the viewport (i.e. the top-left or
        /// bottom-right of the selection is outside the viewport). But the
        /// apprt usecase we have right now doesn't require these to be
        /// correct so... let's fix this later. The wrong values will always
        /// be within the text bounds so we aren't risking an overflow.
        offset_start: u32,
        offset_len: u32,
    };

    pub fn deinit(self: *Text, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

/// Grab the value of text at the given selection point. Note that the
/// selection structure is used as a way to determine the area of the
/// screen to read from, it doesn't have to match the user's current
/// selection state.
///
/// The returned value contains allocated data and must be deinitialized.
pub fn dumpText(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    return try self.dumpTextLocked(alloc, sel);
}

/// Same as `dumpText` but assumes the renderer state mutex is already
/// held.
pub fn dumpTextLocked(
    self: *Surface,
    alloc: Allocator,
    sel: terminal.Selection,
) !Text {
    // Read out the text
    const text = try self.io.terminal.screen.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
    });
    errdefer alloc.free(text);

    // Calculate our viewport info if we can.
    const vp: ?Text.Viewport = viewport: {
        // If our bottom right pin is before the viewport, then we can't
        // possibly have this text be within the viewport.
        const vp_tl_pin = self.io.terminal.screen.pages.getTopLeft(.viewport);
        const br_pin = sel.bottomRight(&self.io.terminal.screen);
        if (br_pin.before(vp_tl_pin)) break :viewport null;

        // If our top-left pin is after the viewport, then we can't possibly
        // have this text be within the viewport.
        const vp_br_pin = self.io.terminal.screen.pages.getBottomRight(.viewport) orelse {
            // I don't think this is possible but I don't want to crash on
            // that assertion so let's just break out...
            log.warn("viewport bottom-right pin not found, bug?", .{});
            break :viewport null;
        };
        const tl_pin = sel.topLeft(&self.io.terminal.screen);
        if (vp_br_pin.before(tl_pin)) break :viewport null;

        // We established that our top-left somewhere before the viewport
        // bottom-right and that our bottom-right is somewhere after
        // the top-left. This means that at least some portion of our
        // selection is within the viewport.

        // Our top-left point. If it doesn't exist in the viewport it must
        // be before and we can return (0,0).
        const tl_pt: terminal.Point = self.io.terminal.screen.pages.pointFromPin(
            .viewport,
            tl_pin,
        ) orelse tl: {
            if (comptime std.debug.runtime_safety) {
                assert(tl_pin.before(vp_tl_pin));
            }

            break :tl .{ .viewport = .{} };
        };

        // Our bottom-right point. If it doesn't exist in the viewport
        // it must be the bottom-right of the viewport.
        const br_pt = self.io.terminal.screen.pages.pointFromPin(
            .viewport,
            br_pin,
        ) orelse br: {
            if (comptime std.debug.runtime_safety) {
                assert(vp_br_pin.before(br_pin));
            }

            break :br self.io.terminal.screen.pages.pointFromPin(
                .viewport,
                vp_br_pin,
            ).?;
        };

        const tl_coord = tl_pt.coord();
        const br_coord = br_pt.coord();

        // Our sizes are all scaled so we need to send the unscaled values back.
        const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };
        const x: f64 = x: {
            // Simple x * cell width gives the left
            var x: f64 = @floatFromInt(tl_coord.x * self.size.cell.width);

            // Add padding
            x += @floatFromInt(self.size.padding.left);

            // Scale
            x /= content_scale.x;

            break :x x;
        };
        const y: f64 = y: {
            // Simple y * cell height gives the top
            var y: f64 = @floatFromInt(tl_coord.y * self.size.cell.height);

            // We want the text baseline
            y += @floatFromInt(self.size.cell.height);
            y -= @floatFromInt(self.font_metrics.cell_baseline);

            // Add padding
            y += @floatFromInt(self.size.padding.top);

            // Scale
            y /= content_scale.y;

            break :y y;
        };

        // Utilize viewport sizing to convert to offsets
        const start = tl_coord.y * self.io.terminal.screen.pages.cols + tl_coord.x;
        const end = br_coord.y * self.io.terminal.screen.pages.cols + br_coord.x;

        break :viewport .{
            .tl_px_x = x,
            .tl_px_y = y,
            .offset_start = start,
            .offset_len = end - start,
        };
    };

    return .{
        .text = text,
        .viewport = vp,
    };
}

/// Returns true if the terminal has a selection.
pub fn hasSelection(self: *const Surface) bool {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    return self.io.terminal.screen.selection != null;
}

/// Returns the selected text. This is allocated.
pub fn selectionString(self: *Surface, alloc: Allocator) !?[:0]const u8 {
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
pub fn pwd(
    self: *const Surface,
    alloc: Allocator,
) Allocator.Error!?[]const u8 {
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
    const preedit_width: usize = if (self.renderer_state.preedit) |preedit| preedit.width() else 0;
    self.renderer_state.mutex.unlock();

    // TODO: need to handle when scrolling and the cursor is not
    // in the visible portion of the screen.

    // Our sizes are all scaled so we need to send the unscaled values back.
    const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };

    const x: f64 = x: {
        // Simple x * cell width gives the top-left corner, then add padding offset
        var x: f64 = @floatFromInt(cursor.x * self.size.cell.width + self.size.padding.left);

        // We want the midpoint
        x += @as(f64, @floatFromInt(self.size.cell.width)) / 2;

        // And scale it
        x /= content_scale.x;

        break :x x;
    };

    const y: f64 = y: {
        // Simple y * cell height gives the top-left corner, then add padding offset
        var y: f64 = @floatFromInt(cursor.y * self.size.cell.height + self.size.padding.top);

        // We want the bottom
        y += @floatFromInt(self.size.cell.height);

        // And scale it
        y /= content_scale.y;

        break :y y;
    };

    // Our height for now is always just the cell height because our preedit
    // rendering only renders in a single line.
    const height: f64 = height: {
        var height: f64 = @floatFromInt(self.size.cell.height);
        height /= content_scale.y;
        break :height height;
    };
    const width: f64 = width: {
        var width: f64 = @floatFromInt(preedit_width * self.size.cell.width);

        // Our max width is the remaining screen width after the cursor.
        // We don't have to deal with wrapping because the preedit doesn't
        // wrap right now.
        const screen_width: f64 = @floatFromInt(self.size.terminal().width);
        const x_offset: f64 = @floatFromInt((cursor.x + 1) * self.size.cell.width);
        const max = screen_width - x_offset;
        width = @min(width, max);

        // Note: we don't apply content scale here because it looks like
        // for some reason in macOS its already scaled. I'm not sure why
        // that is so I'm going to just leave this comment here so its known
        // that I left this out on purpose pending more investigation.

        break :width width;
    };

    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };
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

fn copySelectionToClipboards(
    self: *Surface,
    sel: terminal.Selection,
    clipboards: []const apprt.Clipboard,
) void {
    const buf = self.io.terminal.screen.selectionString(self.alloc, .{
        .sel = sel,
        .trim = self.config.clipboard_trim_trailing_spaces,
    }) catch |err| {
        log.err("error reading selection string err={}", .{err});
        return;
    };
    defer self.alloc.free(buf);

    for (clipboards) |clipboard| self.rt_surface.setClipboardString(
        buf,
        clipboard,
        false,
    ) catch |err| {
        log.err(
            "error setting clipboard string clipboard={} err={}",
            .{ clipboard, err },
        );
    };
}

/// Set the selection contents.
///
/// This must be called with the renderer mutex held.
fn setSelection(self: *Surface, sel_: ?terminal.Selection) !void {
    const prev_ = self.io.terminal.screen.selection;
    try self.io.terminal.screen.select(sel_);

    // If copy on select is false then exit early.
    if (self.config.copy_on_select == .false) return;

    // Set our selection clipboard. If the selection is cleared we do not
    // clear the clipboard. If the selection is set, we only set the clipboard
    // again if it changed, since setting the clipboard can be an expensive
    // operation.
    const sel = sel_ orelse return;
    if (prev_) |prev| if (sel.eql(prev)) return;

    switch (self.config.copy_on_select) {
        .false => unreachable, // handled above with an early exit

        // Both standard and selection clipboards are set.
        .clipboard => {
            self.copySelectionToClipboards(sel, &.{ .standard, .selection });
        },

        // The selection clipboard is set if supported, otherwise the standard.
        .true => {
            const clipboard: apprt.Clipboard = if (self.rt_surface.supportsClipboard(.selection))
                .selection
            else
                .standard;
            self.copySelectionToClipboards(sel, &.{clipboard});
        },
    }
}

/// Change the cell size for the terminal grid. This can happen as
/// a result of changing the font size at runtime.
fn setCellSize(self: *Surface, size: rendererpkg.CellSize) !void {
    // Update our cell size within our size struct
    self.size.cell = size;
    self.balancePaddingIfNeeded();

    // Notify the terminal
    self.io.queueMessage(.{ .resize = self.size }, .unlocked);

    // Update our terminal default size if necessary.
    self.recomputeInitialSize() catch |err| {
        // We don't treat this as a fatal error because not setting
        // an initial size shouldn't stop our terminal from working.
        log.warn("unable to recompute initial window size: {}", .{err});
    };

    // Notify the window
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .cell_size,
        .{ .width = size.width, .height = size.height },
    );
}

/// Change the font size.
///
/// This can only be called from the main thread.
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) !void {
    log.debug("set font size size={}", .{size.points});

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
    self.font_metrics = font_grid.metrics;

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
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    const new_screen_size: rendererpkg.ScreenSize = .{
        .width = size.width,
        .height = size.height,
    };

    // Update our screen size, but only if it actually changed. And if
    // the screen size didn't change, then our grid size could not have
    // changed, so we just return.
    if (self.size.screen.equals(new_screen_size)) return;

    try self.resize(new_screen_size);
}

fn resize(self: *Surface, size: rendererpkg.ScreenSize) !void {
    // Save our screen size
    self.size.screen = size;
    self.balancePaddingIfNeeded();

    // Recalculate our grid size. Because Ghostty supports fluid resizing,
    // its possible the grid doesn't change at all even if the screen size changes.
    // We have to update the IO thread no matter what because we send
    // pixel-level sizing to the subprocess.
    const grid_size = self.size.grid();
    if (grid_size.columns < 5 and (self.size.padding.left > 0 or self.size.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (grid_size.rows < 2 and (self.size.padding.top > 0 or self.size.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }

    // Mail the IO thread
    self.io.queueMessage(.{ .resize = self.size }, .unlocked);
}

/// Recalculate the balanced padding if needed.
fn balancePaddingIfNeeded(self: *Surface) void {
    if (!self.config.window_padding_balance) return;
    const content_scale = try self.rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    self.size.balancePadding(self.config.scaledPadding(x_dpi, y_dpi));
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

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // We clear our selection when ANY OF:
    // 1. We have an existing preedit
    // 2. We have preedit text
    if (self.renderer_state.preedit != null or
        preedit_ != null)
    {
        if (self.config.selection_clear_on_typing) {
            self.setSelection(null) catch {};
        }
    }

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
    const Codepoint = rendererpkg.State.Preedit.Codepoint;
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

/// Returns true if the given key event would trigger a keybinding
/// if it were to be processed. This is useful for determining if
/// a key event should be sent to the terminal or not.
///
/// Note that this function does not check if the binding itself
/// is performable, only if the key event would trigger a binding.
/// If a performable binding is found and the event is not performable,
/// then Ghosty will act as though the binding does not exist.
pub fn keyEventIsBinding(
    self: *Surface,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        .release => return false,
        .press, .repeat => {},
    }

    // Our keybinding set is either our current nested set (for
    // sequences) or the root set.
    const set = self.keyboard.bindings orelse &self.config.keybind.set;

    // log.warn("text keyEventIsBinding event={} match={}", .{ event, set.getEvent(event) != null });

    // If we have a keybinding for this event then we return true.
    return set.getEvent(event) != null;
}

/// Called for any key events. This handles keybindings, encoding and
/// sending to the terminal, etc.
pub fn keyCallback(
    self: *Surface,
    event: input.KeyEvent,
) !InputEffect {
    // log.warn("text keyCallback event={}", .{event});

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Setup our inspector event if we have an inspector.
    var insp_ev: ?inspectorpkg.key.Event = if (self.inspector != null) ev: {
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

    // Handle keybindings first. We need to handle this on all events
    // (press, repeat, release) because a press may perform a binding but
    // a release should not encode if we consumed the press.
    if (try self.maybeHandleBinding(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |v| return v;

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

    // If our mouse modifiers change we may need to change our
    // link highlight state.
    if (!self.mouse.mods.equal(event.mods)) mouse_mods: {
        // Update our modifiers, this will update mouse mods too
        self.modsChanged(event.mods);

        // We only refresh links if
        // 1. mouse reporting is off
        // OR
        // 2. mouse reporting is on and we are not reporting shift to the terminal
        if (self.io.terminal.flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false)))
        {
            // Refresh our link state
            const pos = self.rt_surface.getCursorPos() catch break :mouse_mods;
            self.mouseRefreshLinks(
                pos,
                self.posToViewport(pos.x, pos.y),
                self.mouse.over_link,
            ) catch |err| {
                log.warn("failed to refresh links err={}", .{err});
                break :mouse_mods;
            };
        } else if (self.io.terminal.flags.mouse_event != .none and !self.mouse.mods.shift) {
            // If we have mouse reports on and we don't have shift pressed, we reset state
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }
    }

    // Process the cursor state logic. This will update the cursor shape if
    // needed, depending on the key state.
    if ((SurfaceMouse{
        .physical_key = event.key,
        .mouse_event = self.io.terminal.flags.mouse_event,
        .mouse_shape = self.io.terminal.mouse_shape,
        .mods = self.mouse.mods,
        .over_link = self.mouse.over_link,
        .hidden = self.mouse.hidden,
    }).keyToMouseShape()) |shape| _ = try self.rt_app.performAction(
        .{ .surface = self },
        .mouse_shape,
        shape,
    );

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
            if (prev.key == copy.key) copy.key = .unidentified;
        }

        // If our key is invalid and we have no mods, then we're done!
        // This helps catch the state that we naturally released all keys.
        if (copy.key == .unidentified and copy.mods.empty()) break :event null;

        break :event copy;
    };

    // Encode and send our key. If we didn't encode anything, then we
    // return the effect as ignored.
    if (try self.encodeKey(
        event,
        if (insp_ev) |*ev| ev else null,
    )) |write_req| {
        // If our process is exited and we press a key that results in
        // an encoded value, we close the surface. We want to eventually
        // move this behavior to the apprt probably.
        if (self.child_exited) {
            self.close();
            return .closed;
        }

        errdefer write_req.deinit();
        self.io.queueMessage(switch (write_req) {
            .small => |v| .{ .write_small = v },
            .stable => |v| .{ .write_stable = v },
            .alloc => |v| .{ .write_alloc = v },
        }, .unlocked);
    } else {
        // No valid request means that we didn't encode anything.
        return .ignored;
    }

    // If our event is any keypress that isn't a modifier and we generated
    // some data to send to the pty, then we move the viewport down to the
    // bottom. We also clear the selection for any key other then modifiers.
    if (!event.key.modifier()) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        if (self.config.selection_clear_on_typing or
            event.key == .escape)
        {
            try self.setSelection(null);
        }

        if (self.config.scroll_to_bottom.keystroke) try self.io.terminal.scrollViewport(.bottom);

        try self.queueRender();
    }

    return .consumed;
}

/// Maybe handles a binding for a given event and if so returns the effect.
/// Returns null if the event is not handled in any way and processing should
/// continue.
fn maybeHandleBinding(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.key.Event,
) !?InputEffect {
    switch (event.action) {
        // Release events never trigger a binding but we need to check if
        // we consumed the press event so we don't encode the release.
        .release => {
            if (self.keyboard.last_trigger) |last| {
                if (last == event.bindingHash()) {
                    // We don't reset the last trigger on release because
                    // an apprt may send multiple release events for a single
                    // press event.
                    return .consumed;
                }
            }

            return null;
        },

        // Carry on processing.
        .press, .repeat => {},
    }

    // Find an entry in the keybind set that matches our event.
    const entry: input.Binding.Set.Entry = entry: {
        const set = self.keyboard.bindings orelse &self.config.keybind.set;

        // Get our entry from the set for the given event.
        if (set.getEvent(event)) |v| break :entry v;

        // No entry found. If we're not looking at the root set of the
        // bindings we need to encode everything up to this point and
        // send to the pty.
        //
        // We also ignore modifiers so that nested sequences such as
        // ctrl+a>ctrl+b>c work.
        if (self.keyboard.bindings != null and
            !event.key.modifier())
        {
            // Encode everything up to this point
            self.endKeySequence(.flush, .retain);
        }

        return null;
    };

    // Determine if this entry has an action or if its a leader key.
    const leaf: input.Binding.Set.Leaf = switch (entry.value_ptr.*) {
        .leader => |set| {
            // Setup the next set we'll look at.
            self.keyboard.bindings = set;

            // Store this event so that we can drain and encode on invalid.
            // We don't need to cap this because it is naturally capped by
            // the config validation.
            if (try self.encodeKey(event, insp_ev)) |req| {
                try self.keyboard.queued.append(self.alloc, req);
            }

            // Start or continue our key sequence
            _ = self.rt_app.performAction(
                .{ .surface = self },
                .key_sequence,
                .{ .trigger = entry.key_ptr.* },
            ) catch |err| {
                log.warn(
                    "failed to notify app of key sequence err={}",
                    .{err},
                );
            };

            return .consumed;
        },

        .leaf => |leaf| leaf,
    };
    const action = leaf.action;

    // consumed determines if the input is consumed or if we continue
    // encoding the key (if we have a key to encode).
    const consumed = consumed: {
        // If the consumed flag is explicitly set, then we are consumed.
        if (leaf.flags.consumed) break :consumed true;

        // If the global or all flag is set, we always consume.
        if (leaf.flags.global or leaf.flags.all) break :consumed true;

        break :consumed false;
    };

    // We have an action, so at this point we're handling SOMETHING so
    // we reset the last trigger to null. We only set this if we actually
    // perform an action (below)
    self.keyboard.last_trigger = null;

    // An action also always resets the binding set.
    self.keyboard.bindings = null;

    // Attempt to perform the action
    log.debug("key event binding flags={} action={}", .{
        leaf.flags,
        action,
    });
    const performed = performed: {
        // If this is a global or all action, then we perform it on
        // the app and it applies to every surface.
        if (leaf.flags.global or leaf.flags.all) {
            try self.app.performAllAction(self.rt_app, action);

            // "All" actions are always performed since they are global.
            break :performed true;
        }

        break :performed try self.performBindingAction(action);
    };

    if (performed) {
        // If we performed an action and it was a closing action,
        // our "self" pointer is not safe to use anymore so we need to
        // just exit immediately.
        if (closingAction(action)) {
            log.debug("key binding is a closing binding, halting key event processing", .{});
            return .closed;
        }

        // If our action was "ignore" then we return the special input
        // effect of "ignored".
        if (action == .ignore) return .ignored;
    }

    // If we have the performable flag and the action was not performed,
    // then we act as though a binding didn't exist.
    if (leaf.flags.performable and !performed) {
        // If we're in a sequence, we treat this as if we pressed a key
        // that doesn't exist in the sequence. Reset our sequence and flush
        // any queued events.
        self.endKeySequence(.flush, .retain);

        return null;
    }

    // If we consume this event, then we are done. If we don't consume
    // it, we processed the action but we still want to process our
    // encodings, too.
    if (consumed) {
        // If we had queued events, we deinit them since we consumed
        self.endKeySequence(.drop, .retain);

        // Store our last trigger so we don't encode the release event
        self.keyboard.last_trigger = event.bindingHash();

        if (insp_ev) |ev| ev.binding = action;
        return .consumed;
    }

    // If we didn't perform OR we didn't consume, then we want to
    // encode any queued events for a sequence.
    self.endKeySequence(.flush, .retain);

    return null;
}

const KeySequenceQueued = enum { flush, drop };
const KeySequenceMemory = enum { retain, free };

/// End a key sequence. Safe to call if no key sequence is active.
///
/// Action and mem determine the behavior of the queued inputs up to this
/// point.
fn endKeySequence(
    self: *Surface,
    action: KeySequenceQueued,
    mem: KeySequenceMemory,
) void {
    // Notify apprt key sequence ended
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .key_sequence,
        .end,
    ) catch |err| {
        log.warn(
            "failed to notify app of key sequence end err={}",
            .{err},
        );
    };

    // No matter what we clear our current binding set. This restores
    // the set we look at to the root set.
    self.keyboard.bindings = null;

    if (self.keyboard.queued.items.len > 0) {
        switch (action) {
            .flush => for (self.keyboard.queued.items) |write_req| {
                self.io.queueMessage(switch (write_req) {
                    .small => |v| .{ .write_small = v },
                    .stable => |v| .{ .write_stable = v },
                    .alloc => |v| .{ .write_alloc = v },
                }, .unlocked);
            },

            .drop => for (self.keyboard.queued.items) |req| req.deinit(),
        }

        switch (mem) {
            .free => self.keyboard.queued.clearAndFree(self.alloc),
            .retain => self.keyboard.queued.clearRetainingCapacity(),
        }
    }
}

/// Encodes the key event into a write request. The write request will
/// always copy or allocate so the caller can safely free the event.
fn encodeKey(
    self: *Surface,
    event: input.KeyEvent,
    insp_ev: ?*inspectorpkg.key.Event,
) !?termio.Message.WriteReq {
    // Build up our encoder. Under different modes and
    // inputs there are many keybindings that result in no encoding
    // whatsoever.
    const enc: input.KeyEncoder = enc: {
        const option_as_alt: configpkg.OptionAsAlt = self.config.macos_option_as_alt orelse detect: {
            // Non-macOS doesn't use this value so ignore.
            if (comptime builtin.os.tag != .macos) break :detect .false;

            // If we don't have alt pressed, it doesn't matter what this
            // config is so we can just say "false" and break out and avoid
            // more expensive checks below.
            if (!event.mods.alt) break :detect .false;

            // Alt is pressed, we're on macOS. We break some encapsulation
            // here and assume libghostty for ease...
            break :detect self.rt_app.keyboardLayout().detectOptionAsAlt();
        };

        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        const t = &self.io.terminal;
        break :enc .{
            .event = event,
            .macos_option_as_alt = option_as_alt,
            .alt_esc_prefix = t.modes.get(.alt_esc_prefix),
            .cursor_key_application = t.modes.get(.cursor_keys),
            .keypad_key_application = t.modes.get(.keypad_keys),
            .ignore_keypad_with_numlock = t.modes.get(.ignore_keypad_with_numlock),
            .modify_other_keys_state_2 = t.flags.modify_other_keys_2,
            .kitty_flags = t.screen.kitty_keyboard.current(),
        };
    };

    const write_req: termio.Message.WriteReq = req: {
        // Try to write the input into a small array. This fits almost
        // every scenario. Larger situations can happen due to long
        // pre-edits.
        var data: termio.Message.WriteReq.Small.Array = undefined;
        if (enc.encode(&data)) |seq| {
            // Special-case: we did nothing.
            if (seq.len == 0) return null;

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
    if (insp_ev) |ev| pty: {
        const slice = write_req.slice();
        const copy = self.alloc.alloc(u8, slice.len) catch |err| {
            log.warn("error allocating pty data for inspector err={}", .{err});
            break :pty;
        };
        errdefer self.alloc.free(copy);
        @memcpy(copy, slice);
        ev.pty = copy;
    }

    return write_req;
}

/// Sends text as-is to the terminal without triggering any keyboard
/// protocol. This will treat the input text as if it was pasted
/// from the clipboard so the same logic will be applied. Namely,
/// if bracketed mode is on this will do a bracketed paste. Otherwise,
/// this will filter newlines to '\r'.
pub fn textCallback(self: *Surface, text: []const u8) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    try self.completeClipboardPaste(text, true);
}

/// Callback for when the surface is fully visible or not, regardless
/// of focus state. This is used to pause rendering when the surface
/// is not visible, and also re-render when it becomes visible again.
pub fn occlusionCallback(self: *Surface, visible: bool) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    _ = self.renderer_thread.mailbox.push(.{
        .visible = visible,
    }, .{ .forever = {} });
    try self.queueRender();
}

pub fn focusCallback(self: *Surface, focused: bool) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // If our focus state is the same we do nothing.
    if (self.focused == focused) return;
    self.focused = focused;

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
        if (pressed_key.key != .unidentified) {
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
                    const keyname = comptime keyname: {
                        break :keyname if (std.mem.eql(u8, key, "ctrl"))
                            "control"
                        else if (std.mem.eql(u8, key, "super"))
                            "meta"
                        else
                            key;
                    };
                    pressed_key.key = @field(input.Key, keyname ++ "_" ++ side);
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

    // Whenever our focus changes we unhide the mouse. The mouse will be
    // hidden again if the user starts typing. This helps alleviate some
    // buggy behavior upstream in macOS with the mouse never becoming visible
    // again when tabbing between programs (see #2525).
    self.showMouse();

    // Update the focus state and notify the terminal
    {
        self.renderer_state.mutex.lock();
        self.io.terminal.flags.focused = focused;
        self.renderer_state.mutex.unlock();
        self.io.queueMessage(.{ .focused = focused }, .unlocked);
    }
}

pub fn refreshCallback(self: *Surface) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // The point of this callback is to schedule a render, so do that.
    try self.queueRender();
}

// The amount to scroll. This structure is always normalized so that
// negative is down, left and positive is up, right. Note that INTERNALLY,
// vertical scroll on our terminal uses positive for down (right is not
// supported by our screen since scrollback is only vertical).
const ScrollAmount = struct {
    delta: isize = 0,

    pub fn direction(self: ScrollAmount) enum { down_left, up_right } {
        return if (self.delta < 0) .down_left else .up_right;
    }

    pub fn magnitude(self: ScrollAmount) usize {
        return @abs(self.delta);
    }
};

/// Mouse scroll event. Negative is down, left. Positive is up, right.
///
/// "Natural scrolling" is a macOS term for inverting the scroll direction.
/// This should be handled by the apprt implementation. At this layer,
/// negative is always down, left.
pub fn scrollCallback(
    self: *Surface,
    xoff: f64,
    yoff: f64,
    scroll_mods: input.ScrollMods,
) !void {
    // log.info("SCROLL: xoff={} yoff={} mods={}", .{ xoff, yoff, scroll_mods });

    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    const y: ScrollAmount = if (yoff == 0) .{} else y: {
        // We use cell_size to determine if we have accumulated enough to trigger a scroll
        const cell_size: f64 = @floatFromInt(self.size.cell.height);

        // If we have precision scroll, yoff is the number of pixels to scroll. In non-precision
        // scroll, yoff is the number of wheel ticks. Some mice are capable of reporting fractional
        // wheel ticks, which don't necessarily get reported as precision scrolls. We normalize all
        // scroll events to pixels by multiplying the wheel tick value and the cell size. This means
        // that a wheel tick of 1 results in single scroll event.
        const yoff_adjusted: f64 = if (scroll_mods.precision)
            yoff
        else yoff_adjusted: {
            // Round out the yoff to an absolute minimum of 1. macos tries to
            // simulate precision scrolling with non precision events by
            // ramping up the magnitude of the offsets as it detects faster
            // scrolling. Single click (very slow) scrolls are reported with a
            // magnitude of 0.1 which would normally require a few clicks
            // before we register an actual scroll event (depending on cell
            // height and the mouse_scroll_multiplier setting).
            const yoff_max: f64 = if (yoff > 0)
                @max(yoff, 1)
            else
                @min(yoff, -1);

            break :yoff_adjusted yoff_max * cell_size * self.config.mouse_scroll_multiplier;
        };

        // Add our previously saved pending amount to the offset to get the
        // new offset value. The signs of the pending and yoff should match
        // so that we move further away from zero, but we don't assert
        // this because in theory a user could scroll in the opposite
        // direction and undo a pending scroll.
        const poff: f64 = self.mouse.pending_scroll_y + yoff_adjusted;

        // If the new offset is less than a single unit of scroll, we save
        // the new pending value and do not scroll yet.
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_y = poff;
            break :y .{};
        }

        // We scroll by the number of rows in the offset and save the remainder
        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_y = poff - (amount * cell_size);

        // Round towards zero.
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);

        break :y .{ .delta = delta };
    };

    // For detailed comments see the y calculation above.
    const x: ScrollAmount = if (xoff == 0) .{} else x: {
        if (!scroll_mods.precision) {
            const x_delta_isize: isize = @intFromFloat(@round(xoff));
            break :x .{ .delta = x_delta_isize };
        }

        const poff: f64 = self.mouse.pending_scroll_x + xoff;
        const cell_size: f64 = @floatFromInt(self.size.cell.width);
        if (@abs(poff) < cell_size) {
            self.mouse.pending_scroll_x = poff;
            break :x .{};
        }

        const amount = poff / cell_size;
        assert(@abs(amount) >= 1);
        self.mouse.pending_scroll_x = poff - (amount * cell_size);
        const delta: isize = @intFromFloat(@trunc(amount));
        assert(@abs(delta) >= 1);
        break :x .{ .delta = delta };
    };

    // log.info("SCROLL: delta_y={} delta_x={}", .{ y.delta, x.delta });

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
            if (y.delta != 0) {
                // When we send mouse events as cursor keys we always
                // clear the selection.
                try self.setSelection(null);

                const seq = if (self.io.terminal.modes.get(.cursor_keys)) seq: {
                    // cursor key: application mode
                    break :seq switch (y.direction()) {
                        .up_right => "\x1bOA",
                        .down_left => "\x1bOB",
                    };
                } else seq: {
                    // cursor key: normal mode
                    break :seq switch (y.direction()) {
                        .up_right => "\x1b[A",
                        .down_left => "\x1b[B",
                    };
                };
                for (0..y.magnitude()) |_| {
                    self.io.queueMessage(.{ .write_stable = seq }, .locked);
                }
            }

            return;
        }

        // We have mouse events, are not in an alternate scroll buffer,
        // or have alternate scroll disabled. In this case, we just run
        // the normal logic.

        // If we're scrolling up or down, then send a mouse event.
        if (self.io.terminal.flags.mouse_event != .none) {
            for (0..@abs(y.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                try self.mouseReport(switch (y.direction()) {
                    .up_right => .four,
                    .down_left => .five,
                }, .press, self.mouse.mods, pos);
            }

            for (0..@abs(x.delta)) |_| {
                const pos = try self.rt_surface.getCursorPos();
                try self.mouseReport(switch (x.direction()) {
                    .up_right => .six,
                    .down_left => .seven,
                }, .press, self.mouse.mods, pos);
            }

            // If mouse reporting is on, we do not want to scroll the
            // viewport.
            return;
        }

        if (y.delta != 0) {
            // Modify our viewport, this requires a lock since it affects
            // rendering. We have to switch signs here because our delta
            // is negative down but our viewport is positive down.
            try self.io.terminal.scrollViewport(.{ .delta = y.delta * -1 });
        }
    }

    try self.queueRender();
}

/// This is called when the content scale of the surface changes. The surface
/// can then update any DPI-sensitive state.
pub fn contentScaleCallback(self: *Surface, content_scale: apprt.ContentScale) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

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

    // Update our padding which is dependent on DPI. We only do this for
    // unbalanced padding since balanced padding is not dependent on DPI.
    if (!self.config.window_padding_balance) {
        self.size.padding = self.config.scaledPadding(x_dpi, y_dpi);
    }

    // Force a resize event because the change in padding will affect
    // pixel-level changes to the renderer and viewport.
    try self.resize(self.size.screen);
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
            const max_x: f32 = @floatFromInt(self.size.screen.width);
            const max_y: f32 = @floatFromInt(self.size.screen.height);
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
                .six => 66,
                .seven => 67,
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
            self.io.queueMessage(.{ .write_small = .{
                .data = data,
                .len = 6,
            } }, .locked);
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
            self.io.queueMessage(.{ .write_small = .{
                .data = data,
                .len = @intCast(i),
            } }, .locked);
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
            self.io.queueMessage(.{ .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            } }, .locked);
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
            self.io.queueMessage(.{ .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            } }, .locked);
        },

        .sgr_pixels => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // The position has to be adjusted to the terminal space.
            const coord: rendererpkg.Coordinate.Terminal = (rendererpkg.Coordinate{
                .surface = .{
                    .x = pos.x,
                    .y = pos.y,
                },
            }).convert(.terminal, self.size).terminal;

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                @as(i32, @intFromFloat(@round(coord.x))),
                @as(i32, @intFromFloat(@round(coord.y))),
                final,
            });

            // Ask our IO thread to write the data
            self.io.queueMessage(.{ .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            } }, .locked);
        },
    }
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

    // If the terminal explicitly requests it then we always allow it
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

/// Returns true if the mouse is currently captured by the terminal
/// (i.e. reporting events).
pub fn mouseCaptured(self: *Surface) bool {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    return self.io.terminal.flags.mouse_event != .none;
}

/// Called for mouse button press/release events. This will return true
/// if the mouse event was consumed in some way (i.e. the program is capturing
/// mouse events). If the event was not consumed, then false is returned.
pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) !bool {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

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
                return false;
            };

            insp.cell.select(
                self.alloc,
                p,
                point.x,
                point.y,
            ) catch |err| {
                log.warn("error selecting cell for inspector err={}", .{err});
            };
            return false;
        }
    }

    // Always record our latest mouse state
    self.mouse.click_state[@intCast(@intFromEnum(button))] = action;

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // Update our modifiers if they changed
    self.modsChanged(mods);

    // This is set to true if the terminal is allowed to capture the shift
    // modifier. Note we can do this more efficiently probably with less
    // locking/unlocking but clicking isn't that frequent enough to be a
    // bottleneck.
    const shift_capture = self.mouseShiftCapture(true);

    // Shift-click continues the previous mouse state if we have a selection.
    // cursorPosCallback will also do a mouse report so we don't need to do any
    // of the logic below.
    if (button == .left and action == .press) {
        // We could do all the conditionals in one but I find it more
        // readable as a human to break this one up.
        if (mods.shift and
            self.mouse.left_click_count > 0 and
            !shift_capture)
        extend_selection: {
            // We split this conditional out on its own because this is the
            // only one that requires a renderer mutex grab which is VERY
            // expensive because it could block all our threads.
            if (!self.hasSelection()) break :extend_selection;

            // If we are within the interval that the click would register
            // an increment then we do not extend the selection.
            if (std.time.Instant.now()) |now| {
                const since = now.since(self.mouse.left_click_time);
                if (since <= self.config.mouse_interval) {
                    // Click interval very short, we may be increasing
                    // click counts so we don't extend the selection.
                    break :extend_selection;
                }
            } else |err| {
                // This is a weird behavior, I think either behavior is actually
                // fine. This failure should be exceptionally rare anyways.
                // My thinking here is that we can't be sure if we should extend
                // the selection or not so we just don't.
                log.warn("failed to get time, not extending selection err={}", .{err});
                break :extend_selection;
            }

            const pos = try self.rt_surface.getCursorPos();
            try self.cursorPosCallback(pos, null);
            return true;
        }
    }

    if (button == .left and action == .release) {
        // Stop selection scrolling when releasing the left mouse button
        // but only when selection scrolling is active.
        if (self.selection_scroll_active) {
            self.io.queueMessage(
                .{ .selection_scroll = false },
                .unlocked,
            );
        }

        // The selection clipboard is only updated for left-click drag when
        // the left button is released. This is to avoid the clipboard
        // being updated on every mouse move which would be noisy.
        if (self.config.copy_on_select != .false) {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();
            const prev_ = self.io.terminal.screen.selection;
            if (prev_) |prev| {
                try self.setSelection(terminal.Selection.init(
                    prev.start(),
                    prev.end(),
                    prev.rectangle,
                ));
            }
        }

        // Handle link clicking. We want to do this before we do mouse
        // reporting or any other mouse handling because a successfully
        // clicked link will swallow the event.
        if (self.mouse.over_link) {
            const pos = try self.rt_surface.getCursorPos();
            if (self.processLinks(pos)) |processed| {
                if (processed) return true;
            } else |err| {
                log.warn("error processing links err={}", .{err});
            }
        }
    }

    // Report mouse events if enabled
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        if (self.io.terminal.flags.mouse_event != .none) report: {
            // If we have shift-pressed and we aren't allowed to capture it,
            // then we do not do a mouse report.
            if (mods.shift and !shift_capture) break :report;

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
            return true;
        }
    }

    // For left button click release we check if we are moving our cursor.
    if (button == .left and
        action == .release and
        mods.alt)
    click_move: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we have a selection then we do not do click to move because
        // it means that we moved our cursor while pressing the mouse button.
        if (self.io.terminal.screen.selection != null) break :click_move;

        // Moving always resets the click count so that we don't highlight.
        self.mouse.left_click_count = 0;
        const pin = self.mouse.left_click_pin orelse break :click_move;
        try self.clickMoveCursor(pin.*);
        return true;
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
            const max_distance: f64 = @floatFromInt(self.size.cell.width);
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

        // In all cases below, we set the selection directly rather than use
        // `setSelection` because we want to avoid copying the selection
        // to the selection clipboard. For left mouse clicks we only set
        // the clipboard on release.
        switch (self.mouse.left_click_count) {
            // Single click
            1 => {
                // If we have a selection, clear it. This always happens.
                if (self.io.terminal.screen.selection != null) {
                    try self.io.terminal.screen.select(null);
                    try self.queueRender();
                }
            },

            // Double click, select the word under our mouse
            2 => {
                const sel_ = self.io.terminal.screen.selectWord(pin.*);
                if (sel_) |sel| {
                    try self.io.terminal.screen.select(sel);
                    try self.queueRender();
                }
            },

            // Triple click, select the line under our mouse
            3 => {
                const sel_ = if (mods.ctrlOrSuper())
                    self.io.terminal.screen.selectOutput(pin.*)
                else
                    self.io.terminal.screen.selectLine(.{ .pin = pin.* });
                if (sel_) |sel| {
                    try self.io.terminal.screen.select(sel);
                    try self.queueRender();
                }
            },

            // We should be bounded by 1 to 3
            else => unreachable,
        }
    }

    // Middle-click pastes from our selection clipboard
    if (button == .middle and action == .press) {
        const clipboard: apprt.Clipboard = if (self.rt_surface.supportsClipboard(.selection))
            .selection
        else
            .standard;
        try self.startClipboardRequest(clipboard, .{ .paste = {} });
    }

    // Right-click down selects word for context menus. If the apprt
    // doesn't implement context menus this can be a bit weird but they
    // are supported by our two main apprts so we always do this. If we
    // want to be careful in the future we can add a function to apprts
    // that let's us know.
    if (button == .right and action == .press) sel: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Get our viewport pin
        const screen = &self.renderer_state.terminal.screen;
        const pin = pin: {
            const pos = try self.rt_surface.getCursorPos();
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
                break :sel;
            };

            break :pin pin;
        };

        switch (self.config.right_click_action) {
            .ignore => {},
            .@"context-menu" => {
                // If we already have a selection and the selection contains
                // where we clicked then we don't want to modify the selection.
                if (self.io.terminal.screen.selection) |prev_sel| {
                    if (prev_sel.contains(screen, pin)) break :sel;

                    // The selection doesn't contain our pin, so we create a new
                    // word selection where we clicked.
                }

                const sel = screen.selectWord(pin) orelse break :sel;
                try self.setSelection(sel);
                try self.queueRender();

                // Don't consume so that we show the context menu in apprt.
                return false;
            },
            .copy => {
                if (self.io.terminal.screen.selection) |sel| {
                    self.copySelectionToClipboards(sel, &.{.standard});
                }

                try self.setSelection(null);
                try self.queueRender();
            },
            .@"copy-or-paste" => if (self.io.terminal.screen.selection) |sel| {
                self.copySelectionToClipboards(sel, &.{.standard});
                try self.setSelection(null);
                try self.queueRender();
            } else {
                // Pasting can trigger a lock grab in complete clipboard
                // request so we need to unlock.
                self.renderer_state.mutex.unlock();
                defer self.renderer_state.mutex.lock();
                try self.startClipboardRequest(.standard, .paste);

                // We don't need to clear selection because we didn't have
                // one to begin with.
            },
            .paste => {
                // Before we yield the lock, clear our selection if we have
                // one.
                try self.setSelection(null);
                try self.queueRender();

                // Pasting can trigger a lock grab in complete clipboard
                // request so we need to unlock.
                self.renderer_state.mutex.unlock();
                defer self.renderer_state.mutex.lock();
                try self.startClipboardRequest(.standard, .paste);
            },
        }

        // Consume the event such that the context menu is not displayed.
        return true;
    }

    return false;
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
            self.io.queueMessage(.{ .write_stable = arrow }, .locked);
        }
    }
    if (path.x != 0) {
        const arrow = if (path.x < 0) arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOD" else "\x1b[D";
        } else arrow: {
            break :arrow if (t.modes.get(.cursor_keys)) "\x1bOC" else "\x1b[C";
        };
        for (0..@abs(path.x)) |_| {
            self.io.queueMessage(.{ .write_stable = arrow }, .locked);
        }
    }
}

/// Returns the link at the given cursor position, if any.
///
/// Requires the renderer mutex is held.
fn linkAtPos(
    self: *Surface,
    pos: apprt.CursorPos,
) !?struct {
    input.Link.Action,
    terminal.Selection,
} {
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

    // If we have the proper modifiers set then we can check for OSC8 links.
    if (mouse_mods.equal(input.ctrlOrSuper(.{}))) hyperlink: {
        const rac = mouse_pin.rowAndCell();
        const cell = rac.cell;
        if (!cell.hyperlink) break :hyperlink;
        const sel = terminal.Selection.init(mouse_pin, mouse_pin, false);
        return .{ ._open_osc8, sel };
    }

    // If we have no OSC8 links then we fallback to regex-based URL detection.
    // If we have no configured links we can save a lot of work going forward.
    if (self.config.links.len == 0) return null;

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
            return .{ link.action, sel };
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
    const action, const sel = try self.linkAtPos(pos) orelse return false;
    switch (action) {
        .open => {
            const str = try self.io.terminal.screen.selectionString(self.alloc, .{
                .sel = sel,
                .trim = false,
            });
            defer self.alloc.free(str);
            try self.openUrl(.{ .kind = .unknown, .url = str });
        },

        ._open_osc8 => {
            const uri = self.osc8URI(sel.start()) orelse {
                log.warn("failed to get URI for OSC8 hyperlink", .{});
                return false;
            };
            try self.openUrl(.{ .kind = .unknown, .url = uri });
        },
    }

    return true;
}

fn openUrl(
    self: *Surface,
    action: apprt.action.OpenUrl,
) !void {
    // If the apprt handles it then we're done.
    if (try self.rt_app.performAction(
        .{ .surface = self },
        .open_url,
        action,
    )) return;

    // apprt didn't handle it, fallback to our simple cross-platform
    // URL opener. We log a warning because we want well-behaved
    // apprts to handle this themselves.
    log.warn("apprt did not handle open URL action, falling back to default opener", .{});
    try internal_os.open(
        self.alloc,
        action.kind,
        action.url,
    );
}

/// Return the URI for an OSC8 hyperlink at the given position or null
/// if there is no hyperlink.
fn osc8URI(self: *Surface, pin: terminal.Pin) ?[]const u8 {
    _ = self;
    const page = &pin.node.data;
    const cell = pin.rowAndCell().cell;
    const link_id = page.lookupHyperlink(cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, link_id);
    return entry.uri.offset.ptr(page.memory)[0..entry.uri.len];
}

pub fn mousePressureCallback(
    self: *Surface,
    stage: input.MousePressureStage,
    pressure: f64,
) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // We don't currently use the pressure value for anything. In the
    // future, we could report this to applications using new mouse
    // events or utilize it for some custom UI.
    _ = pressure;

    // If the pressure stage is the same as what we already have do nothing
    if (self.mouse.pressure_stage == stage) return;

    // Update our pressure stage.
    self.mouse.pressure_stage = stage;

    // If our left mouse button is pressed and we're entering a deep
    // click then we want to start a selection. We treat this as a
    // word selection since that is typical macOS behavior.
    const left_idx = @intFromEnum(input.MouseButton.left);
    if (self.mouse.click_state[left_idx] == .press and
        stage == .deep)
    select: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // This should always be set in this state but we don't want
        // to handle state inconsistency here.
        const pin = self.mouse.left_click_pin orelse break :select;
        const sel = self.io.terminal.screen.selectWord(pin.*) orelse break :select;
        try self.io.terminal.screen.select(sel);
        try self.queueRender();
    }
}

/// Cursor position callback.
///
/// Send negative x or y values to indicate the cursor is outside the
/// viewport. The magnitude of the negative values are meaningless;
/// they are only used to indicate the cursor is outside the viewport.
/// It's important to do this to ensure hover states are cleared.
///
/// The mods parameter is optional because some apprts do not provide
/// modifier information on cursor position events. If mods is null then
/// we'll use the last known mods. This is usually accurate since mod events
/// will trigger key press events but on some platforms we don't get them.
/// For example, on macOS, unfocused surfaces don't receive key events but
/// do receive mouse events so we have to rely on updated mods.
pub fn cursorPosCallback(
    self: *Surface,
    pos: apprt.CursorPos,
    mods: ?input.Mods,
) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    // If the position is negative, it is outside our viewport and
    // we need to clear any hover states.
    if (pos.x < 0 or pos.y < 0) {
        // Reset our hyperlink state
        self.mouse.link_point = null;
        if (self.mouse.over_link) {
            self.mouse.over_link = false;
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_shape,
                self.io.terminal.mouse_shape,
            );
            _ = try self.rt_app.performAction(
                .{ .surface = self },
                .mouse_over_link,
                .{ .url = "" },
            );
            try self.queueRender();
        }

        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // No mouse point so we don't highlight links
        self.renderer_state.mouse.point = null;

        // Mark the link's row as dirty, but continue with updating the
        // mouse state below so we can scroll when our position is negative.
        self.renderer_state.terminal.screen.dirty.hyperlink_hover = true;
    }

    // Always show the mouse again if it is hidden
    if (self.mouse.hidden) self.showMouse();

    // Update our modifiers if they changed
    if (mods) |v| self.modsChanged(v);

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

    // Stop selection scrolling when inside the viewport within a 1px buffer
    // for fullscreen windows, but only when selection scrolling is active.
    if (pos.y >= 1 and self.selection_scroll_active) {
        self.io.queueMessage(
            .{ .selection_scroll = false },
            .locked,
        );
    }

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

    // Handle link hovering
    // We refresh links when
    // 1. we were previously over a link
    // OR
    // 2. the cursor position has changed (either we have no previous state, or the state has
    //    changed)
    // AND
    // 1. mouse reporting is off
    // OR
    // 2. mouse reporting is on and we are not reporting shift to the terminal
    if ((over_link or
        self.mouse.link_point == null or
        (self.mouse.link_point != null and !self.mouse.link_point.?.eql(pos_vp))) and
        (self.io.terminal.flags.mouse_event == .none or
            (self.mouse.mods.shift and !self.mouseShiftCapture(false))))
    {
        // If we were previously over a link, we always update. We do this so that if the text
        // changed underneath us, even if the mouse didn't move, we update the URL hints and state
        try self.mouseRefreshLinks(pos, pos_vp, over_link);
    }

    // Do a mouse report
    if (self.io.terminal.flags.mouse_event != .none) report: {
        // Shift overrides mouse "grabbing" in the window, taken from Kitty.
        // This only applies if there is a mouse button pressed so that
        // movement reports are not affected.
        if (self.mouse.mods.shift and !self.mouseShiftCapture(false)) {
            for (self.mouse.click_state) |state| {
                if (state != .release) break :report;
            }
        }

        // We use the first mouse button we find pressed in order to report
        // since the spec (afaict) does not say...
        const button: ?input.MouseButton = button: for (self.mouse.click_state, 0..) |state, i| {
            if (state == .press)
                break :button @enumFromInt(i);
        } else null;

        try self.mouseReport(button, .motion, self.mouse.mods, pos);

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
        // We allow for a 1 pixel buffer at the top and bottom to detect
        // scroll even in full screen windows.
        // Note: one day, we can change this from distance to time based if we want.
        //log.warn("CURSOR POS: {} {}", .{ pos, self.size.screen });
        const max_y: f32 = @floatFromInt(self.size.screen.height);

        // If the mouse is outside the viewport and we have the left
        // mouse button pressed then we need to start the scroll timer.
        if ((pos.y <= 1 or pos.y > max_y - 1) and
            !self.selection_scroll_active)
        {
            self.io.queueMessage(
                .{ .selection_scroll = true },
                .locked,
            );
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
    // then the selection start is the word nearest our current position.
    if (drag_pin.before(click_pin)) {
        try self.io.terminal.screen.select(.init(
            word_current.start(),
            word_start.end(),
            false,
        ));
    } else {
        try self.io.terminal.screen.select(.init(
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

    // Get the line selection under our current drag point. If there isn't a
    // line, do nothing.
    const line = screen.selectLine(.{ .pin = drag_pin }) orelse return;

    // Get the selection under our click point. We first try to trim
    // whitespace if we've selected a word. But if no word exists then
    // we select the blank line.
    const sel_ = screen.selectLine(.{ .pin = click_pin }) orelse
        screen.selectLine(.{ .pin = click_pin, .whitespace = null });

    var sel = sel_ orelse return;
    if (drag_pin.before(click_pin)) {
        sel.startPtr().* = line.start();
    } else {
        sel.endPtr().* = line.end();
    }
    try self.io.terminal.screen.select(sel);
}

fn dragLeftClickSingle(
    self: *Surface,
    drag_pin: terminal.Pin,
    drag_x: f64,
) !void {
    // This logic is in a separate function so that it can be unit tested.
    try self.io.terminal.screen.select(mouseSelection(
        self.mouse.left_click_pin.?.*,
        drag_pin,
        @intFromFloat(@max(0.0, self.mouse.left_click_xpos)),
        @intFromFloat(@max(0.0, drag_x)),
        self.mouse.mods,
        self.size,
    ));
}

/// Calculates the appropriate selection given pins and pixel x positions for
/// the click point and the drag point, as well as mouse mods and screen size.
fn mouseSelection(
    click_pin: terminal.Pin,
    drag_pin: terminal.Pin,
    click_x: u32,
    drag_x: u32,
    mods: input.Mods,
    size: rendererpkg.Size,
) ?terminal.Selection {
    // Explanation:
    //
    // # Normal selections
    //
    // ## Left-to-right selections
    // - The clicked cell is included if it was clicked to the left of its
    //   threshold point and the drag location is right of the threshold point.
    // - The cell under the cursor (the "drag cell") is included if the drag
    //   location is right of its threshold point.
    //
    // ## Right-to-left selections
    // - The clicked cell is included if it was clicked to the right of its
    //   threshold point and the drag location is left of the threshold point.
    // - The cell under the cursor (the "drag cell") is included if the drag
    //   location is left of its threshold point.
    //
    // # Rectangular selections
    //
    // Rectangular selections are handled similarly, except that
    // entire columns are considered rather than individual cells.

    // We only include cells in the selection if the threshold point lies
    // between the start and end points of the selection. A threshold of
    // 60% of the cell width was chosen empirically because it felt good.
    const threshold_point: u32 = @intFromFloat(@round(
        @as(f64, @floatFromInt(size.cell.width)) * 0.6,
    ));

    // We use this to clamp the pixel positions below.
    const max_x = size.grid().columns * size.cell.width - 1;

    // We need to know how far across in the cell the drag pos is, so
    // we subtract the padding and then take it modulo the cell width.
    const drag_x_frac = @min(max_x, drag_x -| size.padding.left) % size.cell.width;

    // We figure out the fractional part of the click x position similarly.
    const click_x_frac = @min(max_x, click_x -| size.padding.left) % size.cell.width;

    // Whether or not this is a rectangular selection.
    const rectangle_selection = SurfaceMouse.isRectangleSelectState(mods);

    // Whether the click pin and drag pin are equal.
    const same_pin = drag_pin.eql(click_pin);

    // Whether or not the end point of our selection is before the start point.
    const end_before_start = ebs: {
        if (same_pin) {
            break :ebs drag_x_frac < click_x_frac;
        }

        // Special handling for rectangular selections, we only use x position.
        if (rectangle_selection) {
            break :ebs switch (std.math.order(drag_pin.x, click_pin.x)) {
                .eq => drag_x_frac < click_x_frac,
                .lt => true,
                .gt => false,
            };
        }

        break :ebs drag_pin.before(click_pin);
    };

    // Whether or not the the click pin cell
    // should be included in the selection.
    const include_click_cell = if (end_before_start)
        click_x_frac >= threshold_point
    else
        click_x_frac < threshold_point;

    // Whether or not the the drag pin cell
    // should be included in the selection.
    const include_drag_cell = if (end_before_start)
        drag_x_frac < threshold_point
    else
        drag_x_frac >= threshold_point;

    // If the click cell should be included in the selection then it's the
    // start, otherwise we get the previous or next cell to it depending on
    // the type and direction of the selection.
    const start_pin =
        if (include_click_cell)
            click_pin
        else if (end_before_start)
            if (rectangle_selection)
                click_pin.leftClamp(1)
            else
                click_pin.leftWrap(1) orelse click_pin
        else if (rectangle_selection)
            click_pin.rightClamp(1)
        else
            click_pin.rightWrap(1) orelse click_pin;

    // Likewise for the end pin with the drag cell.
    const end_pin =
        if (include_drag_cell)
            drag_pin
        else if (end_before_start)
            if (rectangle_selection)
                drag_pin.rightClamp(1)
            else
                drag_pin.rightWrap(1) orelse drag_pin
        else if (rectangle_selection)
            drag_pin.leftClamp(1)
        else
            drag_pin.leftWrap(1) orelse drag_pin;

    // If the click cell is the same as the drag cell and the click cell
    // shouldn't be included, or if the cells are adjacent such that the
    // start or end pin becomes the other cell, and that cell should not
    // be included, then we have no selection, so we set it to null.
    //
    // If in rectangular selection mode, we compare columns as well.
    //
    // TODO(qwerasd): this can/should probably be refactored, it's a bit
    //                repetitive and does excess work in rectangle mode.
    if ((!include_click_cell and same_pin) or
        (!include_click_cell and rectangle_selection and click_pin.x == drag_pin.x) or
        (!include_click_cell and end_pin.eql(click_pin)) or
        (!include_click_cell and rectangle_selection and end_pin.x == click_pin.x) or
        (!include_drag_cell and start_pin.eql(drag_pin)) or
        (!include_drag_cell and rectangle_selection and start_pin.x == drag_pin.x))
    {
        return null;
    }

    // TODO: Clamp selection to the screen area, don't
    //       let it extend past the last written row.

    return .init(
        start_pin,
        end_pin,
        rectangle_selection,
    );
}

/// Call to notify Ghostty that the color scheme for the terminal has
/// changed.
pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) !void {
    // Crash metadata in case we crash in here
    crash.sentry.thread_state = self.crashThreadState();
    defer crash.sentry.thread_state = null;

    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;
    self.notifyConfigConditionalState();

    // If mode 2031 is on, then we report the change live.
    self.reportColorScheme(false);
}

pub fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Coordinate {
    // Get our grid cell
    const coord: rendererpkg.Coordinate = .{ .surface = .{ .x = xpos, .y = ypos } };
    const grid = coord.convert(.grid, self.size).grid;
    return .{ .x = grid.x, .y = grid.y };
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
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .hidden,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
}

fn showMouse(self: *Surface) void {
    if (!self.mouse.hidden) return;
    self.mouse.hidden = false;
    _ = self.rt_app.performAction(
        .{ .surface = self },
        .mouse_visibility,
        .visible,
    ) catch |err| {
        log.warn("apprt failed to set mouse visibility err={}", .{err});
    };
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
    // Forward app-scoped actions to the app. Some app-scoped actions are
    // special-cased here because they do some special things when performed
    // from the surface.
    if (action.scoped(.app)) |app_action| {
        switch (app_action) {
            .new_window => try self.app.newWindow(
                self.rt_app,
                .{ .parent = self },
            ),

            // Undo and redo both support both surface and app targeting.
            // If we are triggering on a surface then we perform the
            // action with the surface target.
            .undo => return try self.rt_app.performAction(
                .{ .surface = self },
                .undo,
                {},
            ),

            .redo => return try self.rt_app.performAction(
                .{ .surface = self },
                .redo,
                {},
            ),

            else => try self.app.performAction(
                self.rt_app,
                action.scoped(.app).?,
            ),
        }
        return true;
    }

    switch (action.scoped(.surface).?) {
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
            self.io.queueMessage(try termio.Message.writeReq(
                self.alloc,
                full_data,
            ), .unlocked);

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
            self.io.queueMessage(try termio.Message.writeReq(
                self.alloc,
                text,
            ), .unlocked);

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
                self.io.queueMessage(.{ .write_stable = ck.normal }, .unlocked);
            } else {
                self.io.queueMessage(.{ .write_stable = ck.application }, .unlocked);
            }
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

                // Clear the selection if configured to do so.
                if (self.config.selection_clear_on_copy) {
                    if (self.setSelection(null)) {
                        self.queueRender() catch |err| {
                            log.warn("failed to queue render after clear selection err={}", .{err});
                        };
                    } else |err| {
                        log.warn("failed to clear selection after copy err={}", .{err});
                    }
                }

                return true;
            }

            return false;
        },

        .copy_url_to_clipboard => {
            // If the mouse isn't over a link, nothing we can do.
            if (!self.mouse.over_link) return false;

            const pos = try self.rt_surface.getCursorPos();
            if (try self.linkAtPos(pos)) |link_info| {
                const url_text = switch (link_info[0]) {
                    .open => url_text: {
                        // For regex links, get the text from selection
                        break :url_text (self.io.terminal.screen.selectionString(self.alloc, .{
                            .sel = link_info[1],
                            .trim = self.config.clipboard_trim_trailing_spaces,
                        })) catch |err| {
                            log.err("error reading url string err={}", .{err});
                            return false;
                        };
                    },

                    ._open_osc8 => url_text: {
                        // For OSC8 links, get the URI directly from hyperlink data
                        const uri = self.osc8URI(link_info[1].start()) orelse {
                            log.warn("failed to get URI for OSC8 hyperlink", .{});
                            return false;
                        };
                        break :url_text try self.alloc.dupeZ(u8, uri);
                    },
                };
                defer self.alloc.free(url_text);

                self.rt_surface.setClipboardString(url_text, .standard, false) catch |err| {
                    log.err("error copying url to clipboard err={}", .{err});
                    return false;
                };

                return true;
            }

            return false;
        },

        .copy_title_to_clipboard => {
            const title = self.rt_surface.getTitle() orelse return false;
            if (title.len == 0) return false;

            self.rt_surface.setClipboardString(title, .standard, false) catch |err| {
                log.err("error copying title to clipboard err={}", .{err});
                return true;
            };

            return true;
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

            // Max point size is somewhat arbitrary.
            var size = self.font_size;
            size.points = @min(size.points + clamped_delta, 255);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .decrease_font_size => |delta| {
            // Max delta is somewhat arbitrary.
            const clamped_delta = @max(0, @min(255, delta));

            log.debug("decrease font size={}", .{clamped_delta});

            var size = self.font_size;
            size.points = @max(1, size.points - clamped_delta);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .reset_font_size => {
            log.debug("reset font size", .{});

            var size = self.font_size;
            size.points = self.config.original_font_size;
            try self.setFontSize(size);

            // Reset font size also resets the manual adjustment state
            self.font_size_adjusted = false;
        },

        .set_font_size => |points| {
            log.debug("set font size={d}", .{points});

            var size = self.font_size;
            size.points = std.math.clamp(points, 1.0, 255.0);
            try self.setFontSize(size);

            // Mark that we manually adjusted the font size
            self.font_size_adjusted = true;
        },

        .prompt_surface_title => return try self.rt_app.performAction(
            .{ .surface = self },
            .prompt_title,
            {},
        ),

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

            self.io.queueMessage(.{
                .clear_screen = .{ .history = true },
            }, .unlocked);
        },

        .scroll_to_top => {
            self.io.queueMessage(.{
                .scroll_viewport = .{ .top = {} },
            }, .unlocked);
        },

        .scroll_to_bottom => {
            self.io.queueMessage(.{
                .scroll_viewport = .{ .bottom = {} },
            }, .unlocked);
        },

        .scroll_to_selection => {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();
            const sel = self.io.terminal.screen.selection orelse return false;
            const tl = sel.topLeft(&self.io.terminal.screen);
            self.io.terminal.screen.scroll(.{ .pin = tl });
        },

        .scroll_page_up => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.io.queueMessage(.{
                .scroll_viewport = .{ .delta = -1 * rows },
            }, .unlocked);
        },

        .scroll_page_down => {
            const rows: isize = @intCast(self.size.grid().rows);
            self.io.queueMessage(.{
                .scroll_viewport = .{ .delta = rows },
            }, .unlocked);
        },

        .scroll_page_fractional => |fraction| {
            const rows: f32 = @floatFromInt(self.size.grid().rows);
            const delta: isize = @intFromFloat(@trunc(fraction * rows));
            self.io.queueMessage(.{
                .scroll_viewport = .{ .delta = delta },
            }, .unlocked);
        },

        .scroll_page_lines => |lines| {
            self.io.queueMessage(.{
                .scroll_viewport = .{ .delta = lines },
            }, .unlocked);
        },

        .jump_to_prompt => |delta| {
            self.io.queueMessage(.{
                .jump_to_prompt = @intCast(delta),
            }, .unlocked);
        },

        .write_screen_file => |v| try self.writeScreenFile(
            .screen,
            v,
        ),

        .write_scrollback_file => |v| try self.writeScreenFile(
            .history,
            v,
        ),

        .write_selection_file => |v| try self.writeScreenFile(
            .selection,
            v,
        ),

        .new_tab => return try self.rt_app.performAction(
            .{ .surface = self },
            .new_tab,
            {},
        ),

        .close_tab => |v| return try self.rt_app.performAction(
            .{ .surface = self },
            .close_tab,
            switch (v) {
                .this => .this,
                .other => .other,
            },
        ),

        inline .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        => |v, tag| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_tab,
            switch (tag) {
                .previous_tab => .previous,
                .next_tab => .next,
                .last_tab => .last,
                .goto_tab => @enumFromInt(v),
                else => comptime unreachable,
            },
        ),

        .move_tab => |position| return try self.rt_app.performAction(
            .{ .surface = self },
            .move_tab,
            .{ .amount = position },
        ),

        .new_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .new_split,
            switch (direction) {
                .right => .right,
                .left => .left,
                .down => .down,
                .up => .up,
                .auto => if (self.size.screen.width > self.size.screen.height)
                    .right
                else
                    .down,
            },
        ),

        .goto_split => |direction| return try self.rt_app.performAction(
            .{ .surface = self },
            .goto_split,
            switch (direction) {
                inline else => |tag| @field(
                    apprt.action.GotoSplit,
                    @tagName(tag),
                ),
            },
        ),

        .resize_split => |value| return try self.rt_app.performAction(
            .{ .surface = self },
            .resize_split,
            .{
                .amount = value[1],
                .direction = switch (value[0]) {
                    inline else => |tag| @field(
                        apprt.action.ResizeSplit.Direction,
                        @tagName(tag),
                    ),
                },
            },
        ),

        .equalize_splits => return try self.rt_app.performAction(
            .{ .surface = self },
            .equalize_splits,
            {},
        ),

        .toggle_split_zoom => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_split_zoom,
            {},
        ),

        .reset_window_size => return try self.rt_app.performAction(
            .{ .surface = self },
            .reset_window_size,
            {},
        ),

        .toggle_maximize => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_maximize,
            {},
        ),

        .toggle_fullscreen => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_fullscreen,
            switch (self.config.macos_non_native_fullscreen) {
                .false => .native,
                .true => .macos_non_native,
                .@"visible-menu" => .macos_non_native_visible_menu,
                .@"padded-notch" => .macos_non_native_padded_notch,
            },
        ),

        .toggle_window_decorations => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_window_decorations,
            {},
        ),

        .toggle_tab_overview => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_tab_overview,
            {},
        ),

        .toggle_window_float_on_top => return try self.rt_app.performAction(
            .{ .surface = self },
            .float_window,
            .toggle,
        ),

        .toggle_secure_input => return try self.rt_app.performAction(
            .{ .surface = self },
            .secure_input,
            .toggle,
        ),

        .toggle_command_palette => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_command_palette,
            {},
        ),

        .show_on_screen_keyboard => return try self.rt_app.performAction(
            .{ .surface = self },
            .show_on_screen_keyboard,
            {},
        ),

        .select_all => {
            const sel = self.io.terminal.screen.selectAll();
            if (sel) |s| {
                try self.setSelection(s);
                try self.queueRender();
            }
        },

        .inspector => |mode| return try self.rt_app.performAction(
            .{ .surface = self },
            .inspector,
            switch (mode) {
                inline else => |tag| @field(
                    apprt.action.Inspector,
                    @tagName(tag),
                ),
            },
        ),

        .close_surface => self.close(),

        .close_window => return try self.rt_app.performAction(
            .{ .surface = self },
            .close_window,
            {},
        ),

        .crash => |location| switch (location) {
            .main => @panic("crash binding action, crashing intentionally"),

            .render => {
                _ = self.renderer_thread.mailbox.push(.{ .crash = {} }, .{ .forever = {} });
                self.queueRender() catch |err| {
                    // Not a big deal if this fails.
                    log.warn("failed to notify renderer of crash message err={}", .{err});
                };
            },

            .io => self.io.queueMessage(.{ .crash = {} }, .unlocked),
        },

        .adjust_selection => |direction| {
            self.renderer_state.mutex.lock();
            defer self.renderer_state.mutex.unlock();

            const screen = &self.io.terminal.screen;
            const sel = if (screen.selection) |*sel| sel else {
                // If we don't have a selection we do not perform this
                // action, allowing the keybind to fall through to the
                // terminal.
                return false;
            };
            sel.adjust(screen, switch (direction) {
                .left => .left,
                .right => .right,
                .up => .up,
                .down => .down,
                .page_up => .page_up,
                .page_down => .page_down,
                .home => .home,
                .end => .end,
                .beginning_of_line => .beginning_of_line,
                .end_of_line => .end_of_line,
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
            screen.dirty.selection = true;
            try self.queueRender();
        },
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
        .close_tab,
        => true,

        else => false,
    };
}

/// The portion of the screen to write for writeScreenFile.
const WriteScreenLoc = enum {
    screen, // Full screen
    history, // History (scrollback)
    selection, // Selected text
};

fn writeScreenFile(
    self: *Surface,
    loc: WriteScreenLoc,
    write_action: input.Binding.Action.WriteScreenAction,
) !void {
    // Create a temporary directory to store our scrollback.
    var tmp_dir = try internal_os.TempDir.init();
    errdefer tmp_dir.deinit();

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buf, "{s}.txt", .{@tagName(loc)});

    // Open our scrollback file
    var file = try tmp_dir.dir.createFile(
        filename,
        switch (builtin.os.tag) {
            .windows => .{},
            else => .{ .mode = 0o600 },
        },
    );
    defer file.close();

    // Screen.dumpString writes byte-by-byte, so buffer it
    var buf_writer = std.io.bufferedWriter(file.writer());

    // Write the scrollback contents. This requires a lock.
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // We only dump history if we have history. We still keep
        // the file and write the empty file to the pty so that this
        // command always works on the primary screen.
        const pages = &self.io.terminal.screen.pages;
        const sel_: ?terminal.Selection = switch (loc) {
            .history => history: {
                // We do not support this for alternate screens
                // because they don't have scrollback anyways.
                if (self.io.terminal.active_screen == .alternate) {
                    break :history null;
                }

                break :history terminal.Selection.init(
                    pages.getTopLeft(.history),
                    pages.getBottomRight(.history) orelse
                        break :history null,
                    false,
                );
            },

            .screen => screen: {
                break :screen terminal.Selection.init(
                    pages.getTopLeft(.screen),
                    pages.getBottomRight(.screen) orelse
                        break :screen null,
                    false,
                );
            },

            .selection => self.io.terminal.screen.selection,
        };

        const sel = sel_ orelse {
            // If we have no selection we have no data so we do nothing.
            tmp_dir.deinit();
            return;
        };

        // Use topLeft and bottomRight to ensure correct coordinate ordering
        const tl = sel.topLeft(&self.io.terminal.screen);
        const br = sel.bottomRight(&self.io.terminal.screen);

        try self.io.terminal.screen.dumpString(
            buf_writer.writer(),
            .{
                .tl = tl,
                .br = br,
                .unwrap = true,
            },
        );
    }
    try buf_writer.flush();

    // Get the final path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath(filename, &path_buf);

    switch (write_action) {
        .copy => {
            const pathZ = try self.alloc.dupeZ(u8, path);
            defer self.alloc.free(pathZ);
            try self.rt_surface.setClipboardString(pathZ, .standard, false);
        },
        .open => try self.openUrl(.{ .kind = .text, .url = path }),
        .paste => self.io.queueMessage(try termio.Message.writeReq(
            self.alloc,
            path,
        ), .unlocked),
    }
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
        const unsafe = unsafe: {
            // If we've disabled paste protection then we always allow the paste.
            if (!self.config.clipboard_paste_protection) break :unsafe false;

            // If we're allowed to paste unsafe data then we always allow the paste.
            // This is set during confirmation usually.
            if (allow_unsafe) break :unsafe false;

            if (bracketed) {
                // If we're bracketed and the paste contains and ending
                // bracket then something naughty might be going on and we
                // never trust it.
                if (std.mem.indexOf(u8, data, "\x1B[201~") != null) break :unsafe true;

                // If we are bracketed and configured to trust that then the
                // paste is not unsafe.
                if (self.config.clipboard_paste_bracketed_safe) break :unsafe false;
            }

            break :unsafe !terminal.isSafePaste(data);
        };

        if (unsafe) {
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
        self.io.queueMessage(.{
            .write_stable = "\x1B[200~",
        }, .unlocked);
        self.io.queueMessage(try termio.Message.writeReq(
            self.alloc,
            data,
        ), .unlocked);
        self.io.queueMessage(.{
            .write_stable = "\x1B[201~",
        }, .unlocked);
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

        self.io.queueMessage(try termio.Message.writeReq(
            self.alloc,
            buf[0..len],
        ), .unlocked);
    }
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

    self.io.queueMessage(try termio.Message.writeReq(
        self.alloc,
        buf,
    ), .unlocked);
}

fn showDesktopNotification(self: *Surface, title: [:0]const u8, body: [:0]const u8) !void {
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
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .desktop_notification,
        .{
            .title = title,
            .body = body,
        },
    );
}

fn crashThreadState(self: *Surface) crash.sentry.ThreadState {
    return .{
        .type = .main,
        .surface = self,
    };
}

/// Tell the surface to present itself to the user. This may involve raising the
/// window and switching tabs.
fn presentSurface(self: *Surface) !void {
    _ = try self.rt_app.performAction(
        .{ .surface = self },
        .present_terminal,
        {},
    );
}

/// Utility function for the unit tests for mouse selection logic.
///
/// Tests a click and drag on a 10x5 cell grid, x positions are given in
/// fractional cells, e.g. 3.1 would be 10% through the cell at x = 3.
///
/// NOTE: The size tested with has 10px wide cells, meaning only one digit
///       after the decimal place has any meaning, e.g. 3.14 is equal to 3.1.
///
/// The provided start_x/y and end_x/y are the expected start and end points
/// of the resulting selection.
fn testMouseSelection(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    start_x: terminal.size.CellCountInt,
    start_y: u32,
    end_x: terminal.size.CellCountInt,
    end_y: u32,
    rect: bool,
) !void {
    assert(builtin.is_test);

    // Our screen size is 10x5 cells that are
    // 10x20 px, with 5px padding on all sides.
    const size: rendererpkg.Size = .{
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .left = 5, .top = 5, .right = 5, .bottom = 5 },
        .screen = .{ .width = 110, .height = 110 },
    };
    var screen = try terminal.Screen.init(std.testing.allocator, 10, 5, 0);
    defer screen.deinit();

    // We hold both ctrl and alt for rectangular
    // select so that this test is platform agnostic.
    const mods: input.Mods = .{
        .ctrl = rect,
        .alt = rect,
    };

    try std.testing.expectEqual(rect, SurfaceMouse.isRectangleSelectState(mods));

    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;

    const cell_width_f64: f64 = @floatFromInt(size.cell.width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        size.padding.left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        size.padding.left;

    const start_pin = screen.pages.pin(.{
        .viewport = .{ .x = start_x, .y = start_y },
    }) orelse unreachable;
    const end_pin = screen.pages.pin(.{
        .viewport = .{ .x = end_x, .y = end_y },
    }) orelse unreachable;

    try std.testing.expectEqualDeep(terminal.Selection{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    }, mouseSelection(
        click_pin,
        drag_pin,
        click_x_pos,
        drag_x_pos,
        mods,
        size,
    ));
}

/// Like `testMouseSelection` but checks that the resulting selection is null.
///
/// See `testMouseSelection` for more details.
fn testMouseSelectionIsNull(
    click_x: f64,
    click_y: u32,
    drag_x: f64,
    drag_y: u32,
    rect: bool,
) !void {
    assert(builtin.is_test);

    // Our screen size is 10x5 cells that are
    // 10x20 px, with 5px padding on all sides.
    const size: rendererpkg.Size = .{
        .cell = .{ .width = 10, .height = 20 },
        .padding = .{ .left = 5, .top = 5, .right = 5, .bottom = 5 },
        .screen = .{ .width = 110, .height = 110 },
    };
    var screen = try terminal.Screen.init(std.testing.allocator, 10, 5, 0);
    defer screen.deinit();

    // We hold both ctrl and alt for rectangular
    // select so that this test is platform agnostic.
    const mods: input.Mods = .{
        .ctrl = rect,
        .alt = rect,
    };

    try std.testing.expectEqual(rect, SurfaceMouse.isRectangleSelectState(mods));

    const click_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(click_x)), .y = click_y },
    }) orelse unreachable;
    const drag_pin = screen.pages.pin(.{
        .viewport = .{ .x = @intFromFloat(@floor(drag_x)), .y = drag_y },
    }) orelse unreachable;

    const cell_width_f64: f64 = @floatFromInt(size.cell.width);
    const click_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(click_x * cell_width_f64))) +
        size.padding.left;
    const drag_x_pos: u32 =
        @as(u32, @intFromFloat(@floor(drag_x * cell_width_f64))) +
        size.padding.left;

    try std.testing.expectEqual(
        null,
        mouseSelection(
            click_pin,
            drag_pin,
            click_x_pos,
            drag_x_pos,
            mods,
            size,
        ),
    );
}

test "Surface: selection logic" {
    // We disable format to make these easier to
    // read by pairing sets of coordinates per line.
    // zig fmt: off

    // -- LTR
    // single cell selection
    try testMouseSelection(
        3.0, 3, // click
        3.9, 3, // drag
        3, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click and drag pin cells
    try testMouseSelection(
        3.0, 3, // click
        5.9, 3, // drag
        3, 3, // expected start
        5, 3, // expected end
        false, // regular selection
    );
    // including click pin cell but not drag pin cell
    try testMouseSelection(
        3.0, 3, // click
        5.0, 3, // drag
        3, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // including drag pin cell but not click pin cell
    try testMouseSelection(
        3.9, 3, // click
        5.9, 3, // drag
        4, 3, // expected start
        5, 3, // expected end
        false, // regular selection
    );
    // including neither click nor drag pin cells
    try testMouseSelection(
        3.9, 3, // click
        5.0, 3, // drag
        4, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // empty selection (single cell on only left half)
    try testMouseSelectionIsNull(
        3.0, 3, // click
        3.1, 3, // drag
        false, // regular selection
    );
    // empty selection (single cell on only right half)
    try testMouseSelectionIsNull(
        3.8, 3, // click
        3.9, 3, // drag
        false, // regular selection
    );
    // empty selection (between two cells, not crossing threshold)
    try testMouseSelectionIsNull(
        3.9, 3, // click
        4.0, 3, // drag
        false, // regular selection
    );

    // -- RTL
    // single cell selection
    try testMouseSelection(
        3.9, 3, // click
        3.0, 3, // drag
        3, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click and drag pin cells
    try testMouseSelection(
        5.9, 3, // click
        3.0, 3, // drag
        5, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including click pin cell but not drag pin cell
    try testMouseSelection(
        5.9, 3, // click
        3.9, 3, // drag
        5, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // including drag pin cell but not click pin cell
    try testMouseSelection(
        5.0, 3, // click
        3.0, 3, // drag
        4, 3, // expected start
        3, 3, // expected end
        false, // regular selection
    );
    // including neither click nor drag pin cells
    try testMouseSelection(
        5.0, 3, // click
        3.9, 3, // drag
        4, 3, // expected start
        4, 3, // expected end
        false, // regular selection
    );
    // empty selection (single cell on only left half)
    try testMouseSelectionIsNull(
        3.1, 3, // click
        3.0, 3, // drag
        false, // regular selection
    );
    // empty selection (single cell on only right half)
    try testMouseSelectionIsNull(
        3.9, 3, // click
        3.8, 3, // drag
        false, // regular selection
    );
    // empty selection (between two cells, not crossing threshold)
    try testMouseSelectionIsNull(
        4.0, 3, // click
        3.9, 3, // drag
        false, // regular selection
    );

    // -- Wrapping
    // LTR, wrap excluded cells
    try testMouseSelection(
        9.9, 2, // click
        0.0, 4, // drag
        0, 3, // expected start
        9, 3, // expected end
        false, // regular selection
    );
    // RTL, wrap excluded cells
    try testMouseSelection(
        0.0, 4, // click
        9.9, 2, // drag
        9, 3, // expected start
        0, 3, // expected end
        false, // regular selection
    );
}

test "Surface: rectangle selection logic" {
    // We disable format to make these easier to
    // read by pairing sets of coordinates per line.
    // zig fmt: off

    // -- LTR
    // single column selection
    try testMouseSelection(
        3.0, 2, // click
        3.9, 4, // drag
        3, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click and drag pin columns
    try testMouseSelection(
        3.0, 2, // click
        5.9, 4, // drag
        3, 2, // expected start
        5, 4, // expected end
        true, //rectangle selection
    );
    // including click pin column but not drag pin column
    try testMouseSelection(
        3.0, 2, // click
        5.0, 4, // drag
        3, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // including drag pin column but not click pin column
    try testMouseSelection(
        3.9, 2, // click
        5.9, 4, // drag
        4, 2, // expected start
        5, 4, // expected end
        true, //rectangle selection
    );
    // including neither click nor drag pin columns
    try testMouseSelection(
        3.9, 2, // click
        5.0, 4, // drag
        4, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // empty selection (single column on only left half)
    try testMouseSelectionIsNull(
        3.0, 2, // click
        3.1, 4, // drag
        true, //rectangle selection
    );
    // empty selection (single column on only right half)
    try testMouseSelectionIsNull(
        3.8, 2, // click
        3.9, 4, // drag
        true, //rectangle selection
    );
    // empty selection (between two columns, not crossing threshold)
    try testMouseSelectionIsNull(
        3.9, 2, // click
        4.0, 4, // drag
        true, //rectangle selection
    );

    // -- RTL
    // single column selection
    try testMouseSelection(
        3.9, 2, // click
        3.0, 4, // drag
        3, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click and drag pin columns
    try testMouseSelection(
        5.9, 2, // click
        3.0, 4, // drag
        5, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including click pin column but not drag pin column
    try testMouseSelection(
        5.9, 2, // click
        3.9, 4, // drag
        5, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // including drag pin column but not click pin column
    try testMouseSelection(
        5.0, 2, // click
        3.0, 4, // drag
        4, 2, // expected start
        3, 4, // expected end
        true, //rectangle selection
    );
    // including neither click nor drag pin columns
    try testMouseSelection(
        5.0, 2, // click
        3.9, 4, // drag
        4, 2, // expected start
        4, 4, // expected end
        true, //rectangle selection
    );
    // empty selection (single column on only left half)
    try testMouseSelectionIsNull(
        3.1, 2, // click
        3.0, 4, // drag
        true, //rectangle selection
    );
    // empty selection (single column on only right half)
    try testMouseSelectionIsNull(
        3.9, 2, // click
        3.8, 4, // drag
        true, //rectangle selection
    );
    // empty selection (between two columns, not crossing threshold)
    try testMouseSelectionIsNull(
        4.0, 2, // click
        3.9, 4, // drag
        true, //rectangle selection
    );

    // -- Wrapping
    // LTR, do not wrap
    try testMouseSelection(
        9.9, 2, // click
        0.0, 4, // drag
        9, 2, // expected start
        0, 4, // expected end
        true, //rectangle selection
    );
    // RTL, do not wrap
    try testMouseSelection(
        0.0, 4, // click
        9.9, 2, // drag
        0, 4, // expected start
        9, 2, // expected end
        true, //rectangle selection
    );
}
