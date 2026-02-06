const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_command_palette);

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
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
    };

    pub const signals = struct {
        /// Emitted when a command from the command palette is activated. The
        /// action contains pointers to allocated data so if a receiver of this
        /// signal needs to keep the action around it will need to clone the
        /// action or there may be use-after-free errors.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// The dialog object containing the palette UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each result row.
        view: *gtk.ListView,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The list that serves as the data source of the model.
        /// This is where all command data is ultimately stored.
        source: *gio.ListStore,

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the command palette. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Listen for any changes to our config.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.source.removeAll();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        const priv = self.private();

        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return;
        };

        // Clear existing binds
        priv.source.removeAll();

        const alloc = Application.default().allocator();
        var commands: std.ArrayList(*Command) = .{};
        defer {
            for (commands.items) |cmd| cmd.unref();
            commands.deinit(alloc);
        }

        self.collectJumpCommands(config, &commands) catch |err| {
            log.warn("failed to collect jump commands: {}", .{err});
        };

        self.collectRegularCommands(config, &commands, alloc);

        // Sort commands
        std.mem.sort(*Command, commands.items, {}, struct {
            fn lessThan(_: void, a: *Command, b: *Command) bool {
                return compareCommands(a, b);
            }
        }.lessThan);

        for (commands.items) |cmd| {
            const cmd_ref = cmd.as(gobject.Object);
            priv.source.append(cmd_ref);
        }
    }

    /// Collect regular commands from configuration, filtering out unsupported actions.
    fn collectRegularCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        _ = self;
        const cfg = config.get();

        for (cfg.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK.
            if (!isActionSupportedOnGtk(command.action)) continue;

            const cmd = Command.new(config, command) catch |err| {
                log.warn("failed to create command: {}", .{err});
                continue;
            };
            errdefer cmd.unref();

            commands.append(alloc, cmd) catch |err| {
                log.warn("failed to add command to list: {}", .{err});
                continue;
            };
        }
    }

    /// Check if an action is supported on GTK.
    fn isActionSupportedOnGtk(action: input.Binding.Action) bool {
        return switch (action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => false,

            else => true,
        };
    }

    /// Collect jump commands for all surfaces across all windows.
    fn collectJumpCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
    ) !void {
        _ = self;
        const app = Application.default();
        const alloc = app.allocator();

        // Get all surfaces from the core app
        const core_app = app.core();
        for (core_app.surfaces.items) |apprt_surface| {
            const surface = apprt_surface.gobj();
            const cmd = Command.newJump(config, surface);
            errdefer cmd.unref();
            try commands.append(alloc, cmd);
        }
    }

    /// Compare two commands for sorting.
    /// Sorts alphabetically by title (case-insensitive), with colon normalization
    /// so "Foo:" sorts before "Foo Bar:". Uses sort_key as tie-breaker.
    fn compareCommands(a: *Command, b: *Command) bool {
        const a_title = a.propGetTitle() orelse return false;
        const b_title = b.propGetTitle() orelse return true;

        // Compare case-insensitively with colon normalization
        for (0..@min(a_title.len, b_title.len)) |i| {
            // Get characters, replacing ':' with '\t'
            const a_char = if (a_title[i] == ':') '\t' else a_title[i];
            const b_char = if (b_title[i] == ':') '\t' else b_title[i];

            const a_lower = std.ascii.toLower(a_char);
            const b_lower = std.ascii.toLower(b_char);

            if (a_lower != b_lower) {
                return a_lower < b_lower;
            }
        }

        // If one title is a prefix of the other, shorter one comes first
        if (a_title.len != b_title.len) {
            return a_title.len < b_title.len;
        }

        // Titles are equal - use sort_key as tie-breaker if both are jump commands
        const a_sort_key = switch (a.private().data) {
            .regular => return false,
            .jump => |*ja| ja.sort_key,
        };
        const b_sort_key = switch (b.private().data) {
            .regular => return false,
            .jump => |*jb| jb.sort_key,
        };

        return a_sort_key < b_sort_key;
    }

    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // ESC was pressed - close the palette
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    /// Handle custom keys for scrolling the command palette.
    fn ecKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv: *Private = self.private();

        const mods = key.translateMods(gtk_mods);
        const total = priv.model.as(gio.ListModel).getNItems();
        const current = priv.model.getSelected();

        if ((keyval == gdk.KEY_n or keyval == gdk.KEY_j) and mods.ctrl and current + 1 < total) {
            priv.model.setSelected(current + 1);
            priv.view.scrollTo(current + 1, .{ .focus = true, .select = true }, null);
            return @intFromBool(true);
        }

        if ((keyval == gdk.KEY_p or keyval == gdk.KEY_k) and mods.ctrl and current > 0) {
            priv.model.setSelected(current - 1);
            priv.view.scrollTo(current - 1, .{ .focus = true, .select = true }, null);
            return @intFromBool(true);
        }

        return @intFromBool(false);
    }

    //---------------------------------------------------------------

    /// Show or hide the command palette dialog. If the dialog is shown it will
    /// be modal over the given window.
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Helper function to send a signal containing the action that should be
    /// performed.
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        self.close();

        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;

        // Handle jump commands differently
        if (cmd.isJump()) {
            const surface = cmd.getJumpSurface() orelse return;
            defer surface.unref();
            surface.present();
            return;
        }

        // Regular command - emit trigger signal
        const action = cmd.getAction() orelse return;

        // Signal that an an action has been selected. Signals are synchronous
        // so we shouldn't need to worry about cloning the action.
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
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
            gobject.ext.ensureType(Command);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("key_pressed", &ecKeyPressed);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.trigger.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
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

        pub const action_key = struct {
            pub const name = "action-key";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetActionKey,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const action = struct {
            pub const name = "action";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetAction,
                            .getter_transfer = .none,
                        },
                    ),
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
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDescription,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    pub const Private = struct {
        config: ?*Config = null,
        arena: ArenaAllocator,
        data: CommandData,

        pub var offset: c_int = 0;

        pub const CommandData = union(enum) {
            regular: RegularData,
            jump: JumpData,
        };

        pub const RegularData = struct {
            command: input.Command,
            action: ?[:0]const u8 = null,
            action_key: ?[:0]const u8 = null,
        };

        pub const JumpData = struct {
            surface: WeakRef(Surface) = .empty,
            title: ?[:0]const u8 = null,
            description: ?[:0]const u8 = null,
            sort_key: usize,
        };
    };

    pub fn new(config: *Config, command: input.Command) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();

        const priv = self.private();
        const cloned = try command.clone(priv.arena.allocator());

        priv.data = .{
            .regular = .{
                .command = cloned,
            },
        };

        return self;
    }

    /// Create a new jump command that focuses a specific surface.
    pub fn newJump(config: *Config, surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });

        const priv = self.private();
        priv.data = .{
            .jump = .{
                // TODO: Replace with surface id whenever Ghostty adds one
                .sort_key = @intFromPtr(surface),
            },
        };
        priv.data.jump.surface.set(surface);

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // NOTE: we do not watch for changes to the config here as the command
        // palette will destroy and recreate this object if/when the config
        // changes.

        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        switch (priv.data) {
            .regular => {},
            .jump => |*j| {
                j.surface.set(null);
            },
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    fn propGetActionKey(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };

        if (regular.action_key) |action_key| return action_key;

        regular.action_key = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "{f}",
            .{regular.command.action},
            0,
        ) catch null;

        return regular.action_key;
    }

    fn propGetAction(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .jump => return null,
        };

        if (regular.action) |action| return action;

        const cfg = if (priv.config) |config| config.get() else return null;
        const keybinds = cfg.keybind.set;

        const alloc = priv.arena.allocator();

        regular.action = action: {
            var buf: [64]u8 = undefined;
            const trigger = keybinds.getTrigger(regular.command.action) orelse break :action null;
            const accel = (key.accelFromTrigger(&buf, trigger) catch break :action null) orelse break :action null;
            break :action alloc.dupeZ(u8, accel) catch return null;
        };

        return regular.action;
    }

    fn propGetTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.title,
            .jump => |*j| {
                if (j.title) |title| return title;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const surface_title = surface.getTitle() orelse "Untitled";

                j.title = std.fmt.allocPrintSentinel(
                    alloc,
                    "Focus: {s}",
                    .{surface_title},
                    0,
                ) catch null;

                return j.title;
            },
        }
    }

    fn propGetDescription(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.description,
            .jump => |*j| {
                if (j.description) |desc| return desc;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();

                const title = surface.getTitle() orelse "Untitled";
                const pwd = surface.getPwd();

                if (pwd) |p| {
                    if (std.mem.indexOf(u8, title, p) == null) {
                        j.description = alloc.dupeZ(u8, p) catch null;
                    }
                }

                return j.description;
            },
        }
    }

    //---------------------------------------------------------------

    /// Return a copy of the action. Callers must ensure that they do not use
    /// the action beyond the lifetime of this object because it has internally
    /// allocated data that will be freed when this object is.
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return switch (priv.data) {
            .regular => |*r| r.command.action,
            .jump => null,
        };
    }

    /// Check if this is a jump command.
    pub fn isJump(self: *Self) bool {
        const priv = self.private();
        return priv.data == .jump;
    }

    /// Get the jump surface. Returns a strong reference that the caller
    /// must unref when done, or null if the surface has been destroyed.
    pub fn getJumpSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.data) {
            .regular => null,
            .jump => |*j| j.surface.get(),
        };
    }

    //---------------------------------------------------------------

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.action_key.impl,
                properties.action.impl,
                properties.title.impl,
                properties.description.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
