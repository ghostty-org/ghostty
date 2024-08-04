//! A binding maps some input trigger to an action. When the trigger
//! occurs, the action is performed.
const Binding = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const key = @import("key.zig");

/// The trigger that needs to be performed to execute the action.
trigger: Trigger,

/// The action to take if this binding matches
action: Action,

/// True if this binding should consume the input when the
/// action is triggered.
consumed: bool = true,

pub const Error = error{
    InvalidFormat,
    InvalidAction,
};

/// Parse the format "ctrl+a=csi:A" into a binding. The format is
/// specifically "trigger=action". Trigger is a "+"-delimited series of
/// modifiers and keys. Action is the action name and optionally a
/// parameter after a colon, i.e. "csi:A" or "ignore".
pub fn parse(raw_input: []const u8) !Binding {
    // NOTE(mitchellh): This is not the most efficient way to do any
    // of this, I welcome any improvements here!

    // If our entire input is prefixed with "unconsumed:" then we are
    // not consuming this keybind when the action is triggered.
    const unconsumed_prefix = "unconsumed:";
    const unconsumed = std.mem.startsWith(u8, raw_input, unconsumed_prefix);
    const start_idx = if (unconsumed) unconsumed_prefix.len else 0;
    const input = raw_input[start_idx..];

    // Find the first = which splits are mapping into the trigger
    // and action, respectively.
    const eqlIdx = std.mem.indexOf(u8, input, "=") orelse return Error.InvalidFormat;

    // Determine our trigger conditions by parsing the part before
    // the "=", i.e. "ctrl+shift+a" or "a"
    const trigger = trigger: {
        var result: Trigger = .{};
        var iter = std.mem.tokenizeScalar(u8, input[0..eqlIdx], '+');
        loop: while (iter.next()) |part| {
            // All parts must be non-empty
            if (part.len == 0) return Error.InvalidFormat;

            // Check if its a modifier
            const modsInfo = @typeInfo(key.Mods).Struct;
            inline for (modsInfo.fields) |field| {
                if (field.type == bool) {
                    if (std.mem.eql(u8, part, field.name)) {
                        // Repeat not allowed
                        if (@field(result.mods, field.name)) return Error.InvalidFormat;
                        @field(result.mods, field.name) = true;
                        continue :loop;
                    }
                }
            }

            // Alias modifiers
            const alias_mods = .{
                .{ "cmd", "super" },    .{ "command", "super" },
                .{ "opt", "alt" },      .{ "option", "alt" },
                .{ "control", "ctrl" },
            };
            inline for (alias_mods) |pair| {
                if (std.mem.eql(u8, part, pair[0])) {
                    // Repeat not allowed
                    if (@field(result.mods, pair[1])) return Error.InvalidFormat;
                    @field(result.mods, pair[1]) = true;
                    continue :loop;
                }
            }

            // If the key starts with "physical" then this is an physical key.
            const physical_prefix = "physical:";
            const physical = std.mem.startsWith(u8, part, physical_prefix);
            const key_part = if (physical) part[physical_prefix.len..] else part;

            // Check if its a key
            const keysInfo = @typeInfo(key.Key).Enum;
            inline for (keysInfo.fields) |field| {
                if (!std.mem.eql(u8, field.name, "invalid")) {
                    if (std.mem.eql(u8, key_part, field.name)) {
                        // Repeat not allowed
                        if (!result.isKeyUnset()) return Error.InvalidFormat;

                        const keyval = @field(key.Key, field.name);
                        result.key = if (physical)
                            .{ .physical = keyval }
                        else
                            .{ .translated = keyval };
                        continue :loop;
                    }
                }
            }

            // If we're still unset and we have exactly one unicode
            // character then we can use that as a key.
            if (result.isKeyUnset()) unicode: {
                // Invalid UTF8 drops to invalid format
                const view = std.unicode.Utf8View.init(key_part) catch break :unicode;
                var it = view.iterator();

                // No codepoints or multiple codepoints drops to invalid format
                const cp = it.nextCodepoint() orelse break :unicode;
                if (it.nextCodepoint() != null) break :unicode;

                result.key = .{ .unicode = cp };
                continue :loop;
            }

            // We didn't recognize this value
            return Error.InvalidFormat;
        }

        break :trigger result;
    };

    // Find a matching action
    const action = try Action.parse(input[eqlIdx + 1 ..]);

    return Binding{
        .trigger = trigger,
        .action = action,
        .consumed = !unconsumed,
    };
}

/// The set of actions that a keybinding can take.
pub const Action = union(enum) {
    /// Ignore this key combination, don't send it to the child process, just
    /// black hole it.
    ignore: void,

    /// This action is used to flag that the binding should be removed from
    /// the set. This should never exist in an active set and `set.put` has an
    /// assertion to verify this.
    unbind: void,

    /// Send a CSI sequence. The value should be the CSI sequence without the
    /// CSI header (`ESC ]` or `\x1b]`).
    csi: []const u8,

    /// Send an `ESC` sequence.
    esc: []const u8,

    // Send the given text. Uses Zig string literal syntax. This is currently
    // not validated. If the text is invalid (i.e. contains an invalid escape
    // sequence), the error will currently only show up in logs.
    text: []const u8,

    /// Send data to the pty depending on whether cursor key mode is enabled
    /// (`application`) or disabled (`normal`).
    cursor_key: CursorKey,

    /// Reset the terminal. This can fix a lot of issues when a running
    /// program puts the terminal into a broken state. This is equivalent to
    /// when you type "reset" and press enter.
    ///
    /// If you do this while in a TUI program such as vim, this may break
    /// the program. If you do this while in a shell, you may have to press
    /// enter after to get a new prompt.
    reset: void,

    /// Copy and paste.
    copy_to_clipboard: void,
    paste_from_clipboard: void,
    paste_from_selection: void,

    /// Increase/decrease the font size by a certain amount.
    increase_font_size: f32,
    decrease_font_size: f32,

    /// Reset the font size to the original configured size.
    reset_font_size: void,

    /// Clear the screen. This also clears all scrollback.
    clear_screen: void,

    /// Select all text on the screen.
    select_all: void,

    /// Scroll the screen varying amounts.
    scroll_to_top: void,
    scroll_to_bottom: void,
    scroll_page_up: void,
    scroll_page_down: void,
    scroll_page_fractional: f32,
    scroll_page_lines: i16,

    /// Adjust an existing selection in a given direction. This action
    /// does nothing if there is no active selection.
    adjust_selection: AdjustSelection,

    /// Jump the viewport forward or back by prompt. Positive number is the
    /// number of prompts to jump forward, negative is backwards.
    jump_to_prompt: i16,

    /// Write the entire scrollback _and_ the active screen into a temporary
    /// file. The action determines what to do with the filepath. Valid values
    /// are:
    ///
    ///   - "paste": Paste the file path into the terminal.
    ///   - "open": Open the file in the default OS editor for text files.
    write_all_file: WriteScreenAction,

    /// Write the entire scrollback into a temporary file. Note that this does
    /// not include the contents of the active screen. The action determines
    /// what to do with the filepath. Valid values are:
    ///
    ///   - "paste": Paste the file path into the terminal.
    ///   - "open": Open the file in the default OS editor for text files.
    write_scrollback_file: WriteScreenAction,

    /// Write the active screen into a temporary file. The action determines
    /// what to do with the filepath. Valid values are:
    ///
    ///   - "paste": Paste the file path into the terminal.
    ///   - "open": Open the file in the default OS editor for text files.
    write_screen_file: WriteScreenAction,

    /// Write the selected text into a temporary file. If there is no selected
    /// text this does nothing (it doesn't even create an empty file). The
    /// action determines what to do with the filepath. Valid values are:
    ///
    ///   - "paste": Paste the file path into the terminal.
    ///   - "open": Open the file in the default OS editor for text files.
    write_selection_file: WriteScreenAction,

    /// Open a new window.
    new_window: void,

    /// Open a new tab.
    new_tab: void,

    /// Go to the previous tab.
    previous_tab: void,

    /// Go to the next tab.
    next_tab: void,

    /// Go to the tab with the specific number, 1-indexed.
    goto_tab: usize,

    /// Create a new split in the given direction. The new split will appear in
    /// the direction given.
    new_split: SplitDirection,

    /// Focus on a split in a given direction.
    goto_split: SplitFocusDirection,

    /// zoom/unzoom the current split.
    toggle_split_zoom: void,

    /// Resize the current split by moving the split divider in the given
    /// direction
    resize_split: SplitResizeParameter,

    /// Equalize all splits in the current window
    equalize_splits: void,

    /// Show, hide, or toggle the terminal inspector for the currently focused
    /// terminal.
    inspector: InspectorMode,

    /// Open the configuration file in the default OS editor. If your default OS
    /// editor isn't configured then this will fail. Currently, any failures to
    /// open the configuration will show up only in the logs.
    open_config: void,

    /// Reload the configuration. The exact meaning depends on the app runtime
    /// in use but this usually involves re-reading the configuration file
    /// and applying any changes. Note that not all changes can be applied at
    /// runtime.
    reload_config: void,

    /// Close the current "surface", whether that is a window, tab, split, etc.
    /// This only closes ONE surface. This will trigger close confirmation as
    /// configured.
    close_surface: void,

    /// Close the window, regardless of how many tabs or splits there may be.
    /// This will trigger close confirmation as configured.
    close_window: void,

    /// Close all windows. This will trigger close confirmation as configured.
    /// This only works for macOS currently.
    close_all_windows: void,

    /// Toggle fullscreen mode of window.
    toggle_fullscreen: void,

    /// Toggle window decorations on and off. This only works on Linux.
    toggle_window_decorations: void,

    /// Quit ghostty.
    quit: void,

    pub const CursorKey = struct {
        normal: []const u8,
        application: []const u8,
    };

    pub const AdjustSelection = enum {
        left,
        right,
        up,
        down,
        page_up,
        page_down,
        home,
        end,
        beginning_of_line,
        end_of_line,
    };

    pub const SplitDirection = enum {
        right,
        down,
        auto, // splits along the larger direction

        // Note: we don't support top or left yet
    };

    // Extern because it is used in the embedded runtime ABI.
    pub const SplitFocusDirection = enum(c_int) {
        previous,
        next,

        top,
        left,
        bottom,
        right,
    };

    // Extern because it is used in the embedded runtime ABI.
    pub const SplitResizeDirection = enum(c_int) {
        up,
        down,
        left,
        right,
    };

    pub const SplitResizeParameter = struct {
        SplitResizeDirection,
        u16,
    };

    pub const WriteScreenAction = enum {
        paste,
        open,
    };

    // Extern because it is used in the embedded runtime ABI.
    pub const InspectorMode = enum(c_int) {
        toggle,
        show,
        hide,
    };

    fn parseEnum(comptime T: type, value: []const u8) !T {
        return std.meta.stringToEnum(T, value) orelse return Error.InvalidFormat;
    }

    fn parseInt(comptime T: type, value: []const u8) !T {
        return std.fmt.parseInt(T, value, 10) catch return Error.InvalidFormat;
    }

    fn parseFloat(comptime T: type, value: []const u8) !T {
        return std.fmt.parseFloat(T, value) catch return Error.InvalidFormat;
    }

    fn parseParameter(
        comptime field: std.builtin.Type.UnionField,
        param: []const u8,
    ) !field.type {
        return switch (@typeInfo(field.type)) {
            .Enum => try parseEnum(field.type, param),
            .Int => try parseInt(field.type, param),
            .Float => try parseFloat(field.type, param),
            .Struct => |info| blk: {
                // Only tuples are supported to avoid ambiguity with field
                // ordering
                comptime assert(info.is_tuple);

                var it = std.mem.splitAny(u8, param, ",");
                var value: field.type = undefined;
                inline for (info.fields) |field_| {
                    const next = it.next() orelse return Error.InvalidFormat;
                    @field(value, field_.name) = switch (@typeInfo(field_.type)) {
                        .Enum => try parseEnum(field_.type, next),
                        .Int => try parseInt(field_.type, next),
                        .Float => try parseFloat(field_.type, next),
                        else => unreachable,
                    };
                }

                // If we have extra parameters it is an error
                if (it.next() != null) return Error.InvalidFormat;

                break :blk value;
            },

            else => unreachable,
        };
    }

    /// Parse an action in the format of "key=value" where key is the
    /// action name and value is the action parameter. The parameter
    /// is optional depending on the action.
    pub fn parse(input: []const u8) !Action {
        // Split our action by colon. A colon may not exist for some
        // actions so it is optional. The part preceding the colon is the
        // action name.
        const colonIdx = std.mem.indexOf(u8, input, ":");
        const action = input[0..(colonIdx orelse input.len)];

        // An action name is always required
        if (action.len == 0) return Error.InvalidFormat;

        const actionInfo = @typeInfo(Action).Union;
        inline for (actionInfo.fields) |field| {
            if (std.mem.eql(u8, action, field.name)) {
                // If the field type is void we expect no value
                switch (field.type) {
                    void => {
                        if (colonIdx != null) return Error.InvalidFormat;
                        return @unionInit(Action, field.name, {});
                    },

                    []const u8 => {
                        const idx = colonIdx orelse return Error.InvalidFormat;
                        const param = input[idx + 1 ..];
                        return @unionInit(Action, field.name, param);
                    },

                    // Cursor keys can't be set currently
                    Action.CursorKey => return Error.InvalidAction,

                    else => {
                        const idx = colonIdx orelse return Error.InvalidFormat;
                        const param = input[idx + 1 ..];
                        return @unionInit(
                            Action,
                            field.name,
                            try parseParameter(field, param),
                        );
                    },
                }
            }
        }

        return Error.InvalidAction;
    }

    /// Implements the formatter for the fmt package. This encodes the
    /// action back into the format used by parse.
    pub fn format(
        self: Action,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;

        switch (self) {
            inline else => |value| {
                // All actions start with the tag.
                try writer.print("{s}", .{@tagName(self)});

                // Only write the value depending on the type if it's not void
                if (@TypeOf(value) != void) {
                    try writer.writeAll(":");
                    try formatValue(writer, value);
                }
            },
        }
    }

    fn formatValue(
        writer: anytype,
        value: anytype,
    ) !void {
        const Value = @TypeOf(value);
        const value_info = @typeInfo(Value);
        switch (Value) {
            void => {},
            []const u8 => try writer.print("{s}", .{value}),
            else => switch (value_info) {
                .Enum => try writer.print("{s}", .{@tagName(value)}),
                .Float => try writer.print("{d}", .{value}),
                .Int => try writer.print("{d}", .{value}),
                .Struct => |info| if (!info.is_tuple) {
                    try writer.print("{} (not configurable)", .{value});
                } else {
                    inline for (info.fields, 0..) |field, i| {
                        try formatValue(writer, @field(value, field.name));
                        if (i + 1 < info.fields.len) try writer.writeAll(",");
                    }
                },
                else => @compileError("unhandled type: " ++ @typeName(Value)),
            },
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hash(self: Action) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Always has the active tag.
        const Tag = @typeInfo(Action).Union.tag_type.?;
        std.hash.autoHash(&hasher, @as(Tag, self));

        // Hash the value of the field.
        switch (self) {
            inline else => |field| {
                const FieldType = @TypeOf(field);
                switch (FieldType) {
                    // Do nothing for void
                    void => {},

                    // Floats are hashed by their bits. This is totally not
                    // portable and there are edge cases such as NaNs and
                    // signed zeros but these are not cases we expect for
                    // our bindings.
                    f32 => std.hash.autoHash(
                        &hasher,
                        @as(u32, @bitCast(field)),
                    ),
                    f64 => std.hash.autoHash(
                        &hasher,
                        @as(u64, @bitCast(field)),
                    ),

                    // Everything else automatically handle.
                    else => std.hash.autoHashStrat(
                        &hasher,
                        field,
                        .DeepRecursive,
                    ),
                }
            },
        }

        return hasher.final();
    }
};

// A key for the C API to execute an action. This must be kept in sync
// with include/ghostty.h.
pub const Key = enum(c_int) {
    copy_to_clipboard,
    paste_from_clipboard,
    new_tab,
    new_window,
};

/// Trigger is the associated key state that can trigger an action.
/// This is an extern struct because this is also used in the C API.
///
/// This must be kept in sync with include/ghostty.h ghostty_input_trigger_s
pub const Trigger = struct {
    /// The key that has to be pressed for a binding to take action.
    key: Trigger.Key = .{ .translated = .invalid },

    /// The key modifiers that must be active for this to match.
    mods: key.Mods = .{},

    pub const Key = union(C.Tag) {
        /// key is the translated version of a key. This is the key that
        /// a logical keyboard layout at the OS level would translate the
        /// physical key to. For example if you use a US hardware keyboard
        /// but have a Dvorak layout, the key would be the Dvorak key.
        translated: key.Key,

        /// key is the "physical" version. This is the same as mapped for
        /// standard US keyboard layouts. For non-US keyboard layouts, this
        /// is used to bind to a physical key location rather than a translated
        /// key.
        physical: key.Key,

        /// This is used for binding to keys that produce a certain unicode
        /// codepoint. This is useful for binding to keys that don't have a
        /// registered keycode with Ghostty.
        unicode: u21,
    };

    /// The extern struct used for triggers in the C API.
    pub const C = extern struct {
        tag: Tag = .translated,
        key: C.Key = .{ .translated = .invalid },
        mods: key.Mods = .{},

        pub const Tag = enum(c_int) {
            translated,
            physical,
            unicode,
        };

        pub const Key = extern union {
            translated: key.Key,
            physical: key.Key,
            unicode: u32,
        };
    };

    /// Returns true if this trigger has no key set.
    pub fn isKeyUnset(self: Trigger) bool {
        return switch (self.key) {
            .translated => |v| v == .invalid,
            else => false,
        };
    }

    /// Returns a hash code that can be used to uniquely identify this trigger.
    pub fn hash(self: Trigger) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, self.key);
        std.hash.autoHash(&hasher, self.mods.binding());
        return hasher.final();
    }

    /// Convert the trigger to a C API compatible trigger.
    pub fn cval(self: Trigger) C {
        return .{
            .tag = self.key,
            .key = switch (self.key) {
                .translated => |v| .{ .translated = v },
                .physical => |v| .{ .physical = v },
                .unicode => |v| .{ .unicode = @intCast(v) },
            },
            .mods = self.mods,
        };
    }

    /// Format implementation for fmt package.
    pub fn format(
        self: Trigger,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;

        // Modifiers first
        if (self.mods.super) try writer.writeAll("super+");
        if (self.mods.ctrl) try writer.writeAll("ctrl+");
        if (self.mods.alt) try writer.writeAll("alt+");
        if (self.mods.shift) try writer.writeAll("shift+");

        // Key
        switch (self.key) {
            .translated => |k| try writer.print("{s}", .{@tagName(k)}),
            .physical => |k| try writer.print("physical:{s}", .{@tagName(k)}),
            .unicode => |c| try writer.print("{u}", .{c}),
        }
    }
};

/// A structure that contains a set of bindings and focuses on fast lookup.
/// The use case is that this will be called on EVERY key input to look
/// for an associated action so it must be fast.
pub const Set = struct {
    const HashMap = std.HashMapUnmanaged(
        Trigger,
        Action,
        Context(Trigger),
        std.hash_map.default_max_load_percentage,
    );

    const ReverseMap = std.HashMapUnmanaged(
        Action,
        Trigger,
        Context(Action),
        std.hash_map.default_max_load_percentage,
    );

    const UnconsumedMap = std.HashMapUnmanaged(
        Trigger,
        void,
        Context(Trigger),
        std.hash_map.default_max_load_percentage,
    );

    /// The set of bindings.
    bindings: HashMap = .{},

    /// The reverse mapping of action to binding. Note that multiple
    /// bindings can map to the same action and this map will only have
    /// the most recently added binding for an action.
    reverse: ReverseMap = .{},

    /// The map of triggers that explicitly do not want to be consumed
    /// when matched. A trigger is "consumed" when it is not further
    /// processed and potentially sent to the terminal. An "unconsumed"
    /// trigger will perform both its action and also continue normal
    /// encoding processing (if any).
    ///
    /// This is stored as a separate map since unconsumed triggers are
    /// rare and we don't want to bloat our map with a byte per entry
    /// (for boolean state) when most entries will be consumed.
    ///
    /// Assert: trigger in this map is also in bindings.
    unconsumed: UnconsumedMap = .{},

    pub fn deinit(self: *Set, alloc: Allocator) void {
        self.bindings.deinit(alloc);
        self.reverse.deinit(alloc);
        self.unconsumed.deinit(alloc);
        self.* = undefined;
    }

    /// Add a binding to the set. If the binding already exists then
    /// this will overwrite it.
    pub fn put(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
    ) Allocator.Error!void {
        try self.put_(alloc, t, action, true);
    }

    /// Same as put but marks the trigger as unconsumed. An unconsumed
    /// trigger will evaluate the action and continue to encode for the
    /// terminal.
    ///
    /// This is a separate function because this case is rare.
    pub fn putUnconsumed(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
    ) Allocator.Error!void {
        try self.put_(alloc, t, action, false);
    }

    fn put_(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
        consumed: bool,
    ) Allocator.Error!void {
        // unbind should never go into the set, it should be handled prior
        assert(action != .unbind);

        const gop = try self.bindings.getOrPut(alloc, t);
        if (!consumed) try self.unconsumed.put(alloc, t, {});

        // If we have an existing binding for this trigger, we have to
        // update the reverse mapping to remove the old action.
        if (gop.found_existing) {
            const t_hash = t.hash();
            var it = self.reverse.iterator();
            while (it.next()) |reverse_entry| it: {
                if (t_hash == reverse_entry.value_ptr.hash()) {
                    self.reverse.removeByPtr(reverse_entry.key_ptr);
                    break :it;
                }
            }

            // We also have to remove the unconsumed state if it exists.
            if (consumed) _ = self.unconsumed.remove(t);
        }

        gop.value_ptr.* = action;
        errdefer _ = self.bindings.remove(t);
        try self.reverse.put(alloc, action, t);
        errdefer _ = self.reverse.remove(action);
    }

    /// Get a binding for a given trigger.
    pub fn get(self: Set, t: Trigger) ?Action {
        return self.bindings.get(t);
    }

    /// Get a trigger for the given action. An action can have multiple
    /// triggers so this will return the first one found.
    pub fn getTrigger(self: Set, a: Action) ?Trigger {
        return self.reverse.get(a);
    }

    /// Returns true if the given trigger should be consumed. Requires
    /// that trigger is in the set to be valid so this should only follow
    /// a non-null get.
    pub fn getConsumed(self: Set, t: Trigger) bool {
        return self.unconsumed.get(t) == null;
    }

    /// Remove a binding for a given trigger.
    pub fn remove(self: *Set, t: Trigger) void {
        const action = self.bindings.get(t) orelse return;
        _ = self.bindings.remove(t);
        _ = self.unconsumed.remove(t);

        // Look for a matching action in bindings and use that.
        // Note: we'd LIKE to replace this with the most recent binding but
        // our hash map obviously has no concept of ordering so we have to
        // choose whatever. Maybe a switch to an array hash map here.
        const action_hash = action.hash();
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.hash() == action_hash) {
                self.reverse.putAssumeCapacity(action, entry.key_ptr.*);
                break;
            }
        } else {
            // No over trigger points to this action so we remove
            // the reverse mapping completely.
            _ = self.reverse.remove(action);
        }
    }

    /// The hash map context for the set. This defines how the hash map
    /// gets the hash key and checks for equality.
    fn Context(comptime KeyType: type) type {
        return struct {
            pub fn hash(ctx: @This(), k: KeyType) u64 {
                _ = ctx;
                return k.hash();
            }

            pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
                return ctx.hash(a) == ctx.hash(b);
            }
        };
    }
};

test "parse: triggers" {
    const testing = std.testing;

    // single character
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .translated = .a } },
            .action = .{ .ignore = {} },
        },
        try parse("a=ignore"),
    );

    // single modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("ctrl+a=ignore"));

    // multiple modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true, .ctrl = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+ctrl+a=ignore"));

    // key can come before modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("a+shift=ignore"));

    // physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+physical:a=ignore"));

    // unicode keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'ö' },
        },
        .action = .{ .ignore = {} },
    }, try parse("shift+ö=ignore"));

    // unconsumed keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
        .consumed = false,
    }, try parse("unconsumed:shift+a=ignore"));

    // unconsumed physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .a },
        },
        .action = .{ .ignore = {} },
        .consumed = false,
    }, try parse("unconsumed:physical:a+shift=ignore"));

    // invalid key
    try testing.expectError(Error.InvalidFormat, parse("foo=ignore"));

    // repeated control
    try testing.expectError(Error.InvalidFormat, parse("shift+shift+a=ignore"));

    // multiple character
    try testing.expectError(Error.InvalidFormat, parse("a+b=ignore"));
}

test "parse: modifier aliases" {
    const testing = std.testing;

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("cmd+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("command+a=ignore"));

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("opt+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("option+a=ignore"));

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .translated = .a },
        },
        .action = .{ .ignore = {} },
    }, try parse("control+a=ignore"));
}

test "parse: action invalid" {
    const testing = std.testing;

    // invalid action
    try testing.expectError(Error.InvalidAction, parse("a=nopenopenope"));
}

test "parse: action no parameters" {
    const testing = std.testing;

    // no parameters
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .translated = .a } },
            .action = .{ .ignore = {} },
        },
        try parse("a=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parse("a=ignore:A"));
}

test "parse: action with string" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=csi:A");
        try testing.expect(binding.action == .csi);
        try testing.expectEqualStrings("A", binding.action.csi);
    }
    // parameter
    {
        const binding = try parse("a=esc:A");
        try testing.expect(binding.action == .esc);
        try testing.expectEqualStrings("A", binding.action.esc);
    }
}

test "parse: action with enum" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=new_split:right");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.right, binding.action.new_split);
    }
}

test "parse: action with int" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=jump_to_prompt:-1");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, -1), binding.action.jump_to_prompt);
    }
    {
        const binding = try parse("a=jump_to_prompt:10");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, 10), binding.action.jump_to_prompt);
    }
}

test "parse: action with float" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=scroll_page_fractional:-0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, -0.5), binding.action.scroll_page_fractional);
    }
    {
        const binding = try parse("a=scroll_page_fractional:+0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, 0.5), binding.action.scroll_page_fractional);
    }
}

test "parse: action with a tuple" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parse("a=resize_split:up,10");
        try testing.expect(binding.action == .resize_split);
        try testing.expectEqual(Action.SplitResizeDirection.up, binding.action.resize_split[0]);
        try testing.expectEqual(@as(u16, 10), binding.action.resize_split[1]);
    }

    // missing parameter
    try testing.expectError(Error.InvalidFormat, parse("a=resize_split:up"));

    // too many
    try testing.expectError(Error.InvalidFormat, parse("a=resize_split:up,10,12"));

    // invalid type
    try testing.expectError(Error.InvalidFormat, parse("a=resize_split:up,four"));
}

test "set: maintains reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .translated = .a } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.translated == .a);
    }

    // should be most recent
    try s.put(alloc, .{ .key = .{ .translated = .b } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.translated == .b);
    }

    // removal should replace
    s.remove(.{ .key = .{ .translated = .b } });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.translated == .a);
    }
}

test "set: overriding a mapping updates reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .translated = .a } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.translated == .a);
    }

    // should be most recent
    try s.put(alloc, .{ .key = .{ .translated = .a } }, .{ .new_tab = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} });
        try testing.expect(trigger == null);
    }
}

test "set: consumed state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .translated = .a } }, .{ .new_window = {} });
    try testing.expect(s.getConsumed(.{ .key = .{ .translated = .a } }));

    try s.putUnconsumed(alloc, .{ .key = .{ .translated = .a } }, .{ .new_window = {} });
    try testing.expect(!s.getConsumed(.{ .key = .{ .translated = .a } }));

    try s.put(alloc, .{ .key = .{ .translated = .a } }, .{ .new_window = {} });
    try testing.expect(s.getConsumed(.{ .key = .{ .translated = .a } }));
}
