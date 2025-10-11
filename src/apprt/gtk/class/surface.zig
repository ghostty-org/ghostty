const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const build_config = @import("../../../build_config.zig");
const datastruct = @import("../../../datastruct/main.zig");
const font = @import("../../../font/main.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const renderer = @import("../../../renderer.zig");
const terminal = @import("../../../terminal/main.zig");
const CoreSurface = @import("../../../Surface.zig");
const gresource = @import("../build/gresource.zig");
const ext = @import("../ext.zig");
const gsettings = @import("../gsettings.zig");
const gtk_key = @import("../key.zig");
const ApprtSurface = @import("../Surface.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;
const ResizeOverlay = @import("resize_overlay.zig").ResizeOverlay;
const SearchOverlay = @import("search_overlay.zig").SearchOverlay;
const KeyStateOverlay = @import("key_state_overlay.zig").KeyStateOverlay;
const ChildExited = @import("surface_child_exited.zig").SurfaceChildExited;
const ClipboardConfirmationDialog = @import("clipboard_confirmation_dialog.zig").ClipboardConfirmationDialog;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Window = @import("window.zig").Window;
const InspectorWindow = @import("inspector_window.zig").InspectorWindow;
const i18n = @import("../../../os/i18n.zig");

const log = std.log.scoped(.gtk_ghostty_surface);

pub const Surface = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const Implements = [_]type{gtk.Scrollable};
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySurface",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
        .implements = &.{
            gobject.ext.implement(gtk.Scrollable, .{}),
        },
    });

    /// A SplitTree implementation that stores surfaces.
    pub const Tree = datastruct.SplitTree(Self);

    pub const properties = struct {
        /// This property is set to true when the bell is ringing. Note that
        /// this property will only emit a changed signal when there is a
        /// full state change. If a bell is ringing and another bell event
        /// comes through, the change notification will NOT be emitted.
        ///
        /// If you need to know every scenario the bell is triggered,
        /// listen to the `bell` signal instead.
        pub const @"bell-ringing" = struct {
            pub const name = "bell-ringing";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("bell_ringing"),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"child-exited" = struct {
            pub const name = "child-exited";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "child_exited",
                    ),
                },
            );
        };

        pub const @"default-size" = struct {
            pub const name = "default-size";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Size,
                .{
                    .accessor = C.privateBoxedFieldAccessor("default_size"),
                },
            );
        };

        pub const @"error" = struct {
            pub const name = "error";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "error",
                    ),
                },
            );
        };

        pub const @"font-size-request" = struct {
            pub const name = "font-size-request";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*font.face.DesiredSize,
                .{
                    .accessor = C.privateBoxedFieldAccessor("font_size_request"),
                },
            );
        };

        pub const focused = struct {
            pub const name = "focused";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "focused",
                    ),
                },
            );
        };

        pub const @"min-size" = struct {
            pub const name = "min-size";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Size,
                .{
                    .accessor = C.privateBoxedFieldAccessor("min_size"),
                },
            );
        };

        pub const @"mouse-hidden" = struct {
            pub const name = "mouse-hidden";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getMouseHidden,
                            .setter = setMouseHidden,
                        },
                    ),
                },
            );
        };

        pub const @"mouse-shape" = struct {
            pub const name = "mouse-shape";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                terminal.MouseShape,
                .{
                    .default = .text,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        terminal.MouseShape,
                        .{
                            .getter = getMouseShape,
                            .setter = setMouseShape,
                        },
                    ),
                },
            );
        };

        pub const @"mouse-hover-url" = struct {
            pub const name = "mouse-hover-url";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("mouse_hover_url"),
                },
            );
        };

        pub const pwd = struct {
            pub const name = "pwd";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("pwd"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };

        pub const zoom = struct {
            pub const name = "zoom";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "zoom",
                    ),
                },
            );
        };

        pub const @"is-split" = struct {
            pub const name = "is-split";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "is_split",
                    ),
                },
            );
        };

        pub const hadjustment = struct {
            pub const name = "hadjustment";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.Adjustment,
                .{
                    .accessor = .{
                        .getter = getHAdjustmentValue,
                        .setter = setHAdjustmentValue,
                    },
                },
            );
        };

        pub const vadjustment = struct {
            pub const name = "vadjustment";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.Adjustment,
                .{
                    .accessor = .{
                        .getter = getVAdjustmentValue,
                        .setter = setVAdjustmentValue,
                    },
                },
            );
        };

        pub const @"hscroll-policy" = struct {
            pub const name = "hscroll-policy";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.ScrollablePolicy,
                .{
                    .default = .natural,
                    .accessor = C.privateShallowFieldAccessor("hscroll_policy"),
                },
            );
        };

        pub const @"vscroll-policy" = struct {
            pub const name = "vscroll-policy";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.ScrollablePolicy,
                .{
                    .default = .natural,
                    .accessor = C.privateShallowFieldAccessor("vscroll_policy"),
                },
            );
        };

        pub const @"key-sequence" = struct {
            pub const name = "key-sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getKeySequence,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const @"key-table" = struct {
            pub const name = "key-table";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getKeyTable,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const readonly = struct {
            pub const name = "readonly";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getReadonly,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the bell event is received. Unlike the
        /// `bell-ringing` property, this is emitted every time the event
        /// is received and not just on state changes.
        pub const bell = struct {
            pub const name = "bell";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
        /// Emitted whenever the surface would like to be closed for any
        /// reason.
        ///
        /// The surface view does NOT handle its own close confirmation.
        /// If there is a process alive then the boolean parameter will
        /// specify it and the parent widget should handle this request.
        ///
        /// This signal lets the containing widget decide how closure works.
        /// This lets this Surface widget be used as a split, tab, etc.
        /// without it having to be aware of its own semantics.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted whenever the clipboard has been written.
        pub const @"clipboard-write" = struct {
            pub const name = "clipboard-write";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{
                    apprt.Clipboard,
                    [*:0]const u8,
                },
                void,
            );
        };

        /// Emitted whenever the surface reads the clipboard.
        pub const @"clipboard-read" = struct {
            pub const name = "clipboard-read";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted after the surface is initialized.
        pub const init = struct {
            pub const name = "init";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted just prior to the context menu appearing.
        pub const menu = struct {
            pub const name = "menu";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted when the focus wants to be brought to the top and
        /// focused.
        pub const @"present-request" = struct {
            pub const name = "present-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted when this surface requests its container to toggle its
        /// fullscreen state.
        pub const @"toggle-fullscreen" = struct {
            pub const name = "toggle-fullscreen";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted when this surface requests its container to toggle its
        /// maximized state.
        pub const @"toggle-maximize" = struct {
            pub const name = "toggle-maximize";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The default size for a window that embeds this surface.
        default_size: ?*Size = null,

        /// The minimum size for this surface. Embedders enforce this,
        /// not the surface itself.
        min_size: ?*Size = null,

        /// The requested font size. This only applies to initialization
        /// and has no effect later.
        font_size_request: ?*font.face.DesiredSize = null,

        /// The mouse shape to show for the surface.
        mouse_shape: terminal.MouseShape = .default,

        /// Whether the mouse should be hidden or not as requested externally.
        mouse_hidden: bool = false,

        /// The URL that the mouse is currently hovering over.
        mouse_hover_url: ?[:0]const u8 = null,

        /// The current working directory. This has to be reported externally,
        /// usually by shell integration which then talks to libghostty
        /// which triggers this property.
        ///
        /// If this is set prior to initialization then the surface will
        /// start in this pwd. If it is set after, it has no impact on the
        /// core surface.
        pwd: ?[:0]const u8 = null,

        /// The title of this surface, if any has been set.
        title: ?[:0]const u8 = null,

        /// The manually overridden title of this surface from `promptTitle`.
        title_override: ?[:0]const u8 = null,

        /// The current focus state of the terminal based on the
        /// focus events.
        focused: bool = true,

        /// Whether this surface is "zoomed" or not. A zoomed surface
        /// shows up taking the full bounds of a split view.
        zoom: bool = false,

        /// The GLAarea that renders the actual surface. This is a binding
        /// to the template so it doesn't have to be unrefed manually.
        gl_area: *gtk.GLArea,

        /// The labels for the left/right sides of the URL hover tooltip.
        url_left: *gtk.Label,
        url_right: *gtk.Label,

        /// The resize overlay
        resize_overlay: *ResizeOverlay,

        /// The search overlay
        search_overlay: *SearchOverlay,

        /// The key state overlay
        key_state_overlay: *KeyStateOverlay,

        /// The apprt Surface.
        rt_surface: ApprtSurface = undefined,

        /// The core surface backing this GTK surface. This starts out
        /// null because it can't be initialized until there is an available
        /// GLArea that is realized.
        //
        // NOTE(mitchellh): This is a limitation we should definitely remove
        // at some point by modifying our OpenGL renderer for GTK to
        // start in an unrealized state. There are other benefits to being
        // able to initialize the surface early so we should aim for that,
        // eventually.
        core_surface: ?*CoreSurface = null,

        /// Cached metrics for libghostty callbacks
        size: apprt.SurfaceSize,
        cursor_pos: apprt.CursorPos,

        /// Various input method state. All related to key input.
        in_keyevent: IMKeyEvent = .false,
        im_context: *gtk.IMMulticontext,
        im_composing: bool = false,
        im_buf: [128]u8 = undefined,
        im_len: u7 = 0,

        /// True when we have a precision scroll in progress
        precision_scroll: bool = false,

        /// True when the child has exited.
        child_exited: bool = false,

        // Progress bar
        progress_bar_timer: ?c_uint = null,

        // True while the bell is ringing. This will be set to false (after
        // true) under various scenarios, but can also manually be set to
        // false by a parent widget.
        bell_ringing: bool = false,

        /// True if this surface is in an error state. This is currently
        /// a simple boolean with no additional information on WHAT the
        /// error state is, because we don't yet need it or use it. For now,
        /// if this is true, then it means the terminal is non-functional.
        @"error": bool = false,

        /// The source that handles setting our child property.
        idle_rechild: ?c_uint = null,

        /// A weak reference to an inspector window.
        inspector: ?*InspectorWindow = null,

        // True if the current surface is a split, this is used to apply
        // unfocused-split-* options
        is_split: bool = false,

        action_group: ?*gio.SimpleActionGroup = null,

        // Gtk.Scrollable interface adjustments
        hadj: ?*gtk.Adjustment = null,
        vadj: ?*gtk.Adjustment = null,
        hscroll_policy: gtk.ScrollablePolicy = .natural,
        vscroll_policy: gtk.ScrollablePolicy = .natural,
        vadj_signal_group: ?*gobject.SignalGroup = null,

        // Key state tracking for key sequences and tables
        key_sequence: std.ArrayListUnmanaged([:0]const u8) = .empty,
        key_tables: std.ArrayListUnmanaged([:0]const u8) = .empty,

        // Template binds
        child_exited_overlay: *ChildExited,
        context_menu: *gtk.PopoverMenu,
        drop_target: *gtk.DropTarget,
        progress_bar_overlay: *gtk.ProgressBar,
        error_page: *adw.StatusPage,
        terminal_page: *gtk.Overlay,

        /// The context for this surface (window, tab, or split)
        context: apprt.surface.NewSurfaceContext = .window,

        /// Whether primary paste (middle-click paste) is enabled.
        gtk_enable_primary_paste: bool = true,

        /// How much pending horizontal scroll do we have?
        pending_horizontal_scroll: f64 = 0.0,

        /// Timer to reset the amount of horizontal scroll if the user
        /// stops scrolling.
        pending_horizontal_scroll_reset: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn core(self: *Self) ?*CoreSurface {
        const priv = self.private();
        return priv.core_surface;
    }

    pub fn rt(self: *Self) *ApprtSurface {
        const priv = self.private();
        return &priv.rt_surface;
    }

    /// Set the parent of this surface. This will extract the information
    /// required to initialize this surface with the proper values but doesn't
    /// retain any memory.
    ///
    /// If the surface is already realized this does nothing.
    pub fn setParent(
        self: *Self,
        parent: *CoreSurface,
        context: apprt.surface.NewSurfaceContext,
    ) void {
        const priv = self.private();

        // This is a mistake! We can only set a parent before surface
        // realization. We log this because this is probably a logic error.
        if (priv.core_surface != null) {
            log.warn("setParent called after surface is already realized", .{});
            return;
        }

        // Store the context so initSurface can use it
        priv.context = context;

        // Setup our font size
        const font_size_ptr = glib.ext.create(font.face.DesiredSize);
        errdefer glib.ext.destroy(font_size_ptr);
        font_size_ptr.* = parent.font_size;
        priv.font_size_request = font_size_ptr;
        self.as(gobject.Object).notifyByPspec(properties.@"font-size-request".impl.param_spec);

        // Remainder needs a config. If there is no config we just assume
        // we aren't inheriting any of these values.
        if (priv.config) |config_obj| {
            // Setup our cwd if configured to inherit
            if (apprt.surface.shouldInheritWorkingDirectory(context, config_obj.get())) {
                if (parent.rt_surface.surface.getPwd()) |pwd| {
                    priv.pwd = glib.ext.dupeZ(u8, pwd);
                    self.as(gobject.Object).notifyByPspec(properties.pwd.impl.param_spec);
                }
            }
        }
    }

    /// Force the surface to redraw itself. Ghostty often will only redraw
    /// the terminal in reaction to internal changes. If there are external
    /// events that invalidate the surface, such as the widget moving parents,
    /// then we should force a redraw.
    pub fn redraw(self: *Self) void {
        const priv = self.private();
        priv.gl_area.queueRender();
    }

    /// Callback used to determine whether border should be shown around the
    /// surface.
    fn closureShouldBorderBeShown(
        _: *Self,
        config_: ?*Config,
        bell_ringing_: c_int,
    ) callconv(.c) c_int {
        const bell_ringing = bell_ringing_ != 0;

        // If the bell isn't ringing exit early because when the surface is
        // first created there's a race between this code being run and the
        // config being set on the surface. That way we don't overwhelm people
        // with the warning that we issue if the config isn't set and overwhelm
        // ourselves with large numbers of bug reports.
        if (!bell_ringing) return @intFromBool(false);

        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computing whether border should be shown, likely bug", .{});
            return @intFromBool(false);
        };

        return @intFromBool(config.@"bell-features".border);
    }

    /// Callback used to determine whether unfocused-split-fill / unfocused-split-opacity
    /// should be applied to the surface
    fn closureShouldUnfocusedSplitBeShown(
        _: *Self,
        focused: c_int,
        is_split: c_int,
    ) callconv(.c) c_int {
        return @intFromBool(focused == 0 and is_split != 0);
    }

    pub fn toggleFullscreen(self: *Self) void {
        signals.@"toggle-fullscreen".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    pub fn toggleMaximize(self: *Self) void {
        signals.@"toggle-maximize".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    pub fn toggleCommandPalette(self: *Self) bool {
        // TODO: pass the surface with the action
        return self.as(gtk.Widget).activateAction("win.toggle-command-palette", null) != 0;
    }

    pub fn controlInspector(
        self: *Self,
        value: apprt.Action.Value(.inspector),
    ) bool {
        // Let's see if we have an inspector already.
        const priv = self.private();
        if (priv.inspector) |inspector| switch (value) {
            .show => {},
            // Our weak ref will set our private value to null
            .toggle, .hide => inspector.as(gtk.Window).destroy(),
        } else switch (value) {
            .toggle, .show => {
                const inspector = InspectorWindow.new(self);
                inspector.present();
                inspector.as(gobject.Object).weakRef(inspectorWeakNotify, self);
                priv.inspector = inspector;
            },

            .hide => {},
        }

        return true;
    }

    /// Redraw our inspector, if there is one associated with this surface.
    pub fn redrawInspector(self: *Self) void {
        const priv = self.private();
        if (priv.inspector) |v| v.queueRender();
    }

    /// Handle a key sequence action from the apprt.
    pub fn keySequenceAction(
        self: *Self,
        value: apprt.action.KeySequence,
    ) Allocator.Error!void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"key-sequence".impl.param_spec);

        switch (value) {
            .trigger => |trigger| {
                // Convert the trigger to a human-readable label
                var buf: std.Io.Writer.Allocating = .init(alloc);
                defer buf.deinit();
                if (gtk_key.labelFromTrigger(&buf.writer, trigger)) |success| {
                    if (!success) return;
                } else |_| return error.OutOfMemory;

                // Make space
                try priv.key_sequence.ensureUnusedCapacity(alloc, 1);

                // Copy and append
                const duped = try buf.toOwnedSliceSentinel(0);
                errdefer alloc.free(duped);
                priv.key_sequence.appendAssumeCapacity(duped);
            },
            .end => {
                // Free all the stored strings and clear
                for (priv.key_sequence.items) |s| alloc.free(s);
                priv.key_sequence.clearAndFree(alloc);
            },
        }
    }

    /// Handle a key table action from the apprt.
    pub fn keyTableAction(
        self: *Self,
        value: apprt.action.KeyTable,
    ) Allocator.Error!void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"key-table".impl.param_spec);

        switch (value) {
            .activate => |name| {
                // Duplicate the name string and push onto stack
                const duped = try alloc.dupeZ(u8, name);
                errdefer alloc.free(duped);
                try priv.key_tables.append(alloc, duped);
            },
            .deactivate => {
                // Pop and free the top table
                if (priv.key_tables.pop()) |s| alloc.free(s);
            },
            .deactivate_all => {
                // Free all tables and clear
                for (priv.key_tables.items) |s| alloc.free(s);
                priv.key_tables.clearAndFree(alloc);
            },
        }
    }

    pub fn showOnScreenKeyboard(self: *Self, event: ?*gdk.Event) bool {
        const priv = self.private();
        return priv.im_context.as(gtk.IMContext).activateOsk(event) != 0;
    }

    /// Set the scrollbar state for this surface. This will setup the
    /// properties for our Gtk.Scrollable interface properly.
    pub fn setScrollbar(self: *Self, scrollbar: terminal.Scrollbar) void {
        // Update existing adjustment in-place. If we don't have an
        // adjustment then we do nothing because we're not part of a
        // scrolled window.
        const vadj = self.getVAdjustment() orelse return;

        // Check if values match existing adjustment and skip update if so
        const value: f64 = @floatFromInt(scrollbar.offset);
        const upper: f64 = @floatFromInt(scrollbar.total);
        const page_size: f64 = @floatFromInt(scrollbar.len);

        if (std.math.approxEqAbs(f64, vadj.getValue(), value, 0.001) and
            std.math.approxEqAbs(f64, vadj.getUpper(), upper, 0.001) and
            std.math.approxEqAbs(f64, vadj.getPageSize(), page_size, 0.001))
        {
            return;
        }

        // If we have a vadjustment we MUST have the signal group since
        // it is setup in the prop handler.
        const priv = self.private();
        const group = priv.vadj_signal_group.?;

        // During manual scrollbar changes from Ghostty core we don't
        // want to emit value-changed signals so we block them. This would
        // cause a waste of resources at best and infinite loops at worst.
        group.block();
        defer group.unblock();

        vadj.configure(
            value, // value: current scroll position
            0, // lower: minimum value
            upper, // upper: maximum value (total scrollable area)
            1, // step_increment: amount to scroll on arrow click
            page_size, // page_increment: amount to scroll on page up/down
            page_size, // page_size: size of visible area
        );
    }

    /// Set the current progress report state.
    pub fn setProgressReport(
        self: *Self,
        value: terminal.osc.Command.ProgressReport,
    ) void {
        const priv = self.private();

        // No matter what, we stop the timer because if we're removing
        // then we're done and otherwise we restart it.
        if (priv.progress_bar_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove progress bar timer", .{});
            }
            priv.progress_bar_timer = null;
        }

        const progress_bar = priv.progress_bar_overlay;
        switch (value.state) {
            // Remove the progress bar
            .remove => {
                progress_bar.as(gtk.Widget).setVisible(@intFromBool(false));
                return;
            },

            // Set the progress bar to a fixed value if one was provided, otherwise pulse.
            // Remove the `error` CSS class so that the progress bar shows as normal.
            .set => {
                progress_bar.as(gtk.Widget).removeCssClass("error");
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                } else {
                    progress_bar.pulse();
                }
            },

            // Set the progress bar to a fixed value if one was provided, otherwise pulse.
            // Set the `error` CSS class so that the progress bar shows as an error color.
            .@"error" => {
                progress_bar.as(gtk.Widget).addCssClass("error");
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                } else {
                    progress_bar.pulse();
                }
            },

            // The state of progress is unknown, so pulse the progress bar to
            // indicate that things are still happening.
            .indeterminate => {
                progress_bar.pulse();
            },

            // If a progress value was provided, set the progress bar to that value.
            // Don't pulse the progress bar as that would indicate that things were
            // happening. Otherwise this is mainly used to keep the progress bar on
            // screen instead of timing out.
            .pause => {
                if (value.progress) |progress| {
                    progress_bar.setFraction(computeFraction(progress));
                }
            },
        }

        // Assume all states lead to visibility
        assert(value.state != .remove);
        progress_bar.as(gtk.Widget).setVisible(@intFromBool(true));

        // Start our timer to remove bad actor programs that stall
        // the progress bar.
        const progress_bar_timeout_seconds = 15;
        assert(priv.progress_bar_timer == null);
        priv.progress_bar_timer = glib.timeoutAdd(
            progress_bar_timeout_seconds * std.time.ms_per_s,
            progressBarTimer,
            self,
        );
    }

    /// The progress bar hasn't been updated by the TUI recently, remove it.
    fn progressBarTimer(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud.?));
        const priv = self.private();
        priv.progress_bar_timer = null;
        self.setProgressReport(.{ .state = .remove });
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Request that this terminal come to the front and become focused.
    /// It is up to the embedding widget to react to this.
    pub fn present(self: *Self) void {
        signals.@"present-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    pub fn commandFinished(self: *Self, value: apprt.Action.Value(.command_finished)) bool {
        const app = Application.default();
        const alloc = app.allocator();
        const priv: *Private = self.private();

        const notify_next_command_finish = notify: {
            const simple_action_group = priv.action_group orelse break :notify false;
            const action_group = simple_action_group.as(gio.ActionGroup);
            const state = action_group.getActionState("notify-on-next-command-finish") orelse break :notify false;
            const bool_variant_type = glib.ext.VariantType.newFor(bool);
            defer bool_variant_type.free();
            if (state.isOfType(bool_variant_type) == 0) break :notify false;
            const notify = state.getBoolean() != 0;
            action_group.changeActionState("notify-on-next-command-finish", glib.Variant.newBoolean(@intFromBool(false)));
            break :notify notify;
        };

        const config = priv.config orelse return false;

        const cfg = config.get();

        if (!notify_next_command_finish) {
            if (cfg.@"notify-on-command-finish" == .never) return true;
            if (cfg.@"notify-on-command-finish" == .unfocused and self.getFocused()) return true;
        }

        if (value.duration.lte(cfg.@"notify-on-command-finish-after")) return true;

        const action = cfg.@"notify-on-command-finish-action";

        if (action.bell) self.setBellRinging(true);

        if (action.notify) notify: {
            const title = std.mem.span(title: {
                const exit_code = value.exit_code orelse break :title i18n._("Command Finished");
                if (exit_code == 0) break :title i18n._("Command Succeeded");
                break :title i18n._("Command Failed");
            });

            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            const writer = &buf.writer;

            writer.writeAll("Command ") catch break :notify;

            if (value.command_line) |command_line| command_line: {
                // Don't bother with a zero length command line.
                if (command_line.len == 0) break :command_line;
                // The defacto standard for "hiding" a command line from being
                // saved in history or other places is to prefix it with a
                // space. Honor that here.
                if (command_line[0] == ' ') {
                    writer.writeAll("«hidden» ") catch break :notify;
                    break :command_line;
                }
                writer.writeAll("“") catch break :notify;
                writer.writeAll(command_line) catch break :notify;
                writer.writeAll("” ") catch break :notify;
            }

            writer.print(
                "took {f}",
                .{value.duration.round(std.time.ns_per_ms)},
            ) catch break :notify;

            if (value.exit_code) |exit_code| {
                writer.print(" and exited with code {d}", .{exit_code}) catch break :notify;
            }

            writer.writeByte('.') catch break :notify;

            const body = buf.toOwnedSliceSentinel(0) catch break :notify;
            defer alloc.free(body);

            self.sendDesktopNotification(title, body);
        }

        return true;
    }

    /// Get the readonly state from the core surface.
    pub fn getReadonly(self: *Self) bool {
        const priv: *Private = self.private();
        const surface = priv.core_surface orelse return false;
        return surface.readonly;
    }

    /// Notify anyone interested that the readonly status has changed.
    pub fn setReadonly(self: *Self, _: apprt.Action.Value(.readonly)) bool {
        self.as(gobject.Object).notifyByPspec(properties.readonly.impl.param_spec);

        return true;
    }

    /// Key press event (press or release).
    ///
    /// At a high level, we want to construct an `input.KeyEvent` and
    /// pass that to `keyCallback`. At a low level, this is more complicated
    /// than it appears because we need to construct all of this information
    /// and its not given to us.
    ///
    /// For all events, we run the GdkEvent through the input method context.
    /// This allows the input method to capture the event and trigger
    /// callbacks such as preedit, commit, etc.
    ///
    /// There are a couple important aspects to the prior paragraph: we must
    /// send ALL events through the input method context. This is because
    /// input methods use both key press and key release events to determine
    /// the state of the input method. For example, fcitx uses key release
    /// events on modifiers (i.e. ctrl+shift) to switch the input method.
    ///
    /// We set some state to note we're in a key event (self.in_keyevent)
    /// because some of the input method callbacks change behavior based on
    /// this state. For example, we don't want to send character events
    /// like "a" via the input "commit" event if we're actively processing
    /// a keypress because we'd lose access to the keycode information.
    /// However, a "commit" event may still happen outside of a keypress
    /// event from e.g. a tablet or on-screen keyboard.
    ///
    /// Finally, we take all of the information in order to determine if we have
    /// a unicode character or if we have to map the keyval to a code to
    /// get the underlying logical key, etc.
    ///
    /// Then we can emit the keyCallback.
    pub fn keyEvent(
        self: *Surface,
        action: input.Action,
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
    ) bool {
        //log.warn("keyEvent action={}", .{action});
        const event = ec_key.as(gtk.EventController).getCurrentEvent() orelse return false;
        const key_event = gobject.ext.cast(gdk.KeyEvent, event) orelse return false;
        const priv = self.private();

        // The block below is all related to input method handling. See the function
        // comment for some high level details and then the comments within
        // the block for more specifics.
        {
            // This can trigger an input method so we need to notify the im context
            // where the cursor is so it can render the dropdowns in the correct
            // place.
            if (priv.core_surface) |surface| {
                const ime_point = surface.imePoint();
                priv.im_context.as(gtk.IMContext).setCursorLocation(&.{
                    .f_x = @intFromFloat(ime_point.x),
                    .f_y = @intFromFloat(ime_point.y),
                    .f_width = 1,
                    .f_height = 1,
                });
            }

            // We note that we're in a keypress because we want some logic to
            // depend on this. For example, we don't want to send character events
            // like "a" via the input "commit" event if we're actively processing
            // a keypress because we'd lose access to the keycode information.
            //
            // We have to maintain some additional state here of whether we
            // were composing because different input methods call the callbacks
            // in different orders. For example, ibus calls commit THEN preedit
            // end but simple calls preedit end THEN commit.
            priv.in_keyevent = if (priv.im_composing) .composing else .not_composing;
            defer priv.in_keyevent = .false;

            // Pass the event through the input method which returns true if handled.
            // Confusingly, not all events handled by the input method result
            // in this returning true so we have to maintain some additional
            // state about whether we were composing or not to determine if
            // we should proceed with key encoding.
            //
            // Cases where the input method does not mark the event as handled:
            //
            // - If we change the input method via keypress while we have preedit
            //   text, the input method will commit the pending text but will not
            //   mark it as handled. We use the `.composing` state to detect
            //   this case.
            //
            // - If we switch input methods (i.e. via ctrl+shift with fcitx),
            //   the input method will handle the key release event but will not
            //   mark it as handled. I don't know any way to detect this case so
            //   it will result in a key event being sent to the key callback.
            //   For Kitty text encoding, this will result in modifiers being
            //   triggered despite being technically consumed. At the time of
            //   writing, both Kitty and Alacritty have the same behavior. I
            //   know of no way to fix this.
            const im_handled = priv.im_context.as(gtk.IMContext).filterKeypress(event) != 0;
            // log.warn("GTKIM: im_handled={} im_len={} im_composing={}", .{
            //     im_handled,
            //     self.im_len,
            //     self.im_composing,
            // });

            // If the input method handled the event, you would think we would
            // never proceed with key encoding for Ghostty but that is not the
            // case. Input methods will handle basic character encoding like
            // typing "a" and we want to associate that with the key event.
            // So we have to check additional state to determine if we exit.
            if (im_handled) {
                // If we are composing then we're in a preedit state and do
                // not want to encode any keys. For example: type a deadkey
                // such as single quote on a US international keyboard layout.
                if (priv.im_composing) return true;

                // If we were composing and now we're not, it means that we committed
                // the text. We also don't want to encode a key event for this.
                // Example: enable Japanese input method, press "konn" and then
                // press enter. The final enter should not be encoded and "konn"
                // (in hiragana) should be written as "こん".
                if (priv.in_keyevent == .composing) return true;

                // Not composing and our input method buffer is empty. This could
                // mean that the input method reacted to this event by activating
                // an onscreen keyboard or something equivalent. We don't know.
                // But the input method handled it and didn't give us text so
                // we will just assume we should not encode this. This handles a
                // real scenario when ibus starts the emoji input method
                // (super+.).
                if (priv.im_len == 0) return true;
            }

            // At this point, for the sake of explanation of internal state:
            // it is possible that im_len > 0 and im_composing == false. This
            // means that we received a commit event from the input method that
            // we want associated with the key event. This is common: its how
            // basic character translation for simple inputs like "a" work.
        }

        // We always reset the length of the im buffer. There's only one scenario
        // we reach this point with im_len > 0 and that's if we received a commit
        // event from the input method. We don't want to keep that state around
        // since we've handled it here.
        defer priv.im_len = 0;

        // Get the keyvals for this event.
        const keyval_unicode = gdk.keyvalToUnicode(keyval);
        const keyval_unicode_unshifted: u21 = gtk_key.keyvalUnicodeUnshifted(
            priv.gl_area.as(gtk.Widget),
            key_event,
            keycode,
        );

        // We want to get the physical unmapped key to process physical keybinds.
        // (These are keybinds explicitly marked as requesting physical mapping).
        const physical_key = keycode: {
            const w3c_key: input.Key = w3c: for (input.keycodes.entries) |entry| {
                if (entry.native == keycode) break :w3c entry.key;
            } else .unidentified;

            // Consult the pre-remapped XKB keyval/keysym to get the (possibly)
            // remapped key. If the W3C key or the remapped key
            // is eligible for remapping, we use it.
            //
            // See the docs for `shouldBeRemappable` for why we even have to
            // do this in the first place.
            if (gtk_key.keyFromKeyval(keyval)) |remapped| {
                if (w3c_key.shouldBeRemappable() or remapped.shouldBeRemappable())
                    break :keycode remapped;
            }

            // Return the original physical key
            break :keycode w3c_key;
        };

        // Get our modifier for the event
        const mods: input.Mods = gtk_key.eventMods(
            event,
            physical_key,
            gtk_mods,
            action,
            Application.default().winproto(),
        );

        // Get our consumed modifiers
        const consumed_mods: input.Mods = consumed: {
            const T = @typeInfo(gdk.ModifierType);
            std.debug.assert(T.@"struct".layout == .@"packed");
            const I = T.@"struct".backing_integer.?;

            const masked = @as(I, @bitCast(key_event.getConsumedModifiers())) & @as(I, gdk.MODIFIER_MASK);
            break :consumed gtk_key.translateMods(@bitCast(masked));
        };

        // log.debug("key pressed key={} keyval={x} physical_key={} composing={} text_len={} mods={}", .{
        //     key,
        //     keyval,
        //     physical_key,
        //     priv.im_composing,
        //     priv.im_len,
        //     mods,
        // });

        // If we have no UTF-8 text, we try to convert our keyval to
        // a text value. We have to do this because GTK will not process
        // "Ctrl+Shift+1" (on US keyboards) as "Ctrl+!" but instead as "".
        // But the keyval is set correctly so we can at least extract that.
        if (priv.im_len == 0 and keyval_unicode > 0) im: {
            if (std.math.cast(u21, keyval_unicode)) |cp| {
                // We don't want to send control characters as IM
                // text. Control characters are handled already by
                // the encoder directly.
                if (cp < 0x20) break :im;

                if (std.unicode.utf8Encode(cp, &priv.im_buf)) |len| {
                    priv.im_len = len;
                } else |_| {}
            }
        }

        // Invoke the core Ghostty logic to handle this input.
        const surface = priv.core_surface orelse return false;
        const effect = surface.keyCallback(.{
            .action = action,
            .key = physical_key,
            .mods = mods,
            .consumed_mods = consumed_mods,
            .composing = priv.im_composing,
            .utf8 = priv.im_buf[0..priv.im_len],
            .unshifted_codepoint = keyval_unicode_unshifted,
        }) catch |err| {
            log.err("error in key callback err={}", .{err});
            return false;
        };

        switch (effect) {
            .closed => return true,
            .ignored => {},
            .consumed => if (action == .press or action == .repeat) {
                // If we were in the composing state then we reset our context.
                // We do NOT want to reset if we're not in the composing state
                // because there is other IME state that we want to preserve,
                // such as quotation mark ordering for Chinese input.
                if (priv.im_composing) {
                    priv.im_context.as(gtk.IMContext).reset();
                    surface.preeditCallback(null) catch {};
                }

                // Bell stops ringing when any key is pressed that is used by
                // the core in any way.
                self.setBellRinging(false);

                return true;
            },
        }

        return false;
    }

    /// Prompt for a manual title change for the surface.
    pub fn promptTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.surface, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Scale x/y by the GDK device scale.
    fn scaledCoordinates(
        self: *Self,
        x: f64,
        y: f64,
    ) struct { x: f64, y: f64 } {
        const gl_area = self.private().gl_area;
        const scale_factor: f64 = @floatFromInt(
            gl_area.as(gtk.Widget).getScaleFactor(),
        );

        return .{
            .x = x * scale_factor,
            .y = y * scale_factor,
        };
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn close(self: *Self) void {
        signals.@"close-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    pub fn childExited(
        self: *Self,
        data: apprt.surface.Message.ChildExited,
    ) bool {
        // Even if we don't support the overlay, we still keep our property
        // up to date for anyone listening.
        const priv = self.private();
        priv.child_exited = true;
        self.as(gobject.Object).notifyByPspec(
            properties.@"child-exited".impl.param_spec,
        );

        // If we have the noop child exited overlay then we don't do anything
        // for child exited. The false return will force libghostty to show
        // the normal text-based message.
        if (comptime @hasDecl(ChildExited, "noop")) {
            return false;
        }

        priv.child_exited_overlay.setData(&data);
        return true;
    }

    pub fn getContentScale(self: *Self) apprt.ContentScale {
        const priv = self.private();
        const gl_area = priv.gl_area;

        const gtk_scale: f32 = scale: {
            const widget = gl_area.as(gtk.Widget);
            // Future: detect GTK version 4.12+ and use gdk_surface_get_scale so we
            // can support fractional scaling.
            const scale = widget.getScaleFactor();
            if (scale <= 0) {
                log.warn("gtk_widget_get_scale_factor returned a non-positive number: {}", .{scale});
                break :scale 1.0;
            }
            break :scale @floatFromInt(scale);
        };

        // Also scale using font-specific DPI, which is often exposed to the user
        // via DE accessibility settings (see https://docs.gtk.org/gtk4/class.Settings.html).
        const xft_dpi_scale = xft_scale: {
            // gtk-xft-dpi is font DPI multiplied by 1024. See
            // https://docs.gtk.org/gtk4/property.Settings.gtk-xft-dpi.html
            const gtk_xft_dpi = gsettings.get(.@"gtk-xft-dpi") orelse {
                log.warn("gtk-xft-dpi was not set, using default value", .{});
                break :xft_scale 1.0;
            };

            // Use a value of 1.0 for the XFT DPI scale if the setting is <= 0
            // See:
            // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/a7738a4d269bfdf4d8d5429ca73ccdd9b2450421
            // https://gitlab.gnome.org/GNOME/libadwaita/-/commit/9759d3fd81129608dd78116001928f2aed974ead
            if (gtk_xft_dpi <= 0) {
                log.warn("gtk-xft-dpi has invalid value ({}), using default", .{gtk_xft_dpi});
                break :xft_scale 1.0;
            }

            // As noted above gtk-xft-dpi is multiplied by 1024, so we divide by
            // 1024, then divide by the default value (96) to derive a scale. Note
            // gtk-xft-dpi can be fractional, so we use floating point math here.
            const xft_dpi: f32 = @as(f32, @floatFromInt(gtk_xft_dpi)) / 1024.0;
            break :xft_scale xft_dpi / 96.0;
        };

        const scale = gtk_scale * xft_dpi_scale;
        return .{ .x = scale, .y = scale };
    }

    pub fn getSize(self: *Self) apprt.SurfaceSize {
        const priv = self.private();
        // By the time this is called, we should be in a widget tree.
        // This should not be called before that. We ensure this by initializing
        // the surface in `glareaResize`. This is VERY important because it
        // avoids the pty having an incorrect initial size.
        assert(priv.size.width >= 0 and priv.size.height >= 0);
        return priv.size;
    }

    pub fn getCursorPos(self: *Self) apprt.CursorPos {
        return self.private().cursor_pos;
    }

    pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
        const app = Application.default();
        const alloc = app.allocator();
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (app.savedLanguage()) |language| {
            try env.put("LANG", language);
        } else {
            env.remove("LANG");
        }

        // Don't leak these GTK environment variables to child processes.
        env.remove("GDK_DEBUG");
        env.remove("GDK_DISABLE");
        env.remove("GSK_RENDERER");

        // Remove some environment variables that are set when Ghostty is launched
        // from a `.desktop` file, by D-Bus activation, or systemd.
        env.remove("GIO_LAUNCHED_DESKTOP_FILE");
        env.remove("GIO_LAUNCHED_DESKTOP_FILE_PID");
        env.remove("DBUS_STARTER_ADDRESS");
        env.remove("DBUS_STARTER_BUS_TYPE");
        env.remove("INVOCATION_ID");
        env.remove("JOURNAL_STREAM");
        env.remove("NOTIFY_SOCKET");

        // Unset environment varies set by snaps if we're running in a snap.
        // This allows Ghostty to further launch additional snaps.
        if (comptime build_config.snap) {
            if (env.get("SNAP") != null) try filterSnapPaths(
                alloc,
                &env,
            );
        }

        // This is a hack because it ties ourselves (optionally) to the
        // Window class. The right solution we should do is emit a signal
        // here where the handler can modify our EnvMap, but boxing the
        // EnvMap is a bit annoying so I'm punting it.
        if (ext.getAncestor(Window, self.as(gtk.Widget))) |window| {
            try window.winproto().addSubprocessEnv(&env);

            if (window.isQuickTerminal()) {
                try env.put("GHOSTTY_QUICK_TERMINAL", "1");
            }
        }

        return env;
    }

    /// Filter out environment variables that start with forbidden prefixes.
    fn filterSnapPaths(gpa: std.mem.Allocator, env_map: *std.process.EnvMap) !void {
        comptime assert(build_config.snap);

        const snap_vars = [_][]const u8{
            "SNAP",
            "SNAP_USER_COMMON",
            "SNAP_USER_DATA",
            "SNAP_DATA",
            "SNAP_COMMON",
        };

        // Use an arena because everything in this function is temporary.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var env_to_remove: std.ArrayList([]const u8) = .empty;
        var env_to_update: std.ArrayList(struct {
            key: []const u8,
            value: []const u8,
        }) = .empty;

        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // Ignore fields we set ourself
            if (std.mem.eql(u8, key, "TERMINFO")) continue;
            if (std.mem.startsWith(u8, key, "GHOSTTY")) continue;

            // Any env var starting with SNAP must be removed
            if (std.mem.startsWith(u8, key, "SNAP_")) {
                try env_to_remove.append(alloc, key);
                continue;
            }

            var filtered_paths: std.ArrayList([]const u8) = .empty;
            var modified = false;
            var paths = std.mem.splitAny(u8, value, ":");
            while (paths.next()) |path| {
                var include = true;
                for (snap_vars) |k| if (env_map.get(k)) |snap_path| {
                    if (snap_path.len == 0) continue;
                    if (std.mem.startsWith(u8, path, snap_path)) {
                        include = false;
                        modified = true;
                        break;
                    }
                };
                if (include) try filtered_paths.append(alloc, path);
            }

            if (modified) {
                if (filtered_paths.items.len > 0) {
                    const new_value = try std.mem.join(alloc, ":", filtered_paths.items);
                    try env_to_update.append(alloc, .{ .key = key, .value = new_value });
                } else {
                    try env_to_remove.append(alloc, key);
                }
            }
        }

        for (env_to_update.items) |item| try env_map.put(
            item.key,
            item.value,
        );
        for (env_to_remove.items) |key| _ = env_map.remove(key);
    }

    pub fn clipboardRequest(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        return try Clipboard.request(
            self,
            clipboard_type,
            state,
        );
    }

    pub fn setClipboard(
        self: *Self,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        Clipboard.set(
            self,
            clipboard_type,
            contents,
            confirm,
        );
    }

    /// Focus this surface. This properly focuses the input part of
    /// our surface.
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.gl_area.as(gtk.Widget).grabFocus();
    }

    pub fn sendDesktopNotification(self: *Self, title: [:0]const u8, body: [:0]const u8) void {
        const app = Application.default();
        const priv: *Private = self.private();

        const core_surface = priv.core_surface orelse {
            log.warn("can't send notification because there is no core surface", .{});
            return;
        };

        const t = switch (title.len) {
            0 => "Ghostty",
            else => title,
        };

        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(body);

        const icon = gio.ThemedIcon.new("com.mitchellh.ghostty");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));

        const pointer = glib.Variant.newUint64(@intFromPtr(core_surface));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            pointer,
        );

        // We set the notification ID to the body content. If the content is the
        // same, this notification may replace a previous notification
        const gio_app = app.as(gio.Application);
        gio_app.sendNotification(body, notification);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActionMap();

        const priv = self.private();

        // Initialize some private fields so they aren't undefined
        priv.rt_surface = .{ .surface = self };
        priv.precision_scroll = false;
        priv.cursor_pos = .{ .x = 0, .y = 0 };
        priv.mouse_shape = .text;
        priv.mouse_hidden = false;
        priv.focused = true;
        priv.size = .{ .width = 0, .height = 0 };
        priv.vadj_signal_group = null;

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        // Setup our input method state
        priv.in_keyevent = .false;
        priv.im_composing = false;
        priv.im_len = 0;

        // Read GTK primary paste setting
        priv.gtk_enable_primary_paste = gsettings.get(.@"gtk-enable-primary-paste") orelse true;

        // Set up to handle items being dropped on our surface. Files can be dropped
        // from Nautilus and strings can be dropped from many programs. The order
        // of these types matter.
        var drop_target_types = [_]gobject.Type{
            gdk.FileList.getGObjectType(),
            gio.File.getGObjectType(),
            gobject.ext.types.string,
        };
        priv.drop_target.setGtypes(&drop_target_types, drop_target_types.len);

        // Setup properties we can't set from our Blueprint file.
        self.as(gtk.Widget).setCursorFromName("text");

        // Initialize our config
        self.propConfig(undefined, null);
    }

    fn initActionMap(self: *Self) void {
        const priv: *Private = self.private();

        const actions = [_]ext.actions.Action(Self){
            .init(
                "prompt-title",
                actionPromptTitle,
                null,
            ),
            .initStateful(
                "notify-on-next-command-finish",
                actionNotifyOnNextCommandFinish,
                null,
                glib.Variant.newBoolean(@intFromBool(false)),
            ),
        };

        priv.action_group = ext.actions.addAsGroup(Self, self, "surface", &actions);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        if (priv.vadj_signal_group) |group| {
            group.setTarget(null);
            group.as(gobject.Object).unref();
            priv.vadj_signal_group = null;
        }

        if (priv.hadj) |v| {
            v.as(gobject.Object).unref();
            priv.hadj = null;
        }

        if (priv.vadj) |v| {
            v.as(gobject.Object).unref();
            priv.vadj = null;
        }

        if (priv.progress_bar_timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove progress bar timer", .{});
            }
            priv.progress_bar_timer = null;
        }

        if (priv.idle_rechild) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle_rechild = null;
        }

        if (priv.pending_horizontal_scroll_reset) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove pending horizontal scroll reset source", .{});
            }
            priv.pending_horizontal_scroll_reset = null;
        }

        // This works around a GTK double-free bug where if you bind
        // to a top-level template child, it frees twice if the widget is
        // also the root child of the template. By unsetting the child here,
        // we avoid the double-free.
        self.as(adw.Bin).setChild(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.core_surface) |v| {
            // Remove ourselves from the list of known surfaces in the app.
            // We do this before deinit in case a callback triggers
            // searching for this surface.
            Application.default().core().deleteSurface(self.rt());

            // NOTE: We must deinit the surface in the finalize call and NOT
            // the dispose call because the inspector widget relies on this
            // behavior with a weakRef to properly deactivate.

            // Deinit the surface
            v.deinit();
            const alloc = Application.default().allocator();
            alloc.destroy(v);

            priv.core_surface = null;
        }
        if (priv.mouse_hover_url) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.mouse_hover_url = null;
        }
        if (priv.default_size) |v| {
            ext.boxedFree(Size, v);
            priv.default_size = null;
        }
        if (priv.font_size_request) |v| {
            glib.ext.destroy(v);
            priv.font_size_request = null;
        }
        if (priv.min_size) |v| {
            ext.boxedFree(Size, v);
            priv.min_size = null;
        }
        if (priv.pwd) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.pwd = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        // Clean up key sequence and key table state
        const alloc = Application.default().allocator();
        for (priv.key_sequence.items) |s| alloc.free(s);
        priv.key_sequence.deinit(alloc);
        for (priv.key_tables.items) |s| alloc.free(s);
        priv.key_tables.deinit(alloc);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns the title property without a copy.
    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    /// Returns the effective title: the user-overridden title if set,
    /// otherwise the terminal-set title.
    pub fn getEffectiveTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        return priv.title_override orelse priv.title;
    }

    /// Copies the effective title to the clipboard.
    pub fn copyTitleToClipboard(self: *Self) bool {
        const title = self.getEffectiveTitle() orelse return false;
        if (title.len == 0) return false;
        self.setClipboard(.standard, &.{.{
            .mime = "text/plain",
            .data = title,
        }}, false);
        return true;
    }

    /// Set the title for this surface, copies the value. This should always
    /// be the title as set by the terminal program, not any manually set
    /// title. For manually set titles see `setTitleOverride`.
    pub fn setTitle(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title = null;
        if (title) |v| priv.title = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.title.impl.param_spec);
    }

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }

    /// Returns the pwd property without a copy.
    pub fn getPwd(self: *Self) ?[:0]const u8 {
        return self.private().pwd;
    }

    /// Set the pwd for this surface, copies the value.
    pub fn setPwd(self: *Self, pwd: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.pwd) |v| glib.free(@ptrCast(@constCast(v)));
        priv.pwd = null;
        if (pwd) |v| priv.pwd = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.pwd.impl.param_spec);
    }

    /// Returns the focus state of this surface.
    pub fn getFocused(self: *Self) bool {
        return self.private().focused;
    }

    /// Change the configuration for this surface.
    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        if (priv.config) |c| c.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);
    }

    /// Return the default size, if set.
    pub fn getDefaultSize(self: *Self) ?*Size {
        const priv = self.private();
        return priv.default_size;
    }

    /// Set the default size for a window that contains this surface.
    /// This is up to the embedding widget to respect this. Generally, only
    /// the first surface in a window respects this.
    pub fn setDefaultSize(self: *Self, size: Size) void {
        const priv = self.private();
        if (priv.default_size) |v| ext.boxedFree(
            Size,
            v,
        );
        priv.default_size = ext.boxedCopy(
            Size,
            &size,
        );
        self.as(gobject.Object).notifyByPspec(properties.@"default-size".impl.param_spec);
    }

    /// Get the key sequence list. Full transfer.
    fn getKeySequence(self: *Self) ?*ext.StringList {
        const priv = self.private();
        const alloc = Application.default().allocator();
        return ext.StringList.create(alloc, priv.key_sequence.items) catch null;
    }

    /// Get the key table list. Full transfer.
    fn getKeyTable(self: *Self) ?*ext.StringList {
        const priv = self.private();
        const alloc = Application.default().allocator();
        return ext.StringList.create(alloc, priv.key_tables.items) catch null;
    }

    /// Return the min size, if set.
    pub fn getMinSize(self: *Self) ?*Size {
        const priv = self.private();
        return priv.min_size;
    }

    /// Set the min size for a window that contains this surface.
    /// This is up to the embedding widget to respect this. Generally, only
    /// the first surface in a window respects this.
    pub fn setMinSize(self: *Self, size: Size) void {
        const priv = self.private();
        if (priv.min_size) |v| ext.boxedFree(
            Size,
            v,
        );
        priv.min_size = ext.boxedCopy(
            Size,
            &size,
        );
        self.as(gobject.Object).notifyByPspec(properties.@"min-size".impl.param_spec);
    }

    pub fn getMouseShape(self: *Self) terminal.MouseShape {
        return self.private().mouse_shape;
    }

    pub fn setMouseShape(self: *Self, shape: terminal.MouseShape) void {
        const priv = self.private();
        priv.mouse_shape = shape;
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-shape".impl.param_spec);
    }

    pub fn getMouseHidden(self: *Self) bool {
        return self.private().mouse_hidden;
    }

    pub fn setMouseHidden(self: *Self, hidden: bool) void {
        const priv = self.private();
        priv.mouse_hidden = hidden;
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-hidden".impl.param_spec);
    }

    pub fn setMouseHoverUrl(self: *Self, url: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.mouse_hover_url) |v| glib.free(@ptrCast(@constCast(v)));
        priv.mouse_hover_url = null;
        if (url) |v| priv.mouse_hover_url = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"mouse-hover-url".impl.param_spec);
    }

    pub fn getBellRinging(self: *Self) bool {
        return self.private().bell_ringing;
    }

    pub fn setBellRinging(self: *Self, ringing: bool) void {
        // Prevent duplicate change notifications if the signals we emit
        // in this function cause this state to change again.
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();

        // Logic around bell reaction happens on every event even if we're
        // already in the ringing state.
        if (ringing) self.ringBell();

        // Property change only happens on actual state change
        const priv = self.private();
        if (priv.bell_ringing == ringing) return;
        priv.bell_ringing = ringing;
        self.as(gobject.Object).notifyByPspec(properties.@"bell-ringing".impl.param_spec);
    }

    pub fn setError(self: *Self, v: bool) void {
        const priv = self.private();
        priv.@"error" = v;
        self.as(gobject.Object).notifyByPspec(properties.@"error".impl.param_spec);
    }

    pub fn setSearchActive(self: *Self, active: bool, needle: [:0]const u8) void {
        const priv = self.private();
        var value = gobject.ext.Value.newFrom(active);
        defer value.unset();
        gobject.Object.setProperty(
            priv.search_overlay.as(gobject.Object),
            SearchOverlay.properties.active.name,
            &value,
        );

        if (!std.mem.eql(u8, needle, "")) {
            priv.search_overlay.setSearchContents(needle);
        }

        if (active) {
            priv.search_overlay.grabFocus();
        }
    }

    pub fn setSearchTotal(self: *Self, total: ?usize) void {
        self.private().search_overlay.setSearchTotal(total);
    }

    pub fn setSearchSelected(self: *Self, selected: ?usize) void {
        self.private().search_overlay.setSearchSelected(selected);
    }

    fn propConfig(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |c| c.get() else return;

        // resize-overlay-duration
        {
            const ms = config.@"resize-overlay-duration".asMilliseconds();
            var value = gobject.ext.Value.newFrom(ms);
            defer value.unset();
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "duration",
                &value,
            );
        }

        // resize-overlay-position
        {
            const hv: struct {
                gtk.Align, // halign
                gtk.Align, // valign
            } = switch (config.@"resize-overlay-position") {
                .center => .{ .center, .center },
                .@"top-left" => .{ .start, .start },
                .@"top-right" => .{ .end, .start },
                .@"top-center" => .{ .center, .start },
                .@"bottom-left" => .{ .start, .end },
                .@"bottom-right" => .{ .end, .end },
                .@"bottom-center" => .{ .center, .end },
            };

            var halign = gobject.ext.Value.newFrom(hv[0]);
            defer halign.unset();
            var valign = gobject.ext.Value.newFrom(hv[1]);
            defer valign.unset();
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "overlay-halign",
                &halign,
            );
            gobject.Object.setProperty(
                priv.resize_overlay.as(gobject.Object),
                "overlay-valign",
                &valign,
            );
        }
    }

    fn propError(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.@"error") {
            // Ensure we have an opaque background. The window will NOT set
            // this if we have transparency set and we need an opaque
            // background for the error message to be readable.
            self.as(gtk.Widget).addCssClass("background");
        } else {
            // Regardless of transparency setting, we remove the background
            // CSS class from this widget. Parent widgets will set it
            // appropriately (see window.zig for example).
            self.as(gtk.Widget).removeCssClass("background");
        }

        // We need to set our child property on an idle tick, because the
        // error property can be triggered by signals that are in the middle
        // of widget mapping and changing our child during that time
        // results in a hard gtk crash.
        if (priv.idle_rechild == null) priv.idle_rechild = glib.idleAdd(
            onIdleRechild,
            self,
        );
    }

    fn onIdleRechild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.idle_rechild = null;
        if (priv.@"error") {
            self.as(adw.Bin).setChild(priv.error_page.as(gtk.Widget));
        } else {
            self.as(adw.Bin).setChild(priv.terminal_page.as(gtk.Widget));
        }
        return 0;
    }

    fn propMouseHoverUrl(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const visible = if (priv.mouse_hover_url) |v| v.len > 0 else false;
        priv.url_left.as(gtk.Widget).setVisible(if (visible) 1 else 0);
    }

    fn propMouseHidden(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // If we're hidden we set it to "none"
        if (priv.mouse_hidden) {
            self.as(gtk.Widget).setCursorFromName("none");
            return;
        }

        // If we're not hidden we just trigger the mouse shape
        // prop notification to handle setting the proper mouse shape.
        self.propMouseShape(undefined, null);
    }

    fn propMouseShape(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // If our mouse should be hidden currently then we don't
        // do anything.
        if (priv.mouse_hidden) return;

        const name: [:0]const u8 = switch (priv.mouse_shape) {
            .default => "default",
            .help => "help",
            .pointer => "pointer",
            .context_menu => "context-menu",
            .progress => "progress",
            .wait => "wait",
            .cell => "cell",
            .crosshair => "crosshair",
            .text => "text",
            .vertical_text => "vertical-text",
            .alias => "alias",
            .copy => "copy",
            .no_drop => "no-drop",
            .move => "move",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
            .all_scroll => "all-scroll",
            .col_resize => "col-resize",
            .row_resize => "row-resize",
            .n_resize => "n-resize",
            .e_resize => "e-resize",
            .s_resize => "s-resize",
            .w_resize => "w-resize",
            .ne_resize => "ne-resize",
            .nw_resize => "nw-resize",
            .se_resize => "se-resize",
            .sw_resize => "sw-resize",
            .ew_resize => "ew-resize",
            .ns_resize => "ns-resize",
            .nesw_resize => "nesw-resize",
            .nwse_resize => "nwse-resize",
            .zoom_in => "zoom-in",
            .zoom_out => "zoom-out",
        };

        // Set our new cursor.
        self.as(gtk.Widget).setCursorFromName(name.ptr);
    }

    fn vadjValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        // This will trigger for every single pixel change in the adjustment,
        // but our core surface handles the noise from this so that identical
        // rows are cheap.
        const core_surface = self.core() orelse return;
        const row: usize = @intFromFloat(@round(adj.getValue()));
        _ = core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
            log.err("error performing scroll_to_row action err={}", .{err});
        };
    }

    fn propVAdjustment(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // When vadjustment is first set, we setup the signal group lazily.
        // This makes it so that if we don't use scrollbars, we never
        // pay the memory cost of this.
        const group: *gobject.SignalGroup = priv.vadj_signal_group orelse group: {
            const group = gobject.SignalGroup.new(gtk.Adjustment.getGObjectType());
            group.connect(
                "value-changed",
                @ptrCast(&vadjValueChanged),
                self,
            );

            priv.vadj_signal_group = group;
            break :group group;
        };

        // Setup our signal group target
        group.setTarget(if (priv.vadj) |v| v.as(gobject.Object) else null);
    }

    /// Handle bell features that need to happen every time a BEL is received
    /// Currently this is audio and system but this could change in the future.
    fn ringBell(self: *Self) void {
        const priv = self.private();

        // Emit the signal
        signals.bell.impl.emit(
            self,
            null,
            .{},
            null,
        );

        // Activate actions if they exist
        _ = self.as(gtk.Widget).activateAction("tab.ring-bell", null);
        _ = self.as(gtk.Widget).activateAction("win.ring-bell", null);

        const config = if (priv.config) |c| c.get() else return;

        // Do our sound
        if (config.@"bell-features".audio) audio: {
            const config_path = config.@"bell-audio-path" orelse break :audio;
            const path, const required = switch (config_path) {
                .optional => |path| .{ path, false },
                .required => |path| .{ path, true },
            };

            const volume = std.math.clamp(
                config.@"bell-audio-volume",
                0.0,
                1.0,
            );

            assert(std.fs.path.isAbsolute(path));
            const media_file = gtk.MediaFile.newForFilename(path);

            // If the audio file is marked as required, we'll emit an error if
            // there was a problem playing it. Otherwise there will be silence.
            if (required) {
                _ = gobject.Object.signals.notify.connect(
                    media_file,
                    ?*anyopaque,
                    mediaFileError,
                    null,
                    .{ .detail = "error" },
                );
            }

            // Watch for the "ended" signal so that we can clean up after
            // ourselves.
            _ = gobject.Object.signals.notify.connect(
                media_file,
                ?*anyopaque,
                mediaFileEnded,
                null,
                .{ .detail = "ended" },
            );

            const media_stream = media_file.as(gtk.MediaStream);
            media_stream.setVolume(volume);
            media_stream.play();
        }
    }

    //---------------------------------------------------------------
    // Gtk.Scrollable interface implementation

    pub fn getHAdjustment(self: *Self) ?*gtk.Adjustment {
        return self.private().hadj;
    }

    pub fn setHAdjustment(self: *Self, adj_: ?*gtk.Adjustment) void {
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.hadjustment.impl.param_spec);

        const priv = self.private();
        if (priv.hadj) |old| {
            old.as(gobject.Object).unref();
            priv.hadj = null;
        }

        const adj = adj_ orelse return;
        _ = adj.as(gobject.Object).ref();
        priv.hadj = adj;
    }

    fn getHAdjustmentValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.getHAdjustment());
    }

    fn setHAdjustmentValue(self: *Self, value: *const gobject.Value) void {
        self.setHAdjustment(gobject.ext.Value.get(value, ?*gtk.Adjustment));
    }

    pub fn getVAdjustment(self: *Self) ?*gtk.Adjustment {
        return self.private().vadj;
    }

    pub fn setVAdjustment(self: *Self, adj_: ?*gtk.Adjustment) void {
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.vadjustment.impl.param_spec);

        const priv = self.private();

        if (priv.vadj) |old| {
            old.as(gobject.Object).unref();
            priv.vadj = null;
        }

        const adj = adj_ orelse return;
        _ = adj.as(gobject.Object).ref();
        priv.vadj = adj;
    }

    fn getVAdjustmentValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.getVAdjustment());
    }

    fn setVAdjustmentValue(self: *Self, value: *const gobject.Value) void {
        self.setVAdjustment(gobject.ext.Value.get(value, ?*gtk.Adjustment));
    }

    //---------------------------------------------------------------
    // Signal Handlers

    pub fn actionPromptTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.prompt_surface_title) catch |err| {
            log.warn("unable to perform prompt title action err={}", .{err});
        };
    }

    pub fn actionNotifyOnNextCommandFinish(
        action: *gio.SimpleAction,
        _: ?*glib.Variant,
        _: *Self,
    ) callconv(.c) void {
        const state = action.as(gio.Action).getState() orelse glib.Variant.newBoolean(@intFromBool(false));
        defer state.unref();
        const bool_variant_type = glib.ext.VariantType.newFor(bool);
        defer bool_variant_type.free();
        if (state.isOfType(bool_variant_type) == 0) return;
        const value = state.getBoolean() != 0;
        action.setState(glib.Variant.newBoolean(@intFromBool(!value)));
    }

    fn childExitedClose(
        _: *ChildExited,
        self: *Self,
    ) callconv(.c) void {
        // This closes the surface with no confirmation.
        self.close();
    }

    fn contextMenuClosed(
        _: *gtk.PopoverMenu,
        self: *Self,
    ) callconv(.c) void {
        // When the context menu closes, it moves focus back to the tab
        // bar if there are tabs. That's not correct. We need to grab it
        // on the surface.
        self.grabFocus();
    }

    fn inspectorWeakNotify(
        ud: ?*anyopaque,
        _: *gobject.Object,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const priv = self.private();
        priv.inspector = null;
    }

    fn dtDrop(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const alloc = Application.default().allocator();

        if (ext.gValueHolds(value, gdk.FileList.getGObjectType())) {
            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();

            var shell_escape_writer: internal_os.ShellEscapeWriter = .init(&stream.writer);
            const writer = &shell_escape_writer.writer;

            const list: ?*glib.SList = list: {
                const unboxed = value.getBoxed() orelse return 0;
                const fl: *gdk.FileList = @ptrCast(@alignCast(unboxed));
                break :list fl.getFiles();
            };
            defer if (list) |v| v.free();

            {
                var current: ?*glib.SList = list;
                while (current) |item| : (current = item.f_next) {
                    const file: *gio.File = @ptrCast(@alignCast(item.f_data orelse continue));
                    const path = file.getPath() orelse continue;
                    const slice = std.mem.span(path);
                    defer glib.free(path);

                    writer.writeAll(slice) catch |err| {
                        log.err("unable to write path to buffer: {}", .{err});
                        continue;
                    };
                    writer.writeAll("\n") catch |err| {
                        log.err("unable to write to buffer: {}", .{err});
                        continue;
                    };
                }
            }

            const string = stream.toOwnedSliceSentinel(0) catch |err| {
                log.err("unable to convert to a slice: {}", .{err});
                return 0;
            };
            defer alloc.free(string);
            Clipboard.paste(self, string);
            return 1;
        }

        if (ext.gValueHolds(value, gio.File.getGObjectType())) {
            const object = value.getObject() orelse return 0;
            const file = gobject.ext.cast(gio.File, object) orelse return 0;
            const path = file.getPath() orelse return 0;
            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();

            var shell_escape_writer: internal_os.ShellEscapeWriter = .init(&stream.writer);
            const writer = &shell_escape_writer.writer;
            writer.writeAll(std.mem.span(path)) catch |err| {
                log.err("unable to write path to buffer: {}", .{err});
                return 0;
            };
            writer.writeAll("\n") catch |err| {
                log.err("unable to write to buffer: {}", .{err});
                return 0;
            };

            const string = stream.toOwnedSliceSentinel(0) catch |err| {
                log.err("unable to convert to a slice: {}", .{err});
                return 0;
            };
            defer alloc.free(string);
            return 1;
        }

        if (ext.gValueHolds(value, gobject.ext.types.string)) {
            if (value.getString()) |string| {
                Clipboard.paste(self, std.mem.span(string));
            }
            return 1;
        }

        return 1;
    }

    fn ecKeyPressed(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        return @intFromBool(self.keyEvent(
            .press,
            ec_key,
            keyval,
            keycode,
            gtk_mods,
        ));
    }

    fn ecKeyReleased(
        ec_key: *gtk.EventControllerKey,
        keyval: c_uint,
        keycode: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) void {
        _ = self.keyEvent(
            .release,
            ec_key,
            keyval,
            keycode,
            state,
        );
    }

    fn ecFocusEnter(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.focused = true;
        priv.im_context.as(gtk.IMContext).focusIn();
        _ = glib.idleAddOnce(idleFocus, self.ref());
        self.as(gobject.Object).notifyByPspec(properties.focused.impl.param_spec);

        // Bell stops ringing as soon as we gain focus
        self.setBellRinging(false);
    }

    fn ecFocusLeave(_: *gtk.EventControllerFocus, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.focused = false;
        priv.im_context.as(gtk.IMContext).focusOut();
        _ = glib.idleAddOnce(idleFocus, self.ref());
        self.as(gobject.Object).notifyByPspec(properties.focused.impl.param_spec);
    }

    /// The focus callback must be triggered on an idle loop source because
    /// there are actions within libghostty callbacks (such as showing close
    /// confirmation dialogs) that can trigger focus loss and cause a deadlock
    /// because the lock may be held during the callback.
    ///
    /// Userdata should be a `*Surface`. This will unref once.
    fn idleFocus(ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();

        const priv = self.private();
        const surface = priv.core_surface orelse return;
        surface.focusCallback(priv.focused) catch |err| {
            log.warn("error in focus callback err={}", .{err});
        };
    }

    fn gcMouseDown(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

        // Bell stops ringing if any mouse button is pressed.
        self.setBellRinging(false);

        // Get our surface. If we don't have one, ignore this.
        const priv = self.private();
        const core_surface = priv.core_surface orelse return;

        // If we don't have focus, grab it.
        const gl_area_widget = priv.gl_area.as(gtk.Widget);
        if (gl_area_widget.hasFocus() == 0) {
            _ = gl_area_widget.grabFocus();
        }

        // Report the event
        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());

        if (button == .middle and !priv.gtk_enable_primary_paste) {
            return;
        }

        const consumed = consumed: {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            break :consumed core_surface.mouseButtonCallback(
                .press,
                button,
                mods,
            ) catch |err| err: {
                log.warn("error in key callback err={}", .{err});
                break :err false;
            };
        };

        // If a right click isn't consumed, mouseButtonCallback selects the hovered
        // word and returns false. We can use this to handle the context menu
        // opening under normal scenarios.
        if (!consumed and button == .right) {
            signals.menu.impl.emit(
                self,
                null,
                .{},
                null,
            );

            const rect: gdk.Rectangle = .{
                .f_x = @intFromFloat(x),
                .f_y = @intFromFloat(y),
                .f_width = 1,
                .f_height = 1,
            };

            const popover = priv.context_menu.as(gtk.Popover);
            popover.setPointingTo(&rect);
            popover.popup();
        }
    }

    fn gcMouseUp(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const gtk_mods = event.getModifierState();
        const button = translateMouseButton(gesture.as(gtk.GestureSingle).getCurrentButton());

        if (button == .middle and !priv.gtk_enable_primary_paste) {
            return;
        }

        const mods = gtk_key.translateMods(gtk_mods);
        const consumed = surface.mouseButtonCallback(
            .release,
            button,
            mods,
        ) catch |err| {
            log.warn("error in key callback err={}", .{err});
            return;
        };

        // Trigger the on-screen keyboard if we have no selection,
        // and that the mouse event hasn't been intercepted by the callback.
        //
        // It's better to do this here rather than within the core callback
        // since we have direct access to the underlying gdk.Event here.
        if (!consumed and button == .left and !surface.hasSelection()) {
            if (!self.showOnScreenKeyboard(event)) {
                log.warn("failed to activate the on-screen keyboard", .{});
            }
        }
    }

    fn ecMouseMotion(
        ec: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const event = ec.as(gtk.EventController).getCurrentEvent() orelse return;
        const priv = self.private();

        const scaled = self.scaledCoordinates(x, y);
        const pos: apprt.CursorPos = .{
            .x = @floatCast(scaled.x),
            .y = @floatCast(scaled.y),
        };

        // There seem to be at least two cases where GTK issues a mouse motion
        // event without the cursor actually moving:
        // 1. GLArea is resized under the mouse. This has the unfortunate
        //    side effect of causing focus to potentially change when
        //    `focus-follows-mouse` is enabled.
        // 2. The window title is updated. This can cause the mouse to unhide
        //    incorrectly when hide-mouse-when-typing is enabled.
        // To prevent incorrect behavior, we'll only grab focus and
        // continue with callback logic if the cursor has actually moved.
        const is_cursor_still = @abs(priv.cursor_pos.x - pos.x) < 1 and
            @abs(priv.cursor_pos.y - pos.y) < 1;
        if (is_cursor_still) return;

        // If we don't have focus, and we want it, grab it.
        if (priv.config) |config| {
            const gl_area_widget = priv.gl_area.as(gtk.Widget);
            if (gl_area_widget.hasFocus() == 0 and
                config.get().@"focus-follows-mouse")
            {
                _ = gl_area_widget.grabFocus();
            }
        }

        // Our pos changed, update
        priv.cursor_pos = pos;

        // Notify the callback
        if (priv.core_surface) |surface| {
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(priv.cursor_pos, mods) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
            };
        }
    }

    fn ecMouseLeave(
        ec_motion: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const event = ec_motion.as(gtk.EventController).getCurrentEvent() orelse return;

        // Get our modifiers
        const priv = self.private();
        if (priv.core_surface) |surface| {
            // If we have a core surface then we can send the cursor pos
            // callback with an invalid position to indicate the mouse left.
            const gtk_mods = event.getModifierState();
            const mods = gtk_key.translateMods(gtk_mods);
            surface.cursorPosCallback(
                .{ .x = -1, .y = -1 },
                mods,
            ) catch |err| {
                log.warn("error in cursor pos callback err={}", .{err});
                return;
            };
        }
    }

    fn ecMouseScrollVerticalPrecisionBegin(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = true;
    }

    fn ecMouseScrollVerticalPrecisionEnd(
        _: *gtk.EventControllerScroll,
        self: *Self,
    ) callconv(.c) void {
        self.private().precision_scroll = false;
    }

    fn ecMouseScrollVertical(
        _: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv: *Private = self.private();
        const surface = priv.core_surface orelse return 0;

        // Multiply precision scrolls by 10 to get a better response from
        // touchpad scrolling
        const multiplier: f64 = if (priv.precision_scroll) 10.0 else 1.0;
        const scroll_mods: input.ScrollMods = .{
            .precision = priv.precision_scroll,
        };

        const scaled = self.scaledCoordinates(x, y);
        surface.scrollCallback(
            // We invert because we apply natural scrolling to the values.
            // This behavior has existed for years without Linux users complaining
            // but I suspect we'll have to make this configurable in the future
            // or read a system setting.
            scaled.x * -1 * multiplier,
            scaled.y * -1 * multiplier,
            scroll_mods,
        ) catch |err| {
            log.warn("error in scroll callback err={}", .{err});
            return 0;
        };

        return 1;
    }

    fn ecMouseScrollHorizontal(
        ec: *gtk.EventControllerScroll,
        x: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv: *Private = self.private();

        switch (ec.getUnit()) {
            .surface => {},
            .wheel => return @intFromBool(false),
            else => return @intFromBool(false),
        }

        priv.pending_horizontal_scroll += x;

        if (@abs(priv.pending_horizontal_scroll) < 120) {
            if (priv.pending_horizontal_scroll_reset) |v| {
                _ = glib.Source.remove(v);
                priv.pending_horizontal_scroll_reset = null;
            }
            priv.pending_horizontal_scroll_reset = glib.timeoutAdd(500, ecMouseScrollHorizontalReset, self);
            return @intFromBool(true);
        }

        _ = self.as(gtk.Widget).activateAction(
            if (priv.pending_horizontal_scroll < 0.0)
                "tab.next-page"
            else
                "tab.previous-page",
            null,
        );

        if (priv.pending_horizontal_scroll_reset) |v| {
            _ = glib.Source.remove(v);
            priv.pending_horizontal_scroll_reset = null;
        }

        priv.pending_horizontal_scroll = 0.0;

        return @intFromBool(true);
    }

    fn ecMouseScrollHorizontalReset(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv: *Private = self.private();
        priv.pending_horizontal_scroll = 0.0;
        priv.pending_horizontal_scroll_reset = null;
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn imPreeditStart(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        // log.warn("GTKIM: preedit start", .{});

        // Start our composing state for the input method and reset our
        // input buffer to empty.
        const priv = self.private();
        priv.im_composing = true;
        priv.im_len = 0;
    }

    fn imPreeditChanged(
        ctx: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Any preedit change should mark that we're composing. Its possible this
        // is false using fcitx5-hangul and typing "dkssud<space>" ("안녕"). The
        // second "s" results in a "commit" for "안" which sets composing to false,
        // but then immediately sends a preedit change for the next symbol. With
        // composing set to false we won't commit this text. Therefore, we must
        // ensure it is set here.
        priv.im_composing = true;

        // We can't set our preedit on our surface unless we're realized.
        // We do this now because we want to still keep our input method
        // state coherent.
        const surface = priv.core_surface orelse return;

        // Get our pre-edit string that we'll use to show the user.
        var buf: [*:0]u8 = undefined;
        ctx.as(gtk.IMContext).getPreeditString(
            &buf,
            null,
            null,
        );
        defer glib.free(buf);
        const str = std.mem.sliceTo(buf, 0);

        // Update our preedit state in Ghostty core
        // log.warn("GTKIM: preedit change str={s}", .{str});
        surface.preeditCallback(str) catch |err| {
            log.warn(
                "error in preedit callback err={}",
                .{err},
            );
        };
    }

    fn imPreeditEnd(
        _: *gtk.IMMulticontext,
        self: *Self,
    ) callconv(.c) void {
        // log.warn("GTKIM: preedit end", .{});

        // End our composing state for GTK, allowing us to commit the text.
        const priv = self.private();
        priv.im_composing = false;

        // End our preedit state in Ghostty core
        const surface = priv.core_surface orelse return;
        surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    fn imCommit(
        _: *gtk.IMMulticontext,
        bytes: [*:0]u8,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const str = std.mem.sliceTo(bytes, 0);

        // log.debug("GTKIM: input commit composing={} keyevent={} str={s}", .{
        //     self.im_composing,
        //     self.in_keyevent,
        //     str,
        // });

        // We need to handle commit specially if we're in a key event.
        // Specifically, GTK will send us a commit event for basic key
        // encodings like "a" (on a US layout keyboard). We don't want
        // to treat this as IME committed text because we want to associate
        // it with a key event (i.e. "a" key press).
        switch (priv.in_keyevent) {
            // If we're not in a key event then this commit is from
            // some other source (i.e. on-screen keyboard, tablet, etc.)
            // and we want to commit the text to the core surface.
            .false => {},

            // If we're in a composing state and in a key event then this
            // key event is resulting in a commit of multiple keypresses
            // and we don't want to encode it alongside the keypress.
            .composing => {},

            // If we're not composing then this commit is just a normal
            // key encoding and we want our key event to handle it so
            // that Ghostty can be aware of the key event alongside
            // the text.
            .not_composing => {
                if (str.len > priv.im_buf.len) {
                    log.warn("not enough buffer space for input method commit", .{});
                    return;
                }

                // Copy our committed text to the buffer
                @memcpy(priv.im_buf[0..str.len], str);
                priv.im_len = @intCast(str.len);

                // log.debug("input commit len={}", .{priv.im_len});
                return;
            },
        }

        // If we reach this point from above it means we're composing OR
        // not in a keypress. In either case, we want to commit the text
        // given to us because that's what GTK is asking us to do. If we're
        // not in a keypress it means that this commit came via a non-keyboard
        // event (i.e. on-screen keyboard, tablet of some kind, etc.).

        // Committing ends composing state
        priv.im_composing = false;

        // We can't set our preedit on our surface unless we're realized.
        // We do this now because we want to still keep our input method
        // state coherent.
        if (priv.core_surface) |surface| {
            // End our preedit state. Well-behaved input methods do this for us
            // by triggering a preedit-end event but some do not (ibus 1.5.29).
            surface.preeditCallback(null) catch |err| {
                log.warn("error in preedit callback err={}", .{err});
            };

            // Send the text to the core surface, associated with no key (an
            // invalid key, which should produce no PTY encoding).
            _ = surface.keyCallback(.{
                .action = .press,
                .key = .unidentified,
                .mods = .{},
                .consumed_mods = .{},
                .composing = false,
                .utf8 = str,
            }) catch |err| {
                log.warn("error in key callback err={}", .{err});
            };
        }
    }

    fn glareaRealize(
        _: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("realize", .{});

        // Make the GL area current so we can detect any OpenGL errors. If
        // we have errors here we can't render and we switch to the error
        // state.
        const priv = self.private();
        priv.gl_area.makeCurrent();
        if (priv.gl_area.getError()) |err| {
            log.warn("failed to make GL context current: {s}", .{err.f_message orelse "(no message)"});
            log.warn("this error is almost always due to a library, driver, or GTK issue", .{});
            log.warn("this is a common cause of this issue: https://ghostty.org/docs/help/gtk-opengl-context", .{});
            self.setError(true);
            return;
        }

        // If we already have an initialized surface then we notify it.
        // If we don't, we'll initialize it on the first resize so we have
        // our proper initial dimensions.
        if (priv.core_surface) |v| realize: {
            v.renderer.displayRealized() catch |err| {
                log.warn("core displayRealized failed err={}", .{err});
                break :realize;
            };

            self.redraw();
        }

        // Setup our input method. We do this here because this will
        // create a strong reference back to ourself and we want to be
        // able to release that in unrealize.
        priv.im_context.as(gtk.IMContext).setClientWidget(self.as(gtk.Widget));
    }

    fn glareaUnrealize(
        gl_area: *gtk.GLArea,
        self: *Self,
    ) callconv(.c) void {
        log.debug("unrealize", .{});

        // Notify our core surface
        const priv = self.private();
        if (priv.core_surface) |surface| {
            // There is no guarantee that our GLArea context is current
            // when unrealize is emitted, so we need to make it current.
            gl_area.makeCurrent();
            if (gl_area.getError()) |err| {
                // I don't know a scenario this can happen, but it means
                // we probably leaked memory because displayUnrealized
                // below frees resources that aren't specifically OpenGL
                // related. I didn't make the OpenGL renderer handle this
                // scenario because I don't know if its even possible
                // under valid circumstances, so let's log.
                log.warn(
                    "gl_area_make_current failed in unrealize msg={s}",
                    .{err.f_message orelse "(no message)"},
                );
                log.warn("OpenGL resources and memory likely leaked", .{});
                return;
            }

            surface.renderer.displayUnrealized();
        }

        // Unset our input method
        priv.im_context.as(gtk.IMContext).setClientWidget(null);
    }

    fn glareaRender(
        _: *gtk.GLArea,
        _: *gdk.GLContext,
        self: *Self,
    ) callconv(.c) c_int {
        // If we don't have a surface then we failed to initialize for
        // some reason and there's nothing to draw to the GLArea.
        const priv = self.private();
        const surface = priv.core_surface orelse return 1;

        surface.renderer.drawFrame(true) catch |err| {
            log.warn("failed to draw frame err={}", .{err});
            return 0;
        };

        return 1;
    }

    fn glareaResize(
        gl_area: *gtk.GLArea,
        width: c_int,
        height: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Some debug output to help understand what GTK is telling us.
        {
            const widget = gl_area.as(gtk.Widget);
            const scale_factor = widget.getScaleFactor();
            const window_scale_factor = scale: {
                const root = widget.getRoot() orelse break :scale 0;
                const gtk_native = root.as(gtk.Native);
                const gdk_surface = gtk_native.getSurface() orelse break :scale 0;
                break :scale gdk_surface.getScaleFactor();
            };

            log.debug("gl resize width={} height={} scale={} window_scale={}", .{
                width,
                height,
                scale_factor,
                window_scale_factor,
            });
        }

        // Store our cached size
        const priv = self.private();
        priv.size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };

        // If our surface is realize, we send callbacks.
        if (priv.core_surface) |surface| {
            // We also update the content scale because there is no signal for
            // content scale change and it seems to trigger a resize event.
            surface.contentScaleCallback(self.getContentScale()) catch |err| {
                log.warn("error in content scale callback err={}", .{err});
            };

            surface.sizeCallback(priv.size) catch |err| {
                log.warn("error in size callback err={}", .{err});
            };

            // Setup our resize overlay if configured
            self.resizeOverlaySchedule();

            return;
        }

        // If we don't have a surface, then we initialize it.
        self.initSurface() catch |err| {
            log.warn("surface failed to initialize err={}", .{err});
        };
    }

    const InitError = Allocator.Error || error{
        GLAreaError,
        SurfaceError,
    };

    fn initSurface(self: *Self) InitError!void {
        const priv = self.private();
        assert(priv.core_surface == null);
        const gl_area = priv.gl_area;

        // We need to make the context current so we can call GL functions.
        // This is required for all surface operations.
        gl_area.makeCurrent();
        if (gl_area.getError()) |err| {
            log.warn("failed to make GL context current: {s}", .{err.f_message orelse "(no message)"});
            log.warn("this error is usually due to a driver or gtk bug", .{});
            log.warn("this is a common cause of this issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/4950", .{});
            return error.GLAreaError;
        }

        const app = Application.default();
        const alloc = app.allocator();

        // Make our pointer to store our surface
        const surface = try alloc.create(CoreSurface);
        errdefer alloc.destroy(surface);

        // Add ourselves to the list of surfaces on the app.
        try app.core().addSurface(self.rt());
        errdefer app.core().deleteSurface(self.rt());

        // Initialize our surface configuration.
        var config = try apprt.surface.newConfig(
            app.core(),
            priv.config.?.get(),
            priv.context,
        );
        defer config.deinit();

        // Properties that can impact surface init
        if (priv.font_size_request) |size| config.@"font-size" = size.points;
        if (priv.pwd) |pwd| config.@"working-directory" = pwd;

        // Initialize the surface
        surface.init(
            alloc,
            &config,
            app.core(),
            app.rt(),
            &priv.rt_surface,
        ) catch |err| {
            log.warn("failed to initialize surface err={}", .{err});
            return error.SurfaceError;
        };
        errdefer surface.deinit();

        // Store it!
        priv.core_surface = surface;

        // Emit the signal that we initialized the surface.
        Surface.signals.init.impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    fn resizeOverlaySchedule(self: *Self) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;

        // Only show the resize overlay if its enabled
        const config = if (priv.config) |c| c.get() else return;
        switch (config.@"resize-overlay") {
            .always, .@"after-first" => {},
            .never => return,
        }

        // If we have resize overlays enabled, setup an idler
        // to show that. We do this in an idle tick because doing it
        // during the resize results in flickering.
        var buf: [32]u8 = undefined;
        priv.resize_overlay.setLabel(text: {
            const grid_size = surface.size.grid();
            break :text std.fmt.bufPrintZ(
                &buf,
                "{d} x {d}",
                .{
                    grid_size.columns,
                    grid_size.rows,
                },
            ) catch |err| err: {
                log.warn("unable to format text: {}", .{err});
                break :err "";
            };
        });
        priv.resize_overlay.schedule();
    }

    fn ecUrlMouseEnter(
        _: *gtk.EventControllerMotion,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const right = priv.url_right.as(gtk.Widget);
        right.setVisible(1);
    }

    fn ecUrlMouseLeave(
        _: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const right = priv.url_right.as(gtk.Widget);
        right.setVisible(0);
    }

    fn mediaFileError(
        media_file: *gtk.MediaFile,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const path = path: {
            const file = media_file.getFile() orelse break :path null;
            break :path file.getPath();
        };
        defer if (path) |p| glib.free(p);

        const media_stream = media_file.as(gtk.MediaStream);
        const err = media_stream.getError() orelse return;
        log.warn("error playing bell from {s}: {s} {d} {s}", .{
            path orelse "<<unknown>>",
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "",
        });
    }

    fn mediaFileEnded(
        media_file: *gtk.MediaFile,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        media_file.unref();
    }

    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }

    fn searchStop(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.end_search) catch |err| {
            log.warn("unable to perform end_search action err={}", .{err});
        };
        _ = self.private().gl_area.as(gtk.Widget).grabFocus();
    }

    fn searchChanged(_: *SearchOverlay, needle: ?[*:0]const u8, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .search = std.mem.sliceTo(needle orelse "", 0) }) catch |err| {
            log.warn("unable to perform search action err={}", .{err});
        };
    }

    fn searchNextMatch(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .navigate_search = .next }) catch |err| {
            log.warn("unable to perform navigate_search action err={}", .{err});
        };
    }

    fn searchPreviousMatch(_: *SearchOverlay, self: *Self) callconv(.c) void {
        const surface = self.core() orelse return;
        _ = surface.performBindingAction(.{ .navigate_search = .previous }) catch |err| {
            log.warn("unable to perform navigate_search action err={}", .{err});
        };
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ResizeOverlay);
            gobject.ext.ensureType(SearchOverlay);
            gobject.ext.ensureType(KeyStateOverlay);
            gobject.ext.ensureType(ChildExited);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "surface",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("gl_area", .{});
            class.bindTemplateChildPrivate("url_left", .{});
            class.bindTemplateChildPrivate("url_right", .{});
            class.bindTemplateChildPrivate("child_exited_overlay", .{});
            class.bindTemplateChildPrivate("context_menu", .{});
            class.bindTemplateChildPrivate("error_page", .{});
            class.bindTemplateChildPrivate("progress_bar_overlay", .{});
            class.bindTemplateChildPrivate("resize_overlay", .{});
            class.bindTemplateChildPrivate("search_overlay", .{});
            class.bindTemplateChildPrivate("key_state_overlay", .{});
            class.bindTemplateChildPrivate("terminal_page", .{});
            class.bindTemplateChildPrivate("drop_target", .{});
            class.bindTemplateChildPrivate("im_context", .{});

            // Template Callbacks
            class.bindTemplateCallback("focus_enter", &ecFocusEnter);
            class.bindTemplateCallback("focus_leave", &ecFocusLeave);
            class.bindTemplateCallback("key_pressed", &ecKeyPressed);
            class.bindTemplateCallback("key_released", &ecKeyReleased);
            class.bindTemplateCallback("mouse_down", &gcMouseDown);
            class.bindTemplateCallback("mouse_up", &gcMouseUp);
            class.bindTemplateCallback("mouse_motion", &ecMouseMotion);
            class.bindTemplateCallback("mouse_leave", &ecMouseLeave);
            class.bindTemplateCallback("scroll_vertical", &ecMouseScrollVertical);
            class.bindTemplateCallback("scroll_vertical_begin", &ecMouseScrollVerticalPrecisionBegin);
            class.bindTemplateCallback("scroll_vertical_end", &ecMouseScrollVerticalPrecisionEnd);
            class.bindTemplateCallback("scroll_horizontal", &ecMouseScrollHorizontal);
            class.bindTemplateCallback("drop", &dtDrop);
            class.bindTemplateCallback("gl_realize", &glareaRealize);
            class.bindTemplateCallback("gl_unrealize", &glareaUnrealize);
            class.bindTemplateCallback("gl_render", &glareaRender);
            class.bindTemplateCallback("gl_resize", &glareaResize);
            class.bindTemplateCallback("im_preedit_start", &imPreeditStart);
            class.bindTemplateCallback("im_preedit_changed", &imPreeditChanged);
            class.bindTemplateCallback("im_preedit_end", &imPreeditEnd);
            class.bindTemplateCallback("im_commit", &imCommit);
            class.bindTemplateCallback("url_mouse_enter", &ecUrlMouseEnter);
            class.bindTemplateCallback("url_mouse_leave", &ecUrlMouseLeave);
            class.bindTemplateCallback("child_exited_close", &childExitedClose);
            class.bindTemplateCallback("context_menu_closed", &contextMenuClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_error", &propError);
            class.bindTemplateCallback("notify_mouse_hover_url", &propMouseHoverUrl);
            class.bindTemplateCallback("notify_mouse_hidden", &propMouseHidden);
            class.bindTemplateCallback("notify_mouse_shape", &propMouseShape);
            class.bindTemplateCallback("notify_vadjustment", &propVAdjustment);
            class.bindTemplateCallback("should_border_be_shown", &closureShouldBorderBeShown);
            class.bindTemplateCallback("should_unfocused_split_be_shown", &closureShouldUnfocusedSplitBeShown);
            class.bindTemplateCallback("search_stop", &searchStop);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_next_match", &searchNextMatch);
            class.bindTemplateCallback("search_previous_match", &searchPreviousMatch);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"bell-ringing".impl,
                properties.config.impl,
                properties.@"child-exited".impl,
                properties.@"default-size".impl,
                properties.@"error".impl,
                properties.@"font-size-request".impl,
                properties.focused.impl,
                properties.@"key-sequence".impl,
                properties.@"key-table".impl,
                properties.@"min-size".impl,
                properties.@"mouse-shape".impl,
                properties.@"mouse-hidden".impl,
                properties.@"mouse-hover-url".impl,
                properties.pwd.impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.zoom.impl,
                properties.@"is-split".impl,
                properties.readonly.impl,

                // For Gtk.Scrollable
                properties.hadjustment.impl,
                properties.vadjustment.impl,
                properties.@"hscroll-policy".impl,
                properties.@"vscroll-policy".impl,
            });

            // Signals
            signals.bell.impl.register(.{});
            signals.@"close-request".impl.register(.{});
            signals.@"clipboard-read".impl.register(.{});
            signals.@"clipboard-write".impl.register(.{});
            signals.init.impl.register(.{});
            signals.menu.impl.register(.{});
            signals.@"present-request".impl.register(.{});
            signals.@"toggle-fullscreen".impl.register(.{});
            signals.@"toggle-maximize".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };

    /// Simple dimensions struct for the surface used by various properties.
    pub const Size = extern struct {
        width: u32,
        height: u32,

        pub const getGObjectType = gobject.ext.defineBoxed(
            Size,
            .{ .name = "GhosttySurfaceSize" },
        );
    };
};

/// The state of the key event while we're doing IM composition.
/// See gtkKeyPressed for detailed descriptions.
pub const IMKeyEvent = enum {
    /// Not in a key event.
    false,

    /// In a key event but im_composing was either true or false
    /// prior to the calling IME processing. This is important to
    /// work around different input methods calling commit and
    /// preedit end in a different order.
    composing,
    not_composing,
};

fn translateMouseButton(button: c_uint) input.MouseButton {
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

/// A namespace for our clipboard-related functions so Surface isn't SO large.
const Clipboard = struct {
    /// Set the clipboard contents.
    pub fn set(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) void {
        const priv = self.private();

        // Grab our plaintext content for use in confirmation dialogs
        // and signals. We always expect one to exist.
        const text: [:0]const u8 = for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) {
                break content.data;
            }
        } else return;

        // If no confirmation is necessary, set the clipboard.
        if (!confirm) {
            const clipboard = get(
                priv.gl_area.as(gtk.Widget),
                clipboard_type,
            ) orelse return;

            const alloc = Application.default().allocator();
            if (alloc.alloc(*gdk.ContentProvider, contents.len)) |providers| {
                // Note: we don't need to unref the individual providers
                // because new_union takes ownership of them.
                defer alloc.free(providers);

                for (contents, 0..) |content, i| {
                    const bytes = glib.Bytes.new(content.data.ptr, content.data.len);
                    defer bytes.unref();
                    if (std.mem.eql(u8, content.mime, "text/plain")) {
                        // Add an explicit UTF-8 encoding parameter to the
                        // text/plain type. The default charset when there is
                        // none is ASCII, and lots of things look for UTF-8
                        // specifically.
                        // The specs are not clear about the order here, but
                        // some clients apparently pick the first match in the
                        // order we set here then garble up bare 'text/plain'
                        // with non-ASCII UTF-8 content, so offer UTF-8 first.
                        //
                        // Note that under X11, GTK automatically adds the
                        // UTF8_STRING atom when this is present.
                        const text_provider_atoms = [_][:0]const u8{
                            "text/plain;charset=utf-8",
                            "text/plain",
                        };
                        var text_providers: [text_provider_atoms.len]*gdk.ContentProvider = undefined;
                        for (text_provider_atoms, 0..) |atom, j| {
                            const provider = gdk.ContentProvider.newForBytes(atom, bytes);
                            text_providers[j] = provider;
                        }
                        const text_union = gdk.ContentProvider.newUnion(
                            &text_providers,
                            text_providers.len,
                        );
                        providers[i] = text_union;
                    } else {
                        const provider = gdk.ContentProvider.newForBytes(content.mime, bytes);
                        providers[i] = provider;
                    }
                }

                const all = gdk.ContentProvider.newUnion(providers.ptr, providers.len);
                defer all.unref();
                _ = clipboard.setContent(all);
            } else |_| {
                // If we fail to alloc, we can at least set the text content.
                clipboard.setText(text);
            }

            Surface.signals.@"clipboard-write".impl.emit(
                self,
                null,
                .{ clipboard_type, text.ptr },
                null,
            );

            return;
        }

        showClipboardConfirmation(
            self,
            .{ .osc_52_write = clipboard_type },
            text,
        );
    }

    /// Request data from the clipboard (read the clipboard). This
    /// completes asynchronously and will call the `completeClipboardRequest`
    /// core surface API when done.
    ///
    /// Returns true if the request was started, false if the clipboard
    /// doesn't contain text (allowing performable keybinds to pass through).
    pub fn request(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) Allocator.Error!bool {
        // Get our requested clipboard
        const clipboard = get(
            self.private().gl_area.as(gtk.Widget),
            clipboard_type,
        ) orelse return false;

        // For paste requests, check if clipboard has text format available.
        // This is a synchronous check that allows performable keybinds to
        // pass through when the clipboard contains non-text content (e.g., images).
        if (state == .paste) {
            const formats = clipboard.getFormats();
            if (formats.containGtype(gobject.ext.types.string) == 0) {
                log.debug("clipboard has no text format, not starting paste request", .{});
                return false;
            }
        }

        // Allocate our userdata
        const alloc = Application.default().allocator();
        const ud = try alloc.create(Request);
        errdefer alloc.destroy(ud);
        ud.* = .{
            // Important: we ref self here so that we can't free memory
            // while we have an outstanding clipboard read.
            .self = self.ref(),
            .state = state,
        };
        errdefer self.unref();

        // Read
        clipboard.readTextAsync(
            null,
            clipboardReadText,
            ud,
        );

        return true;
    }

    /// Paste explicit text directly into the surface, regardless of the
    /// actual clipboard contents.
    pub fn paste(
        self: *Surface,
        text: [:0]const u8,
    ) void {
        if (text.len == 0) return;

        const surface = self.private().core_surface orelse return;
        surface.completeClipboardRequest(
            .paste,
            text,
            false,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                showClipboardConfirmation(
                    self,
                    .paste,
                    text,
                );
                return;
            },

            else => {
                log.warn(
                    "failed to complete clipboard request err={}",
                    .{err},
                );
                return;
            },
        };
    }

    /// Get the specific type of clipboard for a widget.
    fn get(
        widget: *gtk.Widget,
        clipboard: apprt.Clipboard,
    ) ?*gdk.Clipboard {
        return switch (clipboard) {
            .standard => widget.getClipboard(),
            .selection, .primary => widget.getPrimaryClipboard(),
        };
    }

    fn showClipboardConfirmation(
        self: *Surface,
        req: apprt.ClipboardRequest,
        str: [:0]const u8,
    ) void {
        // Build a text buffer for our contents
        const contents_buf: *gtk.TextBuffer = .new(null);
        defer contents_buf.unref();
        contents_buf.insertAtCursor(str, @intCast(str.len));

        // Confirm
        const dialog = gobject.ext.newInstance(
            ClipboardConfirmationDialog,
            .{
                .request = &req,
                .@"can-remember" = switch (req) {
                    .osc_52_read, .osc_52_write => true,
                    .paste => false,
                },
                .@"clipboard-contents" = contents_buf,
            },
        );

        _ = ClipboardConfirmationDialog.signals.confirm.connect(
            dialog,
            *Surface,
            clipboardConfirmationConfirm,
            self,
            .{},
        );
        _ = ClipboardConfirmationDialog.signals.deny.connect(
            dialog,
            *Surface,
            clipboardConfirmationDeny,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    fn clipboardConfirmationConfirm(
        dialog: *ClipboardConfirmationDialog,
        remember: bool,
        self: *Surface,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const req = dialog.getRequest() orelse return;

        // Handle remember
        if (remember) switch (req.*) {
            .osc_52_read => surface.config.clipboard_read = .allow,
            .osc_52_write => surface.config.clipboard_write = .allow,
            .paste => {},
        };

        // Get our text
        const text_buf = dialog.getClipboardContents() orelse return;
        var text_val = gobject.ext.Value.new(?[:0]const u8);
        defer text_val.unset();
        gobject.Object.getProperty(
            text_buf.as(gobject.Object),
            "text",
            &text_val,
        );
        const text = gobject.ext.Value.get(
            &text_val,
            ?[:0]const u8,
        ) orelse return;

        surface.completeClipboardRequest(
            req.*,
            text,
            true,
        ) catch |err| {
            log.warn("failed to complete clipboard request: {}", .{err});
        };
    }

    fn clipboardConfirmationDeny(
        dialog: *ClipboardConfirmationDialog,
        remember: bool,
        self: *Surface,
    ) callconv(.c) void {
        const priv = self.private();
        const surface = priv.core_surface orelse return;
        const req = dialog.getRequest() orelse return;

        // Handle remember
        if (remember) switch (req.*) {
            .osc_52_read => surface.config.clipboard_read = .deny,
            .osc_52_write => surface.config.clipboard_write = .deny,
            .paste => @panic("paste should not be able to be remembered"),
        };
    }

    fn clipboardReadText(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const clipboard = gobject.ext.cast(
            gdk.Clipboard,
            source orelse return,
        ) orelse return;
        const req: *Request = @ptrCast(@alignCast(ud orelse return));

        const alloc = Application.default().allocator();
        defer alloc.destroy(req);

        const self = req.self;
        defer self.unref();

        var gerr: ?*glib.Error = null;
        const cstr_ = clipboard.readTextFinish(res, &gerr);
        if (gerr) |err| {
            defer err.free();
            log.warn(
                "failed to read clipboard err={s}",
                .{err.f_message orelse "(no message)"},
            );
            return;
        }
        const cstr = cstr_ orelse return;
        defer glib.free(cstr);
        const str = std.mem.sliceTo(cstr, 0);

        const surface = self.private().core_surface orelse return;
        surface.completeClipboardRequest(
            req.state,
            str,
            false,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                showClipboardConfirmation(
                    self,
                    req.state,
                    str,
                );
                return;
            },

            else => {
                log.warn(
                    "failed to complete clipboard request err={}",
                    .{err},
                );
                return;
            },
        };

        Surface.signals.@"clipboard-read".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    /// The request we send as userdata to the clipboard read.
    const Request = struct {
        /// "Self" is reffed so we can't dispose it until the clipboard
        /// read is complete. Callers must unref when done.
        self: *Surface,
        state: apprt.ClipboardRequest,
    };
};

/// Compute a fraction [0.0, 1.0] from the supplied progress, which is clamped
/// to [0, 100].
fn computeFraction(progress: u8) f64 {
    return @as(f64, @floatFromInt(std.math.clamp(progress, 0, 100))) / 100.0;
}

test "computeFraction" {
    try std.testing.expectEqual(1.0, computeFraction(100));
    try std.testing.expectEqual(1.0, computeFraction(255));
    try std.testing.expectEqual(0.0, computeFraction(0));
    try std.testing.expectEqual(0.5, computeFraction(50));
}
