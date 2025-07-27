const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
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
                    .nick = "Config",
                    .blurb = "The configuration that this command palette is using.",
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const window = struct {
            pub const name = "window";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Window,
                .{
                    .nick = "Window",
                    .blurb = "The window that the command palette is attached to.",
                    .accessor = C.privateObjFieldAccessor("window"),
                },
            );
        };
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// The window that this command palette is attached to.
        window: ?*Window = null,

        /// Binding of config between window and command palette.
        binding: ?*gobject.Binding = null,

        arena: ArenaAllocator,

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

    /// Create a new instance of the command palette, connected to the given
    /// window.
    pub fn new(window: *Window) *Self {
        const config = config: {
            if (window.getConfig()) |config| break :config config.ref();
            break :config Application.default().getConfig();
        };
        defer config.unref();

        const self = gobject.ext.newInstance(Self, .{
            .config = config,
            .window = window,
        });

        // Sink ourselves so that we aren't floating anymore. We'll unref when
        // the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const app = Application.default();
        const priv = self.private();

        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );

        // Initialize an arena to make cleaning up our allocations easier.
        priv.arena = .init(app.core().alloc);

        priv.binding = binding: {
            const window = priv.window orelse break :binding null;

            // Ensure that we always have the same config as the window.
            break :binding gobject.Object.bindProperty(
                window.as(gobject.Object),
                "config",
                self.as(gobject.Object),
                "config",
                .{},
            );
        };
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.source.removeAll();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        if (priv.binding) |binding| {
            binding.unref();
            priv.binding = null;
        }

        if (priv.window) |window| {
            window.unref();
            priv.window = null;
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

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        self.updateConfig();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // ESC was pressed - close the palette
        const priv = self.private();
        _ = priv.dialog.close();
        self.unref();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    //---------------------------------------------------------------

    pub fn toggle(self: *CommandPalette) void {
        const priv = self.private();

        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            _ = priv.dialog.close();
            self.unref();
            return;
        }

        const window = priv.window orelse {
            log.warn("command palette is not associated with a window", .{});
            return;
        };

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    fn updateConfig(self: *CommandPalette) void {
        const priv = self.private();

        const config = if (priv.config) |config| config.get() else {
            log.warn("command palette does not have a config!", .{});
            return;
        };

        // Clear existing binds and clear allocated data
        priv.source.removeAll();
        _ = priv.arena.reset(.retain_capacity);

        for (config.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK
            switch (command.action) {
                .close_all_windows,
                .toggle_secure_input,
                .check_for_updates,
                .redo,
                .undo,
                .reset_window_size,
                .toggle_window_float_on_top,
                => continue,

                else => {},
            }

            const cmd = Command.new(
                priv.arena.allocator(),
                command,
                config.keybind.set,
            ) catch |err| switch (err) {
                error.OutOfMemory, error.NoSpaceLeft => {
                    log.warn("unable to allocate new command err={}", .{err});
                    return;
                },
            };
            const cmd_ref = cmd.as(gobject.Object);
            priv.source.append(cmd_ref);
            cmd_ref.unref();
        }
    }

    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        const window = priv.window orelse {
            log.warn("command palette is not associated with a window", .{});
            return;
        };

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object = priv.model.as(gio.ListModel).getObject(pos) orelse return;
        const cmd = gobject.ext.cast(Command, object) orelse return;

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        _ = priv.dialog.close();

        const action = cmd.getAction() orelse return;

        window.performBindingAction(action);

        self.unref();
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
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.window.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
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

    pub const getGObjectType = gobject.ext.defineClass(Command, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    // Expose all fields on the input.Command.C struct as properties that can be
    // accessed by the GObject type system (and by extension, blueprints)
    const properties = props: {
        const info = @typeInfo(input.Command.C).@"struct";
        var props: [info.fields.len]type = undefined;

        for (info.fields, 0..) |field, i| {
            const accessor = struct {
                fn getter(self: *Self) ?[:0]const u8 {
                    const priv = self.private();
                    return std.mem.span(@field(priv.cmd_c, field.name));
                }
            };

            // "Canonicalize" field names into the format GObject expects
            const prop_name = prop_name: {
                var buf: [field.name.len:0]u8 = undefined;
                _ = std.mem.replace(u8, field.name, "_", "-", &buf);
                break :prop_name buf;
            };

            props[i] = gobject.ext.defineProperty(
                &prop_name,
                Command,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Command,
                        ?[:0]const u8,
                        .{
                            .getter = &accessor.getter,
                        },
                    ),
                },
            );
        }

        break :props props;
    };

    pub const Private = struct {
        /// The command.
        cmd_c: input.Command.C,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: Allocator, cmd: input.Command, keybinds: input.Binding.Set) (Allocator.Error || error{NoSpaceLeft})!*Command {
        const self = gobject.ext.newInstance(Command, .{});
        const priv = self.private();

        var buf: [64]u8 = undefined;

        const action = action: {
            const trigger = keybinds.getTrigger(cmd.action) orelse break :action null;
            const accel = try key.accelFromTrigger(&buf, trigger) orelse break :action null;
            break :action try alloc.dupeZ(u8, accel);
        };

        priv.cmd_c = .{
            .title = cmd.title.ptr,
            .description = cmd.description.ptr,
            .action = if (action) |v| v.ptr else "",
            .action_key = try std.fmt.allocPrintZ(alloc, "{}", .{cmd.action}),
        };

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        _ = self;
    }

    //---------------------------------------------------------------

    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();

        return input.Binding.Action.parse(
            std.mem.span(priv.cmd_c.action_key),
        ) catch |err| {
            log.err("invalid action={s} ({})", .{ priv.cmd_c.action_key, err });
            return null;
        };
    }

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
            gobject.ext.registerProperties(class, &properties);
        }
    };
};
