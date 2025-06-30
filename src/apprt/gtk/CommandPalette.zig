const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const inputpkg = @import("../../input.zig");
const key = @import("key.zig");
const Builder = @import("Builder.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.command_palette);

window: *Window,

arena: std.heap.ArenaAllocator,

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

pub fn init(self: *CommandPalette, window: *Window) !void {
    // Register the custom command type *before* initializing the builder
    // If we don't do this now, the builder will complain that it doesn't know
    // about this type and fail to initialize
    _ = Command.getGObjectType();

    var builder = Builder.init("command-palette", 1, 5);
    defer builder.deinit();

    self.* = .{
        .window = window,
        .arena = .init(window.app.core_app.alloc),
        .dialog = builder.getObject(adw.Dialog, "command-palette").?,
        .search = builder.getObject(gtk.SearchEntry, "search").?,
        .view = builder.getObject(gtk.ListView, "view").?,
        .model = builder.getObject(gtk.SingleSelection, "model").?,
        .source = builder.getObject(gio.ListStore, "source").?,
    };

    // Manually take a reference here so that the dialog
    // remains in memory after closing
    self.dialog.ref();
    errdefer self.dialog.unref();

    _ = gtk.SearchEntry.signals.stop_search.connect(
        self.search,
        *CommandPalette,
        searchStopped,
        self,
        .{},
    );

    _ = gtk.SearchEntry.signals.activate.connect(
        self.search,
        *CommandPalette,
        searchActivated,
        self,
        .{},
    );

    _ = gtk.ListView.signals.activate.connect(
        self.view,
        *CommandPalette,
        rowActivated,
        self,
        .{},
    );

    try self.updateConfig(&self.window.app.config);
}

pub fn deinit(self: *CommandPalette) void {
    self.arena.deinit();
    self.dialog.unref();
}

pub fn toggle(self: *CommandPalette) void {
    self.dialog.present(self.window.window.as(gtk.Widget));
    // Focus on the search bar when opening the dialog
    _ = self.search.as(gtk.Widget).grabFocus();
}

pub fn updateConfig(self: *CommandPalette, config: *const configpkg.Config) !void {
    // Clear existing binds and clear allocated data
    self.source.removeAll();
    _ = self.arena.reset(.retain_capacity);

    for (config.@"command-palette-entry".value.items) |command| {
        // Filter out actions that are not implemented
        // or don't make sense for GTK
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

        const cmd = try Command.new(
            self.arena.allocator(),
            command,
            config.keybind.set,
        );
        const cmd_ref = cmd.as(gobject.Object);
        self.source.append(cmd_ref);
        cmd_ref.unref();
    }
}

fn activated(self: *CommandPalette, pos: c_uint) void {
    // Use self.model and not self.source here to use the list of *visible* results
    const object = self.model.as(gio.ListModel).getObject(pos) orelse return;
    const cmd = gobject.ext.cast(Command, object) orelse return;

    // Close before running the action in order to avoid being replaced by another
    // dialog (such as the change title dialog). If that occurs then the command
    // palette dialog won't be counted as having closed properly and cannot
    // receive focus when reopened.
    _ = self.dialog.close();

    const action = inputpkg.Binding.Action.parse(
        std.mem.span(cmd.cmd_c.action_key),
    ) catch |err| {
        log.err("got invalid action={s} ({})", .{ cmd.cmd_c.action_key, err });
        return;
    };

    self.window.performBindingAction(action);
}

fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
    // ESC was pressed - close the palette
    _ = self.dialog.close();
}

fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
    // If Enter is pressed, activate the selected entry
    self.activated(self.model.getSelected());
}

fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
    self.activated(pos);
}

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    parent: Parent,
    cmd_c: inputpkg.Command.C,

    pub const getGObjectType = gobject.ext.defineClass(Command, .{
        .name = "GhosttyCommand",
        .classInit = Class.init,
    });

    pub fn new(alloc: Allocator, cmd: inputpkg.Command, keybinds: inputpkg.Binding.Set) !*Command {
        const self = gobject.ext.newInstance(Command, .{});
        var buf: [64]u8 = undefined;

        const action = action: {
            const trigger = keybinds.getTrigger(cmd.action) orelse break :action null;
            const accel = try key.accelFromTrigger(&buf, trigger) orelse break :action null;
            break :action try alloc.dupeZ(u8, accel);
        };

        self.cmd_c = .{
            .title = cmd.title.ptr,
            .description = cmd.description.ptr,
            .action = if (action) |v| v.ptr else "",
            .action_key = try std.fmt.allocPrintZ(alloc, "{}", .{cmd.action}),
        };

        return self;
    }

    fn as(self: *Command, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    pub const Parent = gobject.Object;

    pub const Class = extern struct {
        parent: Parent.Class,

        pub const Instance = Command;

        pub fn init(class: *Class) callconv(.c) void {
            const info = @typeInfo(inputpkg.Command.C).@"struct";

            // Expose all fields on the Command.C struct as properties
            // that can be accessed by the GObject type system
            // (and by extension, blueprints)
            const properties = comptime props: {
                var props: [info.fields.len]type = undefined;

                for (info.fields, 0..) |field, i| {
                    const accessor = struct {
                        fn getter(cmd: *Command) ?[:0]const u8 {
                            return std.mem.span(@field(cmd.cmd_c, field.name));
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
                            .accessor = .{ .getter = &accessor.getter },
                        },
                    );
                }

                break :props props;
            };

            gobject.ext.registerProperties(class, &properties);
        }
    };
};
