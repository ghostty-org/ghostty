const std = @import("std");

const Binding = @import("../../input/Binding.zig");
const Window = @import("Window.zig");
const key = @import("key.zig");
const zf = @import("zf");

const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");

const log = std.log.scoped(.command_palette);

/// List of "example" commands/queries
const example_queries = [_][:0]const u8{
    "new window",
    "inspector",
    "window decoration",
    "clear",
    "reload config",
    "new split",
    "tab overview",
    "maximize",
    "fullscreen",
    "zoom",
};

/// The command palette, which provides a pop-up dialog for searching
/// and running a list of possible "commands", or pre-parametrized actions.
pub const CommandPalette = extern struct {
    parent: Parent,

    pub const Parent = adw.Dialog;

    const Private = struct {
        window: *Window,
        alloc: std.heap.ArenaAllocator,
        list: *CommandListModel,

        examples: @TypeOf(example_queries),
        example_idx: usize = 0,

        // To be filled in during template population
        stack: *adw.ViewStack,
        search: *gtk.SearchEntry,
        actions: *gtk.ListView,
        example: *adw.ActionRow,

        var offset: c_int = 0;
    };

    pub const getGObjectType = gobject.ext.defineClass(CommandPalette, .{
        .instanceInit = init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(window: *Window) !*CommandPalette {
        const self = gobject.ext.newInstance(CommandPalette, .{});
        const priv = self.private();

        // TODO: This is bad style in GObject. This should be in `init`, but
        // I have no way of smuggling a window pointer through.
        priv.window = window;
        priv.alloc = std.heap.ArenaAllocator.init(window.app.core_app.alloc);

        priv.list = try CommandListModel.new(&priv.alloc);
        try priv.list.private().commands.updateBindings(priv.alloc.allocator(), window.app.config.keybind.set);
        priv.actions.setModel(priv.list.as(gtk.SelectionModel));

        priv.examples = example_queries;
        std.crypto.random.shuffle([:0]const u8, &priv.examples);

        priv.search.setKeyCaptureWidget(self.as(gtk.Widget));
        return self;
    }

    pub fn present(self: *CommandPalette) void {
        self.refreshExample();
        self.as(adw.Dialog).present(@ptrCast(self.private().window.window));
    }

    // Boilerplate
    pub fn as(self: *CommandPalette, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }
    pub fn ref(self: *CommandPalette) void {
        _ = self.as(gobject.Object).ref();
    }
    pub fn unref(self: *CommandPalette) void {
        self.as(gobject.Object).unref();
    }
    fn private(self: *CommandPalette) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn refreshExample(self: *CommandPalette) void {
        const priv = self.private();
        const example = priv.examples[priv.example_idx];
        priv.example.as(adw.PreferencesRow).setTitle(example);

        priv.example_idx += 1;
        if (priv.example_idx == priv.examples.len) priv.example_idx = 0;
    }
    fn setQuery(self: *CommandPalette, query: [:0]const u8) void {
        const priv = self.private();
        priv.list.setQuery(query);

        const page = switch (priv.list.state()) {
            .prompt => "prompt",
            .items => items: {
                priv.actions.scrollTo(0, .{ .focus = true }, null);
                break :items "items";
            },
            .not_found => "not-found",
        };

        priv.stack.setVisibleChildName(page);
    }

    // Lifecycle functions
    fn init(self: *CommandPalette, _: *Class) callconv(.C) void {
        self.as(gtk.Widget).initTemplate();
    }
    fn dispose(self: *CommandPalette) callconv(.C) void {
        self.as(gtk.Widget).disposeTemplate(getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }
    fn finalize(self: *CommandPalette) callconv(.C) void {
        self.private().alloc.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    // Callbacks
    fn searchChanged(self: *CommandPalette, _: *gtk.SearchEntry) callconv(.C) void {
        const text = self.private().search.as(gtk.Editable).getText();
        self.setQuery(std.mem.span(text));
    }
    fn searchStopped(self: *CommandPalette, _: *gtk.SearchEntry) callconv(.C) void {
        _ = self.as(Parent).close();
    }
    fn searchActivated(self: *CommandPalette, _: *gtk.SearchEntry) callconv(.C) void {
        self.activateAction(0, self.private().actions);
    }
    fn exampleActivated(self: *CommandPalette, row: *adw.ActionRow) callconv(.C) void {
        const text = row.as(adw.PreferencesRow).getTitle();
        self.private().search.as(gtk.Editable).setText(text);
        self.setQuery(std.mem.span(text));
        self.refreshExample();
    }
    fn activateAction(self: *CommandPalette, pos: c_uint, _: *gtk.ListView) callconv(.C) void {
        const priv = self.private();
        const action = priv.list.getAction(pos) orelse return;
        const action_surface = priv.window.actionSurface() orelse return;

        const performed = action_surface.performBindingAction(action) catch |err| {
            log.err("failed to perform binding action={}", .{err});
            return;
        };

        if (!performed) {
            log.warn("binding action was not performed", .{});
            return;
        }

        _ = self.as(Parent).close();
    }

    pub const Class = extern struct {
        parent: Parent.Class,

        var parent: *Parent.Class = undefined;

        pub const Instance = CommandPalette;

        fn init(class: *Class) callconv(.C) void {
            gobject.Object.virtual_methods.dispose.implement(class, dispose);
            gobject.Object.virtual_methods.finalize.implement(class, finalize);

            const widget_class = class.as(gtk.WidgetClass);
            widget_class.setTemplateFromResource("/com/mitchellh/ghostty/ui/command_palette.ui");
            widget_class.bindTemplateCallbackFull("searchChanged", @ptrCast(&searchChanged));
            widget_class.bindTemplateCallbackFull("searchStopped", @ptrCast(&searchStopped));
            widget_class.bindTemplateCallbackFull("searchActivated", @ptrCast(&searchActivated));
            widget_class.bindTemplateCallbackFull("exampleActivated", @ptrCast(&exampleActivated));
            widget_class.bindTemplateCallbackFull("activateAction", @ptrCast(&activateAction));

            class.bindTemplateChildPrivate("actions", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("stack", .{});
            class.bindTemplateChildPrivate("example", .{});
        }

        fn as(self: *Class, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }

        fn bindTemplateChildPrivate(class: *Class, comptime name: [:0]const u8, comptime options: gtk.ext.BindTemplateChildOptions) void {
            gtk.ext.impl_helpers.bindTemplateChildPrivate(class, name, Private, Private.offset, options);
        }
    };
};

pub const CommandListModel = extern struct {
    parent: Parent,

    pub const Parent = gobject.Object;
    pub const Implements = [_]type{ gio.ListModel, gtk.SelectionModel };

    const Private = struct {
        alloc: *std.heap.ArenaAllocator,
        tokens: std.ArrayListUnmanaged([]const u8),
        commands: CommandList,

        var offset: c_int = 0;
    };

    const State = enum {
        prompt,
        items,
        not_found,
    };

    pub const getGObjectType = gobject.ext.defineClass(CommandListModel, .{
        .classInit = Class.init,
        .implements = &.{
            gobject.ext.implement(gio.ListModel, .{ .init = Class.initListModel }),
            gobject.ext.implement(gtk.SelectionModel, .{ .init = Class.initSelectionModel }),
        },
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const query = struct {
            pub const name = "query";
            const impl = gobject.ext.defineProperty(name, CommandListModel, ?[:0]const u8, .{
                .default = "",
                .accessor = .{ .getter = @ptrCast(&noop), .setter = setQuery },
                .flags = .{ .writable = true },
            });
        };
    };

    pub fn new(alloc: *std.heap.ArenaAllocator) !*CommandListModel {
        const self = gobject.ext.newInstance(CommandListModel, .{});
        self.private().* = .{
            .alloc = alloc,
            .tokens = .{},
            .commands = try CommandList.init(alloc.allocator()),
        };
        return self;
    }

    pub fn getAction(self: *CommandListModel, pos: c_uint) ?Binding.Action {
        const commands = self.private().commands;
        if (pos >= commands.len) return null;

        return commands.list.items(.command)[@intCast(pos)].action;
    }

    pub fn state(self: *CommandListModel) State {
        const priv = self.private();

        return if (priv.tokens.items.len > 0)
            if (priv.commands.len > 0) .items else .not_found
        else
            .prompt;
    }

    // Boilerplate
    pub fn as(self: *CommandListModel, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }
    fn private(self: *CommandListModel) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    // Lifecycle
    fn finalize(self: *CommandListModel) callconv(.C) void {
        const priv = self.private();
        priv.tokens.deinit(priv.alloc.allocator());
        priv.commands.deinit(priv.alloc.allocator());
    }

    // Properties
    pub fn setQuery(self: *CommandListModel, query: ?[:0]const u8) void {
        const priv = self.private();

        priv.tokens.clearRetainingCapacity();
        if (query) |q| {
            var it = std.mem.tokenizeScalar(u8, q, ' ');
            while (it.next()) |token|
                priv.tokens.append(priv.alloc.allocator(), token) catch @panic("OOM");
        }

        const old_len = priv.commands.sortAndFilter(priv.tokens.items);
        self.as(gio.ListModel).itemsChanged(0, old_len, priv.commands.len);
    }

    // ListModel interface
    fn getItem(list: *gio.ListModel, pos: c_uint) callconv(.C) ?*gobject.Object {
        const self = gobject.ext.cast(CommandListModel, list) orelse return null;
        const priv = self.private();
        if (pos >= priv.commands.len) return null;

        const item = priv.commands.list.get(@intCast(pos));
        return gobject.ext.as(gobject.Object, CommandObject.new(item));
    }
    fn getItemType(_: *gio.ListModel) callconv(.C) gobject.Type {
        return CommandObject.getGObjectType();
    }
    fn getNItems(list: *gio.ListModel) callconv(.C) c_uint {
        const self = gobject.ext.cast(CommandListModel, list) orelse return 0;
        return self.private().commands.len;
    }

    // SelectionModel interface
    fn isSelected(_: *gtk.SelectionModel, pos: c_uint) callconv(.C) c_int {
        // Always select the first item (purely visual)
        return @intFromBool(pos == 0);
    }

    pub const Class = extern struct {
        parent: Parent.Class,

        pub const Instance = CommandListModel;

        fn init(class: *Class) callconv(.C) void {
            gobject.ext.registerProperties(class, &.{
                properties.query.impl,
            });
            gobject.Object.virtual_methods.finalize.implement(class, finalize);
        }

        fn initListModel(iface: *gio.ListModel.Iface) callconv(.C) void {
            gio.ListModel.virtual_methods.get_item.implement(iface, getItem);
            gio.ListModel.virtual_methods.get_item_type.implement(iface, getItemType);
            gio.ListModel.virtual_methods.get_n_items.implement(iface, getNItems);
        }

        fn initSelectionModel(iface: *gtk.SelectionModel.Iface) callconv(.C) void {
            gtk.SelectionModel.virtual_methods.is_selected.implement(iface, isSelected);
        }
    };
};

const CommandList = struct {
    list: std.MultiArrayList(Item) = .{},
    len: c_uint = 0,

    const Item = struct {
        command: Binding.Command,
        accelerator: ?[:0]const u8 = null,
        rank: ?f64 = null,
        var offset: c_int = 0;
    };

    fn init(alloc: std.mem.Allocator) !CommandList {
        var list: std.MultiArrayList(Item) = .{};
        try list.ensureTotalCapacity(alloc, Binding.commands.len);

        for (Binding.commands) |command| {
            switch (command.action) {
                // macOS-only
                .prompt_surface_title,
                .close_all_windows,
                .toggle_secure_input,
                .toggle_quick_terminal,
                => continue,

                else => {},
            }

            list.appendAssumeCapacity(.{ .command = command });
        }

        return .{
            .list = list,
            .len = @intCast(list.len),
        };
    }
    fn deinit(self: *CommandList, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }

    /// Sort and filter the current list of commands based on a slice of tokens.
    /// Returns the old size of the command list.
    fn sortAndFilter(self: *CommandList, tokens: [][]const u8) c_uint {
        const old_len = self.len;

        if (tokens.len == 0) {
            self.len = @intCast(self.list.len);
            return old_len;
        }

        const cmds = self.list.items(.command);
        const ranks = self.list.items(.rank);
        for (cmds, ranks) |cmd, *rank| {
            rank.* = zf.rank(cmd.title, tokens, .{
                .to_lower = true,
                .plain = true,
            });
        }
        self.list.sort(self);

        // Limit new length to the items that are not null
        // (null rank correspond to non-matches)
        const new_len = std.mem.indexOfScalar(?f64, ranks, null);
        self.len = @intCast(new_len orelse self.list.len);
        return old_len;
    }

    fn updateBindings(self: *CommandList, alloc: std.mem.Allocator, set: Binding.Set) !void {
        var buf: [256]u8 = undefined;
        for (self.list.items(.command), self.list.items(.accelerator)) |cmd, *accel| {
            if (accel.*) |accel_| alloc.free(accel_);

            accel.* = accel: {
                const trigger = set.getTrigger(cmd.action) orelse break :accel null;
                const accel_ = try key.accelFromTrigger(&buf, trigger) orelse break :accel null;
                break :accel try alloc.dupeZ(u8, accel_);
            };
        }
    }

    // A custom sorting criterion that guarantees that nulls
    // (non-matches) always sink to the bottom of the list,
    // so we can easily exclude them
    pub fn lessThan(self: *CommandList, a: usize, b: usize) bool {
        const ranks = self.list.items(.rank);

        // If a is null, then always place a (null) after b
        const rank_a = ranks[a] orelse return false;
        // If a is non-null and b is null, then put b (null) after a
        const rank_b = ranks[b] orelse return true;

        // Normal ranking logic
        return rank_a < rank_b;
    }
};

pub const CommandObject = extern struct {
    parent: Parent,

    pub const Parent = gobject.Object;
    const Private = CommandList.Item;

    pub const getGObjectType = gobject.ext.defineClass(CommandObject, .{
        .classInit = Class.init,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(name, CommandObject, ?[:0]const u8, .{
                .default = "",
                .accessor = .{ .getter = getTitle, .setter = @ptrCast(&noop) },
                .flags = .{ .readable = true },
            });
        };
        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(name, CommandObject, ?[:0]const u8, .{
                .default = "",
                .accessor = .{ .getter = getDescription, .setter = @ptrCast(&noop) },
                .flags = .{ .readable = true },
            });
        };
        pub const accelerator = struct {
            pub const name = "accelerator";
            const impl = gobject.ext.defineProperty(name, CommandObject, ?[:0]const u8, .{
                .default = "",
                .accessor = .{ .getter = getAccelerator, .setter = @ptrCast(&noop) },
                .flags = .{ .readable = true },
            });
        };
    };

    pub fn new(item: CommandList.Item) *CommandObject {
        const self = gobject.ext.newInstance(CommandObject, .{});
        self.private().* = item;
        return self;
    }
    fn private(self: *CommandObject) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    fn getTitle(self: *CommandObject) ?[:0]const u8 {
        return self.private().command.title;
    }
    fn getDescription(self: *CommandObject) ?[:0]const u8 {
        return self.private().command.description;
    }
    fn getAccelerator(self: *CommandObject) ?[:0]const u8 {
        return self.private().accelerator;
    }

    pub const Class = extern struct {
        parent: Parent.Class,

        pub const Instance = CommandObject;

        fn init(class: *Class) callconv(.C) void {
            gobject.ext.registerProperties(class, &.{
                properties.title.impl,
                properties.description.impl,
                properties.accelerator.impl,
            });
        }
    };
};

// For some bizarre reason zig-gobject forces you to set a setter for a read-only field...
fn noop() callconv(.C) void {
    unreachable;
}
