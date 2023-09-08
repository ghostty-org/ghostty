//! Application runtime that uses GTK4.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const glfw = @import("glfw");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

pub const c = @cImport({
    @cInclude("gtk/gtk.h");
});

// We need native X11 access to access the primary clipboard.
const glfw_native = glfw.Native(.{ .x11 = true });

/// Compatibility with gobject < 2.74
const G_CONNECT_DEFAULT = if (@hasDecl(c, "G_CONNECT_DEFAULT"))
    c.G_CONNECT_DEFAULT
else
    0;

const log = std.log.scoped(.gtk);

/// App is the entrypoint for the application. This is called after all
/// of the runtime-agnostic initialization is complete and we're ready
/// to start.
///
/// There is only ever one App instance per process. This is because most
/// application frameworks also have this restriction so it simplifies
/// the assumptions.
pub const App = struct {
    pub const Options = struct {};

    core_app: *CoreApp,
    config: Config,

    app: *c.GtkApplication,
    ctx: *c.GMainContext,

    cursor_default: *c.GdkCursor,
    cursor_ibeam: *c.GdkCursor,

    /// This is set to false when the main loop should exit.
    running: bool = true,

    pub fn init(core_app: *CoreApp, opts: Options) !App {
        _ = opts;

        // This is super weird, but we still use GLFW with GTK only so that
        // we can tap into their folklore logic to get screen DPI. If we can
        // figure out a reliable way to determine this ourselves, we can get
        // rid of this dep.
        if (!glfw.init(.{})) return error.GlfwInitFailed;

        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // Our uniqueness ID is based on whether we're in a debug mode or not.
        // In debug mode we want to be separate so we can develop Ghostty in
        // Ghostty.
        const uniqueness_id: ?[*c]const u8 = uniqueness_id: {
            if (!config.@"gtk-single-instance") break :uniqueness_id null;

            break :uniqueness_id "com.mitchellh.ghostty" ++ if (builtin.mode == .Debug) "-debug" else "";
        };

        // Create our GTK Application which encapsulates our process.
        const app = @as(?*c.GtkApplication, @ptrCast(c.gtk_application_new(
            uniqueness_id orelse null,

            // GTK >= 2.74
            if (@hasDecl(c, "G_APPLICATION_DEFAULT_FLAGS"))
                c.G_APPLICATION_DEFAULT_FLAGS
            else
                c.G_APPLICATION_FLAGS_NONE,
        ))) orelse return error.GtkInitFailed;
        errdefer c.g_object_unref(app);
        _ = c.g_signal_connect_data(
            app,
            "activate",
            c.G_CALLBACK(&activate),
            core_app,
            null,
            G_CONNECT_DEFAULT,
        );

        // We don't use g_application_run, we want to manually control the
        // loop so we have to do the same things the run function does:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533
        const ctx = c.g_main_context_default() orelse return error.GtkContextFailed;
        if (c.g_main_context_acquire(ctx) == 0) return error.GtkContextAcquireFailed;
        errdefer c.g_main_context_release(ctx);

        const gapp = @as(*c.GApplication, @ptrCast(app));
        var err_: ?*c.GError = null;
        if (c.g_application_register(
            gapp,
            null,
            @ptrCast(&err_),
        ) == 0) {
            if (err_) |err| {
                log.warn("error registering application: {s}", .{err.message});
                c.g_error_free(err);
            }
            return error.GtkApplicationRegisterFailed;
        }

        // This just calls the "activate" signal but its part of the normal
        // startup routine so we just call it:
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        c.g_application_activate(gapp);

        // Get our cursors
        const cursor_default = c.gdk_cursor_new_from_name("default", null).?;
        errdefer c.g_object_unref(cursor_default);
        const cursor_ibeam = c.gdk_cursor_new_from_name("text", cursor_default).?;
        errdefer c.g_object_unref(cursor_ibeam);

        return .{
            .core_app = core_app,
            .app = app,
            .config = config,
            .ctx = ctx,
            .cursor_default = cursor_default,
            .cursor_ibeam = cursor_ibeam,

            // If we are NOT the primary instance, then we never want to run.
            // This means that another instance of the GTK app is running and
            // our "activate" call above will open a window.
            .running = c.g_application_get_is_remote(gapp) == 0,
        };
    }

    // Terminate the application. The application will not be restarted after
    // this so all global state can be cleaned up.
    pub fn terminate(self: *App) void {
        c.g_settings_sync();
        while (c.g_main_context_iteration(self.ctx, 0) != 0) {}
        c.g_main_context_release(self.ctx);
        c.g_object_unref(self.app);

        c.g_object_unref(self.cursor_ibeam);
        c.g_object_unref(self.cursor_default);

        self.config.deinit();

        glfw.terminate();
    }

    /// Reload the configuration. This should return the new configuration.
    /// The old value can be freed immediately at this point assuming a
    /// successful return.
    ///
    /// The returned pointer value is only valid for a stable self pointer.
    pub fn reloadConfig(self: *App) !?*const Config {
        // Load our configuration
        var config = try Config.load(self.core_app.alloc);
        errdefer config.deinit();

        // Update the existing config, be sure to clean up the old one.
        self.config.deinit();
        self.config = config;

        return &self.config;
    }

    pub fn wakeup(self: App) void {
        _ = self;
        c.g_main_context_wakeup(null);
    }

    /// Run the event loop. This doesn't return until the app exits.
    pub fn run(self: *App) !void {
        while (self.running) {
            _ = c.g_main_context_iteration(self.ctx, 1);

            // Tick the terminal app
            const should_quit = try self.core_app.tick(self);
            if (should_quit) self.quit();
        }
    }

    /// Close the given surface.
    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        surface.invalidate();
    }

    pub fn newWindow(self: *App, parent_: ?*CoreSurface) !void {
        const alloc = self.core_app.alloc;

        // Allocate a fixed pointer for our window. We try to minimize
        // allocations but windows and other GUI requirements are so minimal
        // compared to the steady-state terminal operation so we use heap
        // allocation for this.
        //
        // The allocation is owned by the GtkWindow created. It will be
        // freed when the window is closed.
        var window = try alloc.create(Window);
        errdefer alloc.destroy(window);
        try window.init(self);

        // Add our initial tab
        try window.newTab(parent_);
    }

    fn quit(self: *App) void {
        // If we have no toplevel windows, then we're done.
        const list = c.gtk_window_list_toplevels();
        if (list == null) {
            self.running = false;
            return;
        }
        c.g_list_free(list);

        // If we have windows, then we want to confirm that we want to exit.
        const alert = c.gtk_message_dialog_new(
            null,
            c.GTK_DIALOG_MODAL,
            c.GTK_MESSAGE_QUESTION,
            c.GTK_BUTTONS_YES_NO,
            "Quit Ghostty?",
        );
        c.gtk_message_dialog_format_secondary_text(
            @ptrCast(alert),
            "All active terminal sessions will be terminated.",
        );

        // We want the "yes" to appear destructive.
        const yes_widget = c.gtk_dialog_get_widget_for_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_YES,
        );
        c.gtk_widget_add_css_class(yes_widget, "destructive-action");

        // We want the "no" to be the default action
        c.gtk_dialog_set_default_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_NO,
        );

        _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkQuitConfirmation), self, null, G_CONNECT_DEFAULT);

        c.gtk_widget_show(alert);
    }

    fn gtkQuitConfirmation(
        alert: *c.GtkMessageDialog,
        response: c.gint,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        _ = ud;

        // Close the alert window
        c.gtk_window_destroy(@ptrCast(alert));

        // If we didn't confirm then we're done
        if (response != c.GTK_RESPONSE_YES) return;

        // Force close all open windows
        const list = c.gtk_window_list_toplevels();
        defer c.g_list_free(list);
        c.g_list_foreach(list, struct {
            fn callback(data: c.gpointer, _: c.gpointer) callconv(.C) void {
                const ptr = data orelse return;
                const widget: *c.GtkWidget = @ptrCast(@alignCast(ptr));
                const window: *c.GtkWindow = @ptrCast(widget);
                c.gtk_window_destroy(window);
            }
        }.callback, null);
    }

    /// This is called by the "activate" signal. This is sent on program
    /// startup and also when a secondary instance launches and requests
    /// a new window.
    fn activate(app: *c.GtkApplication, ud: ?*anyopaque) callconv(.C) void {
        _ = app;

        const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

        // Queue a new window
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });
    }
};

/// The state for a single, real GTK window.
const Window = struct {
    const TAB_CLOSE_PAGE = "tab_close_page";
    const TAB_CLOSE_SURFACE = "tab_close_surface";

    app: *App,

    /// Our window
    window: *c.GtkWindow,

    /// The notebook (tab grouping) for this window.
    notebook: *c.GtkNotebook,

    /// The background CSS for the window (if any).
    css_window_background: ?[]u8 = null,

    /// The resources directory for the icon (if any).
    icon_search_dir: ?[:0]const u8 = null,

    pub fn init(self: *Window, app: *App) !void {
        // Set up our own state
        self.* = .{
            .app = app,
            .window = undefined,
            .notebook = undefined,
        };

        // Create the window
        const window = c.gtk_application_window_new(app.app);
        const gtk_window: *c.GtkWindow = @ptrCast(window);
        errdefer c.gtk_window_destroy(gtk_window);
        self.window = gtk_window;
        c.gtk_window_set_title(gtk_window, "Ghostty");
        c.gtk_window_set_default_size(gtk_window, 1000, 600);

        // If we don't have the icon then we'll try to add our resources dir
        // to the search path and see if we can find it there.
        const icon_name = "com.mitchellh.ghostty";
        const icon_theme = c.gtk_icon_theme_get_for_display(c.gtk_widget_get_display(window));
        if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) icon: {
            const base = self.app.core_app.resources_dir orelse {
                log.info("gtk app missing Ghostty icon and no resources dir detected", .{});
                log.info("gtk app will not have Ghostty icon", .{});
                break :icon;
            };

            // Note that this method for adding the icon search path is
            // a fallback mechanism. The recommended mechanism is the
            // Freedesktop Icon Theme Specification. We distribute a ".desktop"
            // file in zig-out/share that should be installed to the proper
            // place.
            const dir = try std.fmt.allocPrintZ(app.core_app.alloc, "{s}/icons", .{base});
            self.icon_search_dir = dir;
            c.gtk_icon_theme_add_search_path(icon_theme, dir.ptr);
            if (c.gtk_icon_theme_has_icon(icon_theme, icon_name) == 0) {
                log.warn("Ghostty icon for gtk app not found", .{});
            }
        }
        c.gtk_window_set_icon_name(gtk_window, icon_name);

        // Apply background opacity if we have it
        if (app.config.@"background-opacity" < 1) {
            c.gtk_widget_set_opacity(@ptrCast(window), app.config.@"background-opacity");
        }

        // Hide window decoration if configured. This has to happen before
        // `gtk_widget_show`.
        if (!app.config.@"window-decoration") {
            c.gtk_window_set_decorated(gtk_window, 0);
        }

        c.gtk_widget_show(window);
        _ = c.g_signal_connect_data(window, "close-request", c.G_CALLBACK(&gtkCloseRequest), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, G_CONNECT_DEFAULT);

        // Create a notebook to hold our tabs.
        const notebook_widget = c.gtk_notebook_new();
        const notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
        self.notebook = notebook;
        c.gtk_notebook_set_tab_pos(notebook, c.GTK_POS_TOP);
        c.gtk_notebook_set_scrollable(notebook, 1);
        c.gtk_notebook_set_show_tabs(notebook, 0);
        c.gtk_notebook_set_show_border(notebook, 0);

        // Create our add button for new tabs
        const notebook_add_btn = c.gtk_button_new_from_icon_name("list-add-symbolic");
        c.gtk_notebook_set_action_widget(notebook, notebook_add_btn, c.GTK_PACK_END);
        _ = c.g_signal_connect_data(notebook_add_btn, "clicked", c.G_CALLBACK(&gtkTabAddClick), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), self, null, G_CONNECT_DEFAULT);

        // The notebook is our main child
        c.gtk_window_set_child(gtk_window, notebook_widget);
    }

    pub fn deinit(self: *Window) void {
        if (self.css_window_background) |ptr| self.app.core_app.alloc.free(ptr);
        if (self.icon_search_dir) |ptr| self.app.core_app.alloc.free(ptr);
    }

    /// Add a new tab to this window.
    pub fn newTab(self: *Window, parent_: ?*CoreSurface) !void {
        // Grab a surface allocation we'll need it later.
        var surface = try self.app.core_app.alloc.create(Surface);
        errdefer self.app.core_app.alloc.destroy(surface);

        // Inherit the parent's font size if we are configured to.
        const font_size: ?font.face.DesiredSize = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size null;
            const parent = parent_ orelse break :font_size null;
            break :font_size parent.font_size;
        };

        // Build our tab label
        const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
        const label_text = c.gtk_label_new("Ghostty");
        c.gtk_box_append(label_box, label_text);

        const label_close_widget = c.gtk_button_new_from_icon_name("window-close");
        const label_close = @as(*c.GtkButton, @ptrCast(label_close_widget));
        c.gtk_button_set_has_frame(label_close, 0);
        c.gtk_box_append(label_box, label_close_widget);
        _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&gtkTabCloseClick), self, null, G_CONNECT_DEFAULT);

        // Initialize the GtkGLArea and attach it to our surface.
        // The surface starts in the "unrealized" state because we have to
        // wait for the "realize" callback from GTK to know that the OpenGL
        // context is ready. See Surface docs for more info.
        const gl_area = c.gtk_gl_area_new();
        try surface.init(self.app, .{
            .window = self,
            .gl_area = @ptrCast(gl_area),
            .title_label = @ptrCast(label_text),
            .font_size = font_size,
        });
        errdefer surface.deinit();
        const page_idx = c.gtk_notebook_append_page(self.notebook, gl_area, label_box_widget);
        if (page_idx < 0) {
            log.warn("failed to add surface to notebook", .{});
            return error.GtkAppendPageFailed;
        }

        // Tab settings
        c.gtk_notebook_set_tab_reorderable(self.notebook, gl_area, 1);

        // If we have multiple tabs, show the tab bar.
        if (c.gtk_notebook_get_n_pages(self.notebook) > 1) {
            c.gtk_notebook_set_show_tabs(self.notebook, 1);
        }

        // Set the userdata of the close button so it points to this page.
        const page = c.gtk_notebook_get_page(self.notebook, gl_area) orelse
            return error.GtkNotebookPageNotFound;
        c.g_object_set_data(@ptrCast(label_close), TAB_CLOSE_SURFACE, surface);
        c.g_object_set_data(@ptrCast(label_close), TAB_CLOSE_PAGE, page);
        c.g_object_set_data(@ptrCast(gl_area), TAB_CLOSE_PAGE, page);

        // Switch to the new tab
        c.gtk_notebook_set_current_page(self.notebook, page_idx);

        // We need to grab focus after it is added to the window. When
        // creating a window we want to always focus on the widget.
        const widget = @as(*c.GtkWidget, @ptrCast(gl_area));
        _ = c.gtk_widget_grab_focus(widget);
    }

    /// Close the tab for the given notebook page. This will automatically
    /// handle closing the window if there are no more tabs.
    fn closeTab(self: *Window, page: *c.GtkNotebookPage) void {
        // Remove the page
        const page_idx = getNotebookPageIndex(page);
        c.gtk_notebook_remove_page(self.notebook, page_idx);

        const remaining = c.gtk_notebook_get_n_pages(self.notebook);
        switch (remaining) {
            // If we have no more tabs we close the window
            0 => c.gtk_window_destroy(self.window),

            // If we have one more tab we hide the tab bar
            1 => c.gtk_notebook_set_show_tabs(self.notebook, 0),

            else => {},
        }

        // If we have remaining tabs, we need to make sure we grab focus.
        if (remaining > 0) self.focusCurrentTab();
    }

    /// Close the surface. This surface must be definitely part of this window.
    fn closeSurface(self: *Window, surface: *Surface) void {
        assert(surface.window == self);
        self.closeTab(getNotebookPage(@ptrCast(surface.gl_area)) orelse return);
    }

    /// Go to the previous tab for a surface.
    fn gotoPreviousTab(self: *Window, surface: *Surface) void {
        const page = getNotebookPage(@ptrCast(surface.gl_area)) orelse return;
        const page_idx = getNotebookPageIndex(page);

        // The next index is the previous or we wrap around.
        const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
            const max = c.gtk_notebook_get_n_pages(self.notebook);
            break :next_idx max -| 1;
        };

        // Do nothing if we have one tab
        if (next_idx == page_idx) return;

        c.gtk_notebook_set_current_page(self.notebook, next_idx);
        self.focusCurrentTab();
    }

    /// Go to the next tab for a surface.
    fn gotoNextTab(self: *Window, surface: *Surface) void {
        const page = getNotebookPage(@ptrCast(surface.gl_area)) orelse return;
        const page_idx = getNotebookPageIndex(page);
        const max = c.gtk_notebook_get_n_pages(self.notebook) -| 1;
        const next_idx = if (page_idx < max) page_idx + 1 else 0;
        if (next_idx == page_idx) return;

        c.gtk_notebook_set_current_page(self.notebook, next_idx);
        self.focusCurrentTab();
    }

    /// Go to the specific tab index.
    fn gotoTab(self: *Window, n: usize) void {
        if (n == 0) return;
        const max = c.gtk_notebook_get_n_pages(self.notebook);
        const page_idx = std.math.cast(c_int, n - 1) orelse return;
        if (page_idx < max) {
            c.gtk_notebook_set_current_page(self.notebook, page_idx);
            self.focusCurrentTab();
        }
    }

    /// Toggle fullscreen for this window.
    fn toggleFullscreen(self: *Window, _: configpkg.NonNativeFullscreen) void {
        const is_fullscreen = c.gtk_window_is_fullscreen(self.window);
        if (is_fullscreen == 0) {
            c.gtk_window_fullscreen(self.window);
        } else {
            c.gtk_window_unfullscreen(self.window);
        }
    }

    /// Grabs focus on the currently selected tab.
    fn focusCurrentTab(self: *Window) void {
        const page_idx = c.gtk_notebook_get_current_page(self.notebook);
        const widget = c.gtk_notebook_get_nth_page(self.notebook, page_idx);
        _ = c.gtk_widget_grab_focus(widget);
    }

    fn gtkTabAddClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        const parent = self.app.core_app.focusedSurface();
        self.newTab(parent) catch |err| {
            log.warn("error adding new tab: {}", .{err});
            return;
        };
    }

    fn gtkTabCloseClick(btn: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
        _ = ud;
        const surface: *Surface = @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(btn), TAB_CLOSE_SURFACE) orelse return,
        ));

        surface.core_surface.close();
    }

    fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(self.notebook, page)));
        const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
        const label_text = c.gtk_label_get_text(gtk_label);
        c.gtk_window_set_title(self.window, label_text);
    }

    fn gtkCloseRequest(v: *c.GtkWindow, ud: ?*anyopaque) callconv(.C) bool {
        _ = v;
        log.debug("window close request", .{});
        const self = userdataSelf(ud.?);

        if (self.app.core_app.surfaces.items.len == 1) {
            log.debug("Exiting without promt - only a single surface registered", .{});
            c.gtk_window_destroy(self.window);
            return true;
        }

        // Setup our basic message
        const alert = c.gtk_message_dialog_new(
            self.window,
            c.GTK_DIALOG_MODAL,
            c.GTK_MESSAGE_QUESTION,
            c.GTK_BUTTONS_YES_NO,
            "Close this window?",
        );
        c.gtk_message_dialog_format_secondary_text(
            @ptrCast(alert),
            "All terminal sessions in this window will be terminated.",
        );

        // We want the "yes" to appear destructive.
        const yes_widget = c.gtk_dialog_get_widget_for_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_YES,
        );
        c.gtk_widget_add_css_class(yes_widget, "destructive-action");

        // We want the "no" to be the default action
        c.gtk_dialog_set_default_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_NO,
        );

        _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, G_CONNECT_DEFAULT);

        c.gtk_widget_show(alert);
        return true;
    }

    fn gtkCloseConfirmation(
        alert: *c.GtkMessageDialog,
        response: c.gint,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        c.gtk_window_destroy(@ptrCast(alert));
        if (response == c.GTK_RESPONSE_YES) {
            const self = userdataSelf(ud.?);
            c.gtk_window_destroy(self.window);
        }
    }

    /// "destroy" signal for the window
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;
        log.debug("window destroy", .{});

        const self = userdataSelf(ud.?);
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    /// Get the GtkNotebookPage for the given object. You must be sure the
    /// object has the notebook page property set.
    fn getNotebookPage(obj: *c.GObject) ?*c.GtkNotebookPage {
        return @ptrCast(@alignCast(
            c.g_object_get_data(obj, TAB_CLOSE_PAGE) orelse return null,
        ));
    }

    fn getNotebookPageIndex(page: *c.GtkNotebookPage) c_int {
        var value: c.GValue = std.mem.zeroes(c.GValue);
        defer c.g_value_unset(&value);
        _ = c.g_value_init(&value, c.G_TYPE_INT);
        c.g_object_get_property(
            @ptrCast(@alignCast(page)),
            "position",
            &value,
        );

        return c.g_value_get_int(&value);
    }

    fn userdataSelf(ud: *anyopaque) *Window {
        return @ptrCast(@alignCast(ud));
    }
};

pub const Surface = struct {
    /// This is detected by the OpenGL renderer to move to a single-threaded
    /// draw operation. This basically puts locks around our draw path.
    pub const opengl_single_threaded_draw = true;

    pub const Options = struct {
        /// The window that this surface is attached to.
        window: *Window,

        /// The GL area that this surface should draw to.
        gl_area: *c.GtkGLArea,

        /// The label to use as the title of this surface. This will be
        /// modified with setTitle.
        title_label: ?*c.GtkLabel = null,

        /// A font size to set on the surface once it is initialized.
        font_size: ?font.face.DesiredSize = null,
    };

    /// Where the title of this surface will go.
    const Title = union(enum) {
        none: void,
        label: *c.GtkLabel,
    };

    /// Whether the surface has been realized or not yet. When a surface is
    /// "realized" it means that the OpenGL context is ready and the core
    /// surface has been initialized.
    realized: bool = false,

    /// The app we're part of
    app: *App,

    /// The window we're part of
    window: *Window,

    /// Our GTK area
    gl_area: *c.GtkGLArea,

    /// Our title label (if there is one).
    title: Title,

    /// The core surface backing this surface
    core_surface: CoreSurface,

    /// The font size to use for this surface once realized.
    font_size: ?font.face.DesiredSize = null,

    /// Cached metrics about the surface from GTK callbacks.
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    clipboard: c.GValue,

    /// Key input states. See gtkKeyPressed for detailed descriptions.
    in_keypress: bool = false,
    im_context: *c.GtkIMContext,
    im_composing: bool = false,
    im_buf: [128]u8 = undefined,
    im_len: u7 = 0,

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        const widget = @as(*c.GtkWidget, @ptrCast(opts.gl_area));
        c.gtk_gl_area_set_required_version(opts.gl_area, 3, 3);
        c.gtk_gl_area_set_has_stencil_buffer(opts.gl_area, 0);
        c.gtk_gl_area_set_has_depth_buffer(opts.gl_area, 0);
        c.gtk_gl_area_set_use_es(opts.gl_area, 0);

        // Key event controller will tell us about raw keypress events.
        const ec_key = c.gtk_event_controller_key_new();
        errdefer c.g_object_unref(ec_key);
        c.gtk_widget_add_controller(widget, ec_key);
        errdefer c.gtk_widget_remove_controller(widget, ec_key);

        // Focus controller will tell us about focus enter/exit events
        const ec_focus = c.gtk_event_controller_focus_new();
        errdefer c.g_object_unref(ec_focus);
        c.gtk_widget_add_controller(widget, ec_focus);
        errdefer c.gtk_widget_remove_controller(widget, ec_focus);

        // Create a second key controller so we can receive the raw
        // key-press events BEFORE the input method gets them.
        const ec_key_press = c.gtk_event_controller_key_new();
        errdefer c.g_object_unref(ec_key_press);
        c.gtk_widget_add_controller(widget, ec_key_press);
        errdefer c.gtk_widget_remove_controller(widget, ec_key_press);

        // Clicks
        const gesture_click = c.gtk_gesture_click_new();
        errdefer c.g_object_unref(gesture_click);
        c.gtk_gesture_single_set_button(@ptrCast(gesture_click), 0);
        c.gtk_widget_add_controller(widget, @ptrCast(gesture_click));

        // Mouse movement
        const ec_motion = c.gtk_event_controller_motion_new();
        errdefer c.g_object_unref(ec_motion);
        c.gtk_widget_add_controller(widget, ec_motion);

        // Scroll events
        const ec_scroll = c.gtk_event_controller_scroll_new(
            c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
                c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
        );
        errdefer c.g_object_unref(ec_scroll);
        c.gtk_widget_add_controller(widget, ec_scroll);

        // The input method context that we use to translate key events into
        // characters. This doesn't have an event key controller attached because
        // we call it manually from our own key controller.
        const im_context = c.gtk_im_multicontext_new();
        errdefer c.g_object_unref(im_context);

        // The GL area has to be focusable so that it can receive events
        c.gtk_widget_set_focusable(widget, 1);
        c.gtk_widget_set_focus_on_click(widget, 1);

        // When we're over the widget, set the cursor to the ibeam
        c.gtk_widget_set_cursor(widget, app.cursor_ibeam);

        // Build our result
        self.* = .{
            .app = app,
            .window = opts.window,
            .gl_area = opts.gl_area,
            .title = if (opts.title_label) |label| .{
                .label = label,
            } else .{ .none = {} },
            .core_surface = undefined,
            .font_size = opts.font_size,
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = 0, .y = 0 },
            .clipboard = std.mem.zeroes(c.GValue),
            .im_context = im_context,
        };
        errdefer self.* = undefined;

        // GL events
        _ = c.g_signal_connect_data(opts.gl_area, "realize", c.G_CALLBACK(&gtkRealize), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "render", c.G_CALLBACK(&gtkRender), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(opts.gl_area, "resize", c.G_CALLBACK(&gtkResize), self, null, G_CONNECT_DEFAULT);

        _ = c.g_signal_connect_data(ec_key_press, "key-pressed", c.G_CALLBACK(&gtkKeyPressed), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_key_press, "key-released", c.G_CALLBACK(&gtkKeyReleased), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_focus, "enter", c.G_CALLBACK(&gtkFocusEnter), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_focus, "leave", c.G_CALLBACK(&gtkFocusLeave), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_click, "pressed", c.G_CALLBACK(&gtkMouseDown), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_click, "released", c.G_CALLBACK(&gtkMouseUp), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_motion, "motion", c.G_CALLBACK(&gtkMouseMotion), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(ec_scroll, "scroll", c.G_CALLBACK(&gtkMouseScroll), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im_context, "preedit-start", c.G_CALLBACK(&gtkInputPreeditStart), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im_context, "preedit-changed", c.G_CALLBACK(&gtkInputPreeditChanged), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im_context, "preedit-end", c.G_CALLBACK(&gtkInputPreeditEnd), self, null, G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(im_context, "commit", c.G_CALLBACK(&gtkInputCommit), self, null, G_CONNECT_DEFAULT);
    }

    fn realize(self: *Surface) !void {
        // Add ourselves to the list of surfaces on the app.
        try self.app.core_app.addSurface(self);
        errdefer self.app.core_app.deleteSurface(self);

        // Get our new surface config
        var config = try apprt.surface.newConfig(self.app.core_app, &self.app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        try self.core_surface.init(
            self.app.core_app.alloc,
            &config,
            self.app.core_app,
            .{ .rt_app = self.app, .mailbox = &self.app.core_app.mailbox },
            self,
        );
        errdefer self.core_surface.deinit();

        // If we have a font size we want, set that now
        if (self.font_size) |size| {
            self.core_surface.setFontSize(size);
        }

        // Note we're realized
        self.realized = true;
    }

    pub fn deinit(self: *Surface) void {
        // We don't allocate anything if we aren't realized.
        if (!self.realized) return;

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
        self.core_surface = undefined;

        // Free all our GTK stuff
        c.g_object_unref(self.im_context);
        c.g_value_unset(&self.clipboard);
    }

    fn render(self: *Surface) !void {
        try self.core_surface.renderer.draw();
    }

    /// Invalidate the surface so that it forces a redraw on the next tick.
    fn invalidate(self: *Surface) void {
        c.gtk_gl_area_queue_render(self.gl_area);
    }

    /// Close this surface.
    pub fn close(self: *Surface, processActive: bool) void {
        if (!processActive) {
            self.window.closeSurface(self);
            return;
        }

        // Setup our basic message
        const alert = c.gtk_message_dialog_new(
            self.window.window,
            c.GTK_DIALOG_MODAL,
            c.GTK_MESSAGE_QUESTION,
            c.GTK_BUTTONS_YES_NO,
            "Close this terminal?",
        );
        c.gtk_message_dialog_format_secondary_text(
            @ptrCast(alert),
            "There is still a running process in the terminal. " ++
                "Closing the terminal will kill this process. " ++
                "Are you sure you want to close the terminal?\n\n" ++
                "Click 'No' to cancel and return to your terminal.",
        );

        // We want the "yes" to appear destructive.
        const yes_widget = c.gtk_dialog_get_widget_for_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_YES,
        );
        c.gtk_widget_add_css_class(yes_widget, "destructive-action");

        // We want the "no" to be the default action
        c.gtk_dialog_set_default_response(
            @ptrCast(alert),
            c.GTK_RESPONSE_NO,
        );

        _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, G_CONNECT_DEFAULT);

        c.gtk_widget_show(alert);
    }

    pub fn toggleFullscreen(self: *Surface, mac_non_native: configpkg.NonNativeFullscreen) void {
        self.window.toggleFullscreen(mac_non_native);
    }

    pub fn newTab(self: *Surface) !void {
        try self.window.newTab(&self.core_surface);
    }

    pub fn gotoPreviousTab(self: *Surface) void {
        self.window.gotoPreviousTab(self);
    }

    pub fn gotoNextTab(self: *Surface) void {
        self.window.gotoNextTab(self);
    }

    pub fn gotoTab(self: *Surface, n: usize) void {
        self.window.gotoTab(n);
    }

    pub fn setShouldClose(self: *Surface) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Surface) bool {
        _ = self;
        return false;
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;
        const monitor = glfw.Monitor.getPrimary() orelse return error.NoMonitor;
        const scale = monitor.getContentScale();
        return apprt.ContentScale{ .x = scale.x_scale, .y = scale.y_scale };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;
    }

    pub fn setTitle(self: *Surface, slice: [:0]const u8) !void {
        switch (self.title) {
            .none => {},

            .label => |label| {
                c.gtk_label_set_text(label, slice.ptr);

                const widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
                if (c.gtk_widget_is_focus(widget) == 1) {
                    c.gtk_window_set_title(self.window.window, c.gtk_label_get_text(label));
                }
            },
        }

        // const root = c.gtk_widget_get_root(@ptrCast(
        //     *c.GtkWidget,
        //     self.gl_area,
        // ));
    }

    pub fn getClipboardString(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
    ) ![:0]const u8 {
        const clipboard = getClipboard(@ptrCast(self.gl_area), clipboard_type);
        const content = c.gdk_clipboard_get_content(clipboard) orelse {
            // On my machine, this NEVER works, so we fallback to glfw's
            // implementation... I believe this never works because we need to
            // use the async mechanism with GTK but that doesn't play nice
            // with what our core expects.
            log.debug("no GTK clipboard contents, falling back to glfw", .{});
            return switch (clipboard_type) {
                .standard => glfw.getClipboardString() orelse glfw.mustGetErrorCode(),
                .selection => value: {
                    const raw = glfw_native.getX11SelectionString() orelse
                        return glfw.mustGetErrorCode();
                    break :value std.mem.span(raw);
                },
            };
        };

        c.g_value_unset(&self.clipboard);
        _ = c.g_value_init(&self.clipboard, c.G_TYPE_STRING);
        if (c.gdk_content_provider_get_value(content, &self.clipboard, null) == 0) {
            return "";
        }

        const ptr = c.g_value_get_string(&self.clipboard);
        return std.mem.sliceTo(ptr, 0);
    }

    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
    ) !void {
        const clipboard = getClipboard(@ptrCast(self.gl_area), clipboard_type);
        c.gdk_clipboard_set_text(clipboard, val.ptr);
    }

    fn getClipboard(widget: *c.GtkWidget, clipboard: apprt.Clipboard) ?*c.GdkClipboard {
        return switch (clipboard) {
            .standard => c.gtk_widget_get_clipboard(widget),
            .selection => c.gtk_widget_get_primary_clipboard(widget),
        };
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    fn gtkRealize(area: *c.GtkGLArea, ud: ?*anyopaque) callconv(.C) void {
        log.debug("gl surface realized", .{});

        // We need to make the context current so we can call GL functions.
        c.gtk_gl_area_make_current(area);
        if (c.gtk_gl_area_get_error(area)) |err| {
            log.err("surface failed to realize: {s}", .{err.*.message});
            return;
        }

        // realize means that our OpenGL context is ready, so we can now
        // initialize the core surface which will setup the renderer.
        const self = userdataSelf(ud.?);
        self.realize() catch |err| {
            // TODO: we need to destroy the GL area here.
            log.err("surface failed to realize: {}", .{err});
            return;
        };
    }

    /// render signal
    fn gtkRender(area: *c.GtkGLArea, ctx: *c.GdkGLContext, ud: ?*anyopaque) callconv(.C) c.gboolean {
        _ = area;
        _ = ctx;

        const self = userdataSelf(ud.?);
        self.render() catch |err| {
            log.err("surface failed to render: {}", .{err});
            return 0;
        };

        return 1;
    }

    /// render signal
    fn gtkResize(area: *c.GtkGLArea, width: c.gint, height: c.gint, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);

        // Some debug output to help understand what GTK is telling us.
        {
            const scale_factor = scale: {
                const widget = @as(*c.GtkWidget, @ptrCast(area));
                break :scale c.gtk_widget_get_scale_factor(widget);
            };

            const window_scale_factor = scale: {
                const window = @as(*c.GtkNative, @ptrCast(self.window.window));
                const gdk_surface = c.gtk_native_get_surface(window);
                break :scale c.gdk_surface_get_scale_factor(gdk_surface);
            };

            log.debug("gl resize width={} height={} scale={} window_scale={}", .{
                width,
                height,
                scale_factor,
                window_scale_factor,
            });
        }

        self.size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };

        // Call the primary callback.
        if (self.realized) {
            self.core_surface.sizeCallback(self.size) catch |err| {
                log.err("error in size callback err={}", .{err});
                return;
            };
        }
    }

    /// "destroy" signal for surface
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;
        log.debug("gl destroy", .{});

        const self = userdataSelf(ud.?);
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    fn gtkMouseDown(
        gesture: *c.GtkGestureClick,
        _: c.gint,
        _: c.gdouble,
        _: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));

        // If we don't have focus, grab it.
        const gl_widget = @as(*c.GtkWidget, @ptrCast(self.gl_area));
        if (c.gtk_widget_has_focus(gl_widget) == 0) {
            _ = c.gtk_widget_grab_focus(gl_widget);
        }

        self.core_surface.mouseButtonCallback(.press, button, .{}) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseUp(
        gesture: *c.GtkGestureClick,
        _: c.gint,
        _: c.gdouble,
        _: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const button = translateMouseButton(c.gtk_gesture_single_get_current_button(@ptrCast(gesture)));
        const self = userdataSelf(ud.?);
        self.core_surface.mouseButtonCallback(.release, button, .{}) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseMotion(
        _: *c.GtkEventControllerMotion,
        x: c.gdouble,
        y: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.cursor_pos = .{
            .x = @max(@as(f32, 0), @as(f32, @floatCast(x))),
            .y = @floatCast(y),
        };

        self.core_surface.cursorPosCallback(self.cursor_pos) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    fn gtkMouseScroll(
        _: *c.GtkEventControllerScroll,
        x: c.gdouble,
        y: c.gdouble,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);

        // GTK doesn't support any of the scroll mods.
        const scroll_mods: input.ScrollMods = .{};

        self.core_surface.scrollCallback(x, y * -1, scroll_mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    fn gtkKeyPressed(
        ec_key: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        gtk_mods: c.GdkModifierType,
        ud: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        return if (keyEvent(.press, ec_key, keyval, keycode, gtk_mods, ud)) 1 else 0;
    }

    fn gtkKeyReleased(
        ec_key: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        ud: ?*anyopaque,
    ) callconv(.C) c.gboolean {
        return if (keyEvent(.release, ec_key, keyval, keycode, state, ud)) 1 else 0;
    }

    /// Key press event. This is where we do ALL of our key handling,
    /// translation to keyboard layouts, dead key handling, etc. Key handling
    /// is complicated so this comment will explain what's going on.
    ///
    /// At a high level, we want to construct an `input.KeyEvent` and
    /// pass that to `keyCallback`. At a low level, this is more complicated
    /// than it appears because we need to construct all of this information
    /// and its not given to us.
    ///
    /// For press events, we run the keypress through the input method context
    /// in order to determine if we're in a dead key state, completed unicode
    /// char, etc. This all happens through various callbacks: preedit, commit,
    /// etc. These inspect "in_keypress" if they have to and set some instance
    /// state.
    ///
    /// We then take all of the information in order to determine if we have
    /// a unicode character or if we have to map the keyval to a code to
    /// get the underlying logical key, etc.
    ///
    /// Finally, we can emit the keyCallback.
    ///
    /// Note we ALSO have an IMContext attached directly to the widget
    /// which can emit preedit and commit callbacks. But, if we're not
    /// in a keypress, we let those automatically work.
    fn keyEvent(
        action: input.Action,
        ec_key: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        gtk_mods: c.GdkModifierType,
        ud: ?*anyopaque,
    ) bool {
        const self = userdataSelf(ud.?);
        const mods = translateMods(gtk_mods);
        const keyval_unicode = c.gdk_keyval_to_unicode(keyval);
        const event = c.gtk_event_controller_get_current_event(@ptrCast(ec_key));

        // Get the unshifted unicode value of the keyval. This is used
        // by the Kitty keyboard protocol.
        const keyval_unicode_unshifted: u21 = unshifted: {
            var n: c_int = undefined;
            var keys: [*c]c.GdkKeymapKey = undefined;
            var keyvals: [*c]c.guint = undefined;
            if (c.gdk_display_map_keycode(
                c.gdk_event_get_display(event),
                keycode,
                &keys,
                &keyvals,
                &n,
            ) == 0) break :unshifted 0;

            defer c.g_free(keys);
            defer c.g_free(keyvals);
            for (keys[0..@intCast(n)], 0..) |key, i| {
                if (key.group == 0 and key.level == 0) {
                    break :unshifted @intCast(c.gdk_keyval_to_unicode(keyvals[i]));
                }
            }

            break :unshifted 0;
        };

        // We always reset our committed text when ending a keypress so that
        // future keypresses don't think we have a commit event.
        defer self.im_len = 0;

        // We only want to send the event through the IM context if we're a press
        if (action == .press or action == .repeat) {
            // We mark that we're in a keypress event. We use this in our
            // IM commit callback to determine if we need to send a char callback
            // to the core surface or not.
            self.in_keypress = true;
            defer self.in_keypress = false;

            // Pass the event through the IM controller to handle dead key states.
            // Filter is true if the event was handled by the IM controller.
            _ = c.gtk_im_context_filter_keypress(self.im_context, event) != 0;

            // If this is a dead key, then we're composing a character and
            // we need to set our proper preedit state.
            if (self.im_composing) preedit: {
                const text = self.im_buf[0..self.im_len];
                const view = std.unicode.Utf8View.init(text) catch |err| {
                    log.warn("cannot build utf8 view over input: {}", .{err});
                    break :preedit;
                };
                var it = view.iterator();

                const cp: u21 = it.nextCodepoint() orelse 0;
                self.core_surface.preeditCallback(cp) catch |err| {
                    log.err("error in preedit callback err={}", .{err});
                    break :preedit;
                };
            } else {
                // If we aren't composing, then we set our preedit to
                // empty no matter what.
                self.core_surface.preeditCallback(null) catch {};
            }
        }

        // We want to get the physical unmapped key to process physical keybinds.
        // (These are keybinds explicitly marked as requesting physical mapping).
        const physical_key = keycode: for (input.keycodes.entries) |entry| {
            if (entry.native == keycode) break :keycode entry.key;
        } else .invalid;

        // Get our consumed modifiers
        const consumed_mods: input.Mods = consumed: {
            const raw = c.gdk_key_event_get_consumed_modifiers(event);
            const masked = raw & c.GDK_MODIFIER_MASK;
            break :consumed translateMods(masked);
        };

        // If we're not in a dead key state, we want to translate our text
        // to some input.Key.
        const key = if (!self.im_composing) key: {
            // A completed key. If the length of the key is one then we can
            // attempt to translate it to a key enum and call the key
            // callback. First try plain ASCII.
            if (self.im_len > 0) {
                if (input.Key.fromASCII(self.im_buf[0])) |key| {
                    break :key key;
                }
            }

            // If that doesn't work then we try to translate they kevval..
            if (keyval_unicode != 0) {
                if (std.math.cast(u8, keyval_unicode)) |byte| {
                    if (input.Key.fromASCII(byte)) |key| {
                        break :key key;
                    }
                }
            }

            break :key physical_key;
        } else .invalid;

        // log.debug("key pressed key={} keyval={x} physical_key={} composing={} text_len={} mods={}", .{
        //     key,
        //     keyval,
        //     physical_key,
        //     self.im_composing,
        //     self.im_len,
        //     mods,
        // });

        // If we have no UTF-8 text, we try to convert our keyval to
        // a text value. We have to do this because GTK will not process
        // "Ctrl+Shift+1" (on US keyboards) as "Ctrl+!" but instead as "".
        // But the keyval is set correctly so we can at least extract that.
        if (self.im_len == 0 and keyval_unicode > 0) {
            if (std.math.cast(u21, keyval_unicode)) |cp| {
                if (std.unicode.utf8Encode(cp, &self.im_buf)) |len| {
                    self.im_len = len;
                } else |_| {}
            }
        }

        // Invoke the core Ghostty logic to handle this input.
        const consumed = self.core_surface.keyCallback(.{
            .action = action,
            .key = key,
            .physical_key = physical_key,
            .mods = mods,
            .consumed_mods = consumed_mods,
            .composing = self.im_composing,
            .utf8 = self.im_buf[0..self.im_len],
            .unshifted_codepoint = keyval_unicode_unshifted,
        }) catch |err| {
            log.err("error in key callback err={}", .{err});
            return false;
        };

        // If we consume the key then we want to reset the dead key state.
        if (consumed and (action == .press or action == .repeat)) {
            c.gtk_im_context_reset(self.im_context);
            self.core_surface.preeditCallback(null) catch {};
            return true;
        }

        return false;
    }

    fn gtkInputPreeditStart(
        _: *c.GtkIMContext,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        //log.debug("preedit start", .{});
        const self = userdataSelf(ud.?);
        if (!self.in_keypress) return;

        // Mark that we are now composing a string with a dead key state.
        // We'll record the string in the preedit-changed callback.
        self.im_composing = true;
    }

    fn gtkInputPreeditChanged(
        ctx: *c.GtkIMContext,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        if (!self.in_keypress) return;

        // Get our pre-edit string that we'll use to show the user.
        var buf: [*c]u8 = undefined;
        _ = c.gtk_im_context_get_preedit_string(ctx, &buf, null, null);
        defer c.g_free(buf);
        const str = std.mem.sliceTo(buf, 0);

        // Copy the preedit string into the im_buf. This is safe because
        // commit will always overwrite this.
        self.im_len = @intCast(@min(self.im_buf.len, str.len));
        @memcpy(self.im_buf[0..self.im_len], str);
    }

    fn gtkInputPreeditEnd(
        _: *c.GtkIMContext,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        //log.debug("preedit end", .{});
        const self = userdataSelf(ud.?);
        if (!self.in_keypress) return;
        self.im_composing = false;
        self.im_len = 0;
    }

    fn gtkInputCommit(
        _: *c.GtkIMContext,
        bytes: [*:0]u8,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        const self = userdataSelf(ud.?);
        const str = std.mem.sliceTo(bytes, 0);

        // If we're in a key event, then we want to buffer the commit so
        // that we can send the proper keycallback followed by the char
        // callback.
        if (self.in_keypress) {
            if (str.len <= self.im_buf.len) {
                @memcpy(self.im_buf[0..str.len], str);
                self.im_len = @intCast(str.len);

                // log.debug("input commit: {x}", .{self.im_buf[0]});
            } else {
                log.warn("not enough buffer space for input method commit", .{});
            }

            return;
        }

        // We're not in a keypress, so this was sent from an on-screen emoji
        // keyboard or someting like that. Send the characters directly to
        // the surface.
        _ = self.core_surface.keyCallback(.{
            .action = .press,
            .key = .invalid,
            .physical_key = .invalid,
            .mods = .{},
            .consumed_mods = .{},
            .composing = false,
            .utf8 = str,
        }) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    fn gtkFocusEnter(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.core_surface.focusCallback(true) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn gtkFocusLeave(_: *c.GtkEventControllerFocus, ud: ?*anyopaque) callconv(.C) void {
        const self = userdataSelf(ud.?);
        self.core_surface.focusCallback(false) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    fn gtkCloseConfirmation(
        alert: *c.GtkMessageDialog,
        response: c.gint,
        ud: ?*anyopaque,
    ) callconv(.C) void {
        c.gtk_window_destroy(@ptrCast(alert));
        if (response == c.GTK_RESPONSE_YES) {
            const self = userdataSelf(ud.?);
            self.window.closeSurface(self);
        }
    }

    fn userdataSelf(ud: *anyopaque) *Surface {
        return @ptrCast(@alignCast(ud));
    }
};

fn translateMouseButton(button: c.guint) input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        10 => .ten,
        11 => .eleven,
        else => .unknown,
    };
}

fn translateMods(state: c.GdkModifierType) input.Mods {
    var mods: input.Mods = .{};
    if (state & c.GDK_SHIFT_MASK != 0) mods.shift = true;
    if (state & c.GDK_CONTROL_MASK != 0) mods.ctrl = true;
    if (state & c.GDK_ALT_MASK != 0) mods.alt = true;
    if (state & c.GDK_SUPER_MASK != 0) mods.super = true;

    // Lock is dependent on the X settings but we just assume caps lock.
    if (state & c.GDK_LOCK_MASK != 0) mods.caps_lock = true;
    return mods;
}

fn translateKey(keyval: c.guint) input.Key {
    return switch (keyval) {
        c.GDK_KEY_a => .a,
        c.GDK_KEY_b => .b,
        c.GDK_KEY_c => .c,
        c.GDK_KEY_d => .d,
        c.GDK_KEY_e => .e,
        c.GDK_KEY_f => .f,
        c.GDK_KEY_g => .g,
        c.GDK_KEY_h => .h,
        c.GDK_KEY_i => .i,
        c.GDK_KEY_j => .j,
        c.GDK_KEY_k => .k,
        c.GDK_KEY_l => .l,
        c.GDK_KEY_m => .m,
        c.GDK_KEY_n => .n,
        c.GDK_KEY_o => .o,
        c.GDK_KEY_p => .p,
        c.GDK_KEY_q => .q,
        c.GDK_KEY_r => .r,
        c.GDK_KEY_s => .s,
        c.GDK_KEY_t => .t,
        c.GDK_KEY_u => .u,
        c.GDK_KEY_v => .v,
        c.GDK_KEY_w => .w,
        c.GDK_KEY_x => .x,
        c.GDK_KEY_y => .y,
        c.GDK_KEY_z => .z,

        c.GDK_KEY_0 => .zero,
        c.GDK_KEY_1 => .one,
        c.GDK_KEY_2 => .two,
        c.GDK_KEY_3 => .three,
        c.GDK_KEY_4 => .four,
        c.GDK_KEY_5 => .five,
        c.GDK_KEY_6 => .six,
        c.GDK_KEY_7 => .seven,
        c.GDK_KEY_8 => .eight,
        c.GDK_KEY_9 => .nine,

        c.GDK_KEY_semicolon => .semicolon,
        c.GDK_KEY_space => .space,
        c.GDK_KEY_apostrophe => .apostrophe,
        c.GDK_KEY_comma => .comma,
        c.GDK_KEY_grave => .grave_accent, // `
        c.GDK_KEY_period => .period,
        c.GDK_KEY_slash => .slash,
        c.GDK_KEY_minus => .minus,
        c.GDK_KEY_equal => .equal,
        c.GDK_KEY_bracketleft => .left_bracket, // [
        c.GDK_KEY_bracketright => .right_bracket, // ]
        c.GDK_KEY_backslash => .backslash, // /

        c.GDK_KEY_Up => .up,
        c.GDK_KEY_Down => .down,
        c.GDK_KEY_Right => .right,
        c.GDK_KEY_Left => .left,
        c.GDK_KEY_Home => .home,
        c.GDK_KEY_End => .end,
        c.GDK_KEY_Insert => .insert,
        c.GDK_KEY_Delete => .delete,
        c.GDK_KEY_Caps_Lock => .caps_lock,
        c.GDK_KEY_Scroll_Lock => .scroll_lock,
        c.GDK_KEY_Num_Lock => .num_lock,
        c.GDK_KEY_Page_Up => .page_up,
        c.GDK_KEY_Page_Down => .page_down,
        c.GDK_KEY_Escape => .escape,
        c.GDK_KEY_Return => .enter,
        c.GDK_KEY_Tab => .tab,
        c.GDK_KEY_BackSpace => .backspace,
        c.GDK_KEY_Print => .print_screen,
        c.GDK_KEY_Pause => .pause,

        c.GDK_KEY_F1 => .f1,
        c.GDK_KEY_F2 => .f2,
        c.GDK_KEY_F3 => .f3,
        c.GDK_KEY_F4 => .f4,
        c.GDK_KEY_F5 => .f5,
        c.GDK_KEY_F6 => .f6,
        c.GDK_KEY_F7 => .f7,
        c.GDK_KEY_F8 => .f8,
        c.GDK_KEY_F9 => .f9,
        c.GDK_KEY_F10 => .f10,
        c.GDK_KEY_F11 => .f11,
        c.GDK_KEY_F12 => .f12,
        c.GDK_KEY_F13 => .f13,
        c.GDK_KEY_F14 => .f14,
        c.GDK_KEY_F15 => .f15,
        c.GDK_KEY_F16 => .f16,
        c.GDK_KEY_F17 => .f17,
        c.GDK_KEY_F18 => .f18,
        c.GDK_KEY_F19 => .f19,
        c.GDK_KEY_F20 => .f20,
        c.GDK_KEY_F21 => .f21,
        c.GDK_KEY_F22 => .f22,
        c.GDK_KEY_F23 => .f23,
        c.GDK_KEY_F24 => .f24,
        c.GDK_KEY_F25 => .f25,

        c.GDK_KEY_KP_0 => .kp_0,
        c.GDK_KEY_KP_1 => .kp_1,
        c.GDK_KEY_KP_2 => .kp_2,
        c.GDK_KEY_KP_3 => .kp_3,
        c.GDK_KEY_KP_4 => .kp_4,
        c.GDK_KEY_KP_5 => .kp_5,
        c.GDK_KEY_KP_6 => .kp_6,
        c.GDK_KEY_KP_7 => .kp_7,
        c.GDK_KEY_KP_8 => .kp_8,
        c.GDK_KEY_KP_9 => .kp_9,
        c.GDK_KEY_KP_Decimal => .kp_decimal,
        c.GDK_KEY_KP_Divide => .kp_divide,
        c.GDK_KEY_KP_Multiply => .kp_multiply,
        c.GDK_KEY_KP_Subtract => .kp_subtract,
        c.GDK_KEY_KP_Add => .kp_add,
        c.GDK_KEY_KP_Enter => .kp_enter,
        c.GDK_KEY_KP_Equal => .kp_equal,

        c.GDK_KEY_Shift_L => .left_shift,
        c.GDK_KEY_Control_L => .left_control,
        c.GDK_KEY_Alt_L => .left_alt,
        c.GDK_KEY_Super_L => .left_super,
        c.GDK_KEY_Shift_R => .right_shift,
        c.GDK_KEY_Control_R => .right_control,
        c.GDK_KEY_Alt_R => .right_alt,
        c.GDK_KEY_Super_R => .right_super,

        else => .invalid,
    };
}
