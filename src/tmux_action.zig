//! Translation of Ghostty binding actions into tmux commands.
//!
//! While a surface takes part in a tmux control mode session, the panes
//! and windows behind it live in the tmux server. Creating a native split
//! or closing a native tab on our own would leave the two views out of
//! sync, so actions that create, close, focus or arrange them are
//! expressed as tmux commands instead, and the notifications tmux sends
//! back are what change the native UI.
//!
//! This module is the pure half of that: it knows nothing about apprts,
//! surfaces or the session, only the facts in `Context`, so every mapping
//! can be tested down to the exact command text.
//!
//! Every `Binding.Action` is classified in the switch in `translate`.
//! There is deliberately no `else` there, so adding an action forces a
//! decision about what it means while attached to tmux.
//!
//! Actions that only concern our view of a terminal stay native: byte
//! output for the pane (which the follower wraps into `send-keys`), the
//! clipboard, font size, search, scrolling and selection, native window
//! and app actions, and undo/redo. Pane commands carry `-t %<pane>` only
//! when the action came from a follower; the gateway has no pane, so tmux
//! uses its active one. Text from the user goes through the `Title` and
//! `PaneTarget` formatters, which escape tmux's quoting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");

const Action = input.Binding.Action;

/// What we know about where an action was triggered.
pub const Context = struct {
    /// The tmux pane of the surface the action came from. Null for the
    /// gateway, which has no pane: pane commands then carry no target and
    /// tmux uses its active pane.
    pane: ?usize = null,

    /// The tmux window that holds `pane`. Null when it isn't known, which
    /// is always the case for the gateway.
    window: ?usize = null,

    /// The tmux windows shown as tabs of the same native window as
    /// `window`, in native tab order, including `window` itself. Empty
    /// when `window` is null.
    tabs: []const usize = &.{},

    /// Whether the surface is wider than it is tall. This is what
    /// `new_split:auto` splits along.
    wider_than_tall: bool = false,

    /// The size of a cell in the unit that `resize_split` amounts use, so
    /// that an amount can be turned into the cells tmux counts in.
    cell_width: f32 = 1,
    cell_height: f32 = 1,

    /// Where a new tab goes among the tabs of its native window, as
    /// `window-new-tab-position` says for native tabs.
    new_tab_position: NewTabPosition = .current,

    /// Whether closing may need confirmation (`confirm-close-surface`).
    /// Closing a pane or window kills the programs in it, so the close
    /// actions then stay native: the apprt asks as it does for any close
    /// and reaches tmux through its native close events.
    confirm_close: bool = false,

    pub const NewTabPosition = enum {
        /// Right after the tab of `window`.
        current,

        /// After the last tab of the native window.
        end,
    };
};

/// What to do about an action.
pub const Result = union(enum) {
    /// tmux has no say in this action; Ghostty performs it itself.
    native,

    /// The action means nothing here and must not run natively either,
    /// for example moving a tab when there is only one.
    consumed,

    /// Send commands to tmux.
    commands: Commands,

    /// Leave the session with `detach-client`. This isn't a command in
    /// `commands` because the viewer is torn down right after it.
    detach: Detach,

    /// Show the native tab title prompt. The title it returns comes back
    /// as `set_tab_title`. The payload is the tmux window to rename.
    prompt_tab_title: usize,

    /// Show the native surface title prompt. The title it returns comes
    /// back as `set_surface_title`. The payload is the tmux pane to
    /// retitle.
    prompt_surface_title: usize,

    /// Let the native tab move to a new native window happen, and give
    /// the tmux window (the payload) a group of its own so that a later
    /// layout puts it there. tmux has no command for this: native windows
    /// are not a tmux concept.
    regroup_tab: usize,

    pub fn deinit(self: Result, alloc: Allocator) void {
        switch (self) {
            .commands => |v| v.deinit(alloc),
            else => {},
        }
    }
};

pub const Detach = struct {
    /// Perform the original action natively as well, so that `quit` still
    /// quits. Leaving the session comes first, done by the core or, for an
    /// apprt that leaves it as part of quitting, by the apprt.
    then_native: bool,
};

pub const Commands = struct {
    /// Complete tmux command lines one after another, each ending in a
    /// newline. Owned by the caller. They have to be sent one at a time:
    /// tmux answers every command with its own reply block and the
    /// viewer matches those against its command queue.
    data: []u8,

    /// How the tmux window that these commands may create is placed in
    /// the native UI.
    affinity: Affinity = .none,

    /// Also perform the original action natively afterwards. This is for
    /// actions where tmux can't echo the change back, such as a pane
    /// title, or where part of the effect is local, such as clearing the
    /// screen.
    then_native: bool = false,

    pub fn deinit(self: Commands, alloc: Allocator) void {
        alloc.free(self.data);
    }

    pub fn lines(self: Commands) Lines {
        return .{ .rest = self.data };
    }
};

pub const Affinity = enum {
    /// The commands create no window.
    none,

    /// The new window becomes a tab of the native window the action came
    /// from.
    tab,

    /// The new window gets a native window of its own.
    window,
};

/// Iterates the command lines of `Commands`.
pub const Lines = struct {
    rest: []const u8,

    /// The next command line, including its trailing newline.
    pub fn next(self: *Lines) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const end = if (std.mem.indexOfScalar(u8, self.rest, '\n')) |i|
            i + 1
        else
            self.rest.len;
        defer self.rest = self.rest[end..];
        return self.rest[0..end];
    }
};

/// Decide what an action means while attached to a tmux session.
pub fn translate(
    alloc: Allocator,
    action: Action,
    ctx: Context,
) Allocator.Error!Result {
    return switch (action) {
        //-----------------------------------------------------------
        // Splits: tmux panes

        .new_split => |direction| try newSplit(alloc, direction, ctx),
        .goto_split => |direction| try gotoSplit(alloc, direction, ctx),
        .resize_split => |param| try resizeSplit(alloc, param[0], param[1], ctx),

        // `-E` spreads the pane and its neighbors evenly, which is the
        // closest tmux has to equalizing a split tree.
        .equalize_splits => try single(
            alloc,
            "select-layout -E{f}",
            .{PaneTarget{ .pane = ctx.pane }},
        ),

        .toggle_split_zoom => try single(
            alloc,
            "resize-pane -Z{f}",
            .{PaneTarget{ .pane = ctx.pane }},
        ),

        // The gateway has no pane, and closing it means leaving control
        // mode rather than killing a pane, which the surface handles.
        .close_surface => if (ctx.confirm_close)
            .native
        else if (ctx.pane) |pane|
            try single(alloc, "kill-pane -t %{d}", .{pane})
        else
            .native,

        //-----------------------------------------------------------
        // Tabs and windows: tmux windows
        //
        // A native window is a group of tmux windows (see `Context.tabs`)
        // and each native tab is one of them.

        .new_tab => affinity(try newTab(alloc, ctx), .tab),
        .new_window => affinity(try single(alloc, "new-window", .{}), .window),

        .close_tab => |mode| if (ctx.confirm_close)
            .native
        else
            try closeTab(alloc, mode, ctx),
        .close_window => if (ctx.confirm_close) .native else try closeWindow(alloc, ctx),

        .next_tab => try stepTab(alloc, .next, ctx),
        .previous_tab => try stepTab(alloc, .previous, ctx),

        // Ghostty's `last_tab` is the rightmost tab, not tmux's
        // `last-window` (the previously selected one), so it is named by
        // id like any other tab.
        .last_tab => try gotoTab(alloc, std.math.maxInt(usize), ctx),

        .goto_tab => |n| try gotoTab(alloc, n, ctx),
        .move_tab => |amount| try moveTab(alloc, amount, ctx),

        .move_tab_to_new_window => if (ctx.window) |window|
            // With a single tab there is nothing to move out of.
            (if (ctx.tabs.len > 1) .{ .regroup_tab = window } else .native)
        else
            .native,

        //-----------------------------------------------------------
        // Titles
        //
        // The tab title is the tmux window name; tmux reports a rename
        // back and that is what updates the native tab. The surface title
        // is the tmux pane title, which tmux does not report back, so the
        // native surface title is set as well.

        .set_tab_title => |title| if (ctx.window) |window|
            try setTabTitle(alloc, window, title)
        else
            .native,

        .set_surface_title => |title| if (ctx.pane) |pane|
            try setPaneTitle(alloc, pane, title)
        else
            .native,

        .prompt_tab_title => if (ctx.window) |window|
            .{ .prompt_tab_title = window }
        else
            .native,

        .prompt_surface_title => if (ctx.pane) |pane|
            .{ .prompt_surface_title = pane }
        else
            .native,

        //-----------------------------------------------------------
        // Leaving

        // Detach rather than kill, so the tmux session survives. This
        // is also what makes quitting safe: it unregisters every pane
        // before the surfaces close, because a closing surface would
        // otherwise kill its pane.
        .close_all_windows => .{ .detach = .{ .then_native = false } },
        .quit => .{ .detach = .{ .then_native = true } },

        //-----------------------------------------------------------
        // Screen contents

        // The history lives in tmux as well as in the view; clear both.
        // The gateway only clears its own plate.
        .clear_screen => if (ctx.pane) |pane| clear: {
            var result = try single(alloc, "clear-history -t %{d}", .{pane});
            result.commands.then_native = true;
            break :clear result;
        } else .native,

        // So does the terminal state. Resetting only the view would leave
        // tmux's modes, scroll region and screen as they were, and later
        // output would be drawn on a different terminal here than in tmux.
        // A reset also drops the scrollback, natively and so in tmux.
        .reset => if (ctx.pane) |pane| reset: {
            var b: Builder = .{ .alloc = alloc };
            defer b.deinit();
            try b.add("send-keys -R -t %{d}", .{pane});
            try b.add("clear-history -t %{d}", .{pane});
            var result = try b.finish();
            result.commands.then_native = true;
            break :reset result;
        } else .native,

        //-----------------------------------------------------------
        // Native: bytes for the pane. A follower wraps what it would
        // write to a pty into `send-keys` itself.

        .csi,
        .esc,
        .text,
        .cursor_key,

        // Native: the view of the terminal. Nothing here changes what
        // tmux holds, and tmux has no notion of the viewport,
        // selection, search, clipboard or font.
        .copy_to_clipboard,
        .paste_from_clipboard,
        .paste_from_selection,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .search,
        .search_selection,
        .navigate_search,
        .start_search,
        .end_search,
        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        .toggle_readonly,
        .toggle_mouse_reporting,

        // Native: the native window and the application. tmux knows
        // nothing about OS windows, so their title, size, decoration and
        // focus are ours, and so is the rest of the application.
        .goto_window,
        .toggle_tab_overview,
        .prompt_window_title,
        .set_window_title,
        .reset_window_size,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .open_config,
        .reload_config,
        .check_for_updates,

        // Native: undoing a close would bring back a native tab for a
        // pane that tmux has already killed, so tmux has nothing to
        // offer. (Only implemented on macOS, where it's up to the apprt.)
        .undo,
        .redo,

        // Native: input handling and housekeeping.
        .ignore,
        .unbind,
        .end_key_sequence,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .crash,
        => .native,
    };
}

/// Apply an affinity to commands.
fn affinity(result: Result, value: Affinity) Result {
    var r = result;
    r.commands.affinity = value;
    return r;
}

/// A single command line, formatted.
fn single(
    alloc: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!Result {
    return .{ .commands = .{
        .data = try std.fmt.allocPrint(alloc, fmt ++ "\n", args),
    } };
}

/// Several command lines. Finishing with no lines means there was
/// nothing to do, which is a consumed action rather than an empty send.
const Builder = struct {
    alloc: Allocator,
    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *Builder) void {
        self.list.deinit(self.alloc);
    }

    fn add(
        self: *Builder,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        try self.list.print(self.alloc, fmt ++ "\n", args);
    }

    fn finish(self: *Builder) Allocator.Error!Result {
        if (self.list.items.len == 0) return .consumed;
        return .{ .commands = .{
            .data = try self.list.toOwnedSlice(self.alloc),
        } };
    }
};

/// ` -t %<pane>`, or nothing so that tmux falls back to its active pane.
const PaneTarget = struct {
    pane: ?usize,

    pub fn format(self: PaneTarget, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.pane) |id| try writer.print(" -t %{d}", .{id});
    }
};

/// Text as one argument of a tmux command line, for names and titles.
///
/// Two layers of tmux syntax apply and both are handled here:
///
///   - The command parser. Single quotes keep everything literal, so `;`,
///     `$`, `~`, `{` and backslashes are safe, except for the quote
///     itself, which is written as `'\''` (close, escaped quote, reopen).
///     A newline would end the command line, so control characters
///     become spaces.
///
///   - Format expansion. tmux expands `#{...}` and `#(...)` in window
///     names and pane titles, so every `#` is doubled to keep the text
///     literal. (tmux itself then stores `#` as `_` in those names.)
const Title = struct {
    text: []const u8,

    pub fn format(self: Title, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('\'');
        for (self.text) |c| switch (c) {
            '\'' => try writer.writeAll("'\\''"),
            '#' => try writer.writeAll("##"),
            0...0x1f, 0x7f => try writer.writeByte(' '),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('\'');
    }
};

fn newSplit(
    alloc: Allocator,
    direction: Action.SplitDirection,
    ctx: Context,
) Allocator.Error!Result {
    // `-b` puts the new pane before the target: left or above.
    const flag: []const u8 = switch (direction) {
        .right => "-h",
        .left => "-hb",
        .down => "-v",
        .up => "-vb",
        .auto => if (ctx.wider_than_tall) "-h" else "-v",
    };

    return single(alloc, "split-window {s}{f}", .{
        flag,
        PaneTarget{ .pane = ctx.pane },
    });
}

fn gotoSplit(
    alloc: Allocator,
    direction: Action.SplitFocusDirection,
    ctx: Context,
) Allocator.Error!Result {
    const flag: []const u8 = switch (direction) {
        .left => "-L",
        .right => "-R",
        .up => "-U",
        .down => "-D",

        // These are relative to the active pane of a window, not to a
        // pane we name, so make the surface's pane the active one first
        // (a no-op when it already is). `+` and `-` wrap around.
        .previous, .next => {
            const step: u8 = if (direction == .next) '+' else '-';
            var b: Builder = .{ .alloc = alloc };
            defer b.deinit();
            if (ctx.pane) |pane| try b.add("select-pane -t %{d}", .{pane});
            if (ctx.window) |window|
                try b.add("select-pane -t @{d}.{c}", .{ window, step })
            else
                try b.add("select-pane -t :.{c}", .{step});
            return b.finish();
        },
    };

    return single(alloc, "select-pane {s}{f}", .{
        flag,
        PaneTarget{ .pane = ctx.pane },
    });
}

fn resizeSplit(
    alloc: Allocator,
    direction: Action.SplitResizeDirection,
    amount: u16,
    ctx: Context,
) Allocator.Error!Result {
    // Nothing to resize by. Natively this isn't performable either.
    if (amount == 0) return .consumed;

    const flag: []const u8 = switch (direction) {
        .left => "-L",
        .right => "-R",
        .up => "-U",
        .down => "-D",
    };
    const cell: f32 = switch (direction) {
        .left, .right => ctx.cell_width,
        .up, .down => ctx.cell_height,
    };

    // The amount is in pixels but tmux counts cells, and wants the
    // adjustment last: `-t` after it is rejected as an extra argument.
    // The divider moves the way the flag says, as it does natively.
    return single(alloc, "resize-pane {s}{f} {d}", .{
        flag,
        PaneTarget{ .pane = ctx.pane },
        pixelsToCells(amount, cell),
    });
}

fn pixelsToCells(amount: u16, cell: f32) usize {
    // A cell size that isn't usable counts the amount as cells.
    const size = if (cell >= 1) cell else 1;
    const cells: usize = @intFromFloat(@round(@as(f32, @floatFromInt(amount)) / size));
    return @max(cells, 1);
}

/// The tabs of the group, which is just the window if we know of no
/// others. Null if there is no window to be a tab.
fn group(ctx: *const Context, single_tab: *[1]usize) ?[]const usize {
    const window = ctx.window orelse return null;
    if (ctx.tabs.len > 0) return ctx.tabs;
    single_tab[0] = window;
    return single_tab;
}

fn tabIndex(tabs: []const usize, window: usize) ?usize {
    return std.mem.indexOfScalar(usize, tabs, window);
}

fn closeTab(
    alloc: Allocator,
    mode: Action.CloseTabMode,
    ctx: Context,
) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse return .native;
    const window = ctx.window.?;
    const pos = tabIndex(tabs, window) orelse return .native;

    var b: Builder = .{ .alloc = alloc };
    defer b.deinit();
    switch (mode) {
        .this => try b.add("kill-window -t @{d}", .{window}),
        .other => for (tabs, 0..) |id, i| {
            if (i != pos) try b.add("kill-window -t @{d}", .{id});
        },
        .right => for (tabs[pos + 1 ..]) |id| {
            try b.add("kill-window -t @{d}", .{id});
        },
    }

    return b.finish();
}

/// A new window for the native window of `ctx`.
///
/// Tabs follow tmux's window order, and a bare `new-window` takes the
/// first free index, which after a window was killed can be in the middle
/// of the tabs or before the current one. `-a` inserts right after the
/// window we name instead, moving later windows up.
fn newTab(alloc: Allocator, ctx: Context) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse {
        // The gateway shows no tmux window, so the place is tmux's: its
        // current window, or its last one. The braces of `{end}` would
        // start a command block if they weren't quoted.
        return switch (ctx.new_tab_position) {
            .current => single(alloc, "new-window -a", .{}),
            .end => single(alloc, "new-window -a -t '{{end}}'", .{}),
        };
    };
    const after = switch (ctx.new_tab_position) {
        .current => ctx.window.?,
        .end => tabs[tabs.len - 1],
    };
    return single(alloc, "new-window -a -t @{d}", .{after});
}

fn closeWindow(alloc: Allocator, ctx: Context) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse return .native;

    var b: Builder = .{ .alloc = alloc };
    defer b.deinit();
    for (tabs) |id| try b.add("kill-window -t @{d}", .{id});
    return b.finish();
}

fn stepTab(
    alloc: Allocator,
    comptime direction: enum { next, previous },
    ctx: Context,
) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse return .native;
    const pos = tabIndex(tabs, ctx.window.?) orelse return .native;
    if (tabs.len == 1) return .consumed;

    // Wraps around, like the native tab bar.
    const target = switch (direction) {
        .next => tabs[(pos + 1) % tabs.len],
        .previous => tabs[(pos + tabs.len - 1) % tabs.len],
    };

    return single(alloc, "select-window -t @{d}", .{target});
}

fn gotoTab(alloc: Allocator, n: usize, ctx: Context) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse return .native;

    // Tabs count from 1 and a number past the end means the last tab,
    // which is what the native tab bar does.
    if (n == 0) return .consumed;
    const target = tabs[@min(n, tabs.len) - 1];
    if (target == ctx.window.?) return .consumed;

    return single(alloc, "select-window -t @{d}", .{target});
}

fn moveTab(alloc: Allocator, amount: isize, ctx: Context) Allocator.Error!Result {
    var single_tab: [1]usize = undefined;
    const tabs = group(&ctx, &single_tab) orelse return .native;
    const window = ctx.window.?;
    const pos = tabIndex(tabs, window) orelse return .native;
    if (tabs.len == 1) return .consumed;

    // Past either end the tab wraps around, like the native tab bar.
    const len: isize = @intCast(tabs.len);
    const dest: usize = @intCast(@mod(@as(isize, @intCast(pos)) + @mod(amount, len), len));

    // Swapping with the neighbor in tab order exchanges their tmux
    // indexes, which changes the order within this group without
    // touching windows of other groups that sit between them. Reaching
    // a position further away takes one swap per step, and the other
    // tabs keep their relative order, as a native reorder does.
    var b: Builder = .{ .alloc = alloc };
    defer b.deinit();
    var at = pos;
    while (at != dest) {
        const next = if (dest > at) at + 1 else at - 1;
        try b.add("swap-window -s @{d} -t @{d}", .{ window, tabs[next] });
        at = next;
    }

    // tmux makes whatever window ends up at the current index current
    // after a swap, which can be the neighbor, and `-d` doesn't reliably
    // prevent that. The moved tab is the one the user is on, so keep it
    // selected.
    if (b.list.items.len > 0) try b.add("select-window -t @{d}", .{window});
    return b.finish();
}

/// Rename a tmux window, which is what a tab title is. An empty title
/// clears the override, which for tmux means automatic naming again:
/// renaming turns that off for the window, and `rename-window` with an
/// empty name would do nothing.
fn setTabTitle(
    alloc: Allocator,
    window: usize,
    title: []const u8,
) Allocator.Error!Result {
    if (title.len == 0) return single(
        alloc,
        "set-option -w -u -t @{d} automatic-rename",
        .{window},
    );

    // `--` because a name that starts with a dash would be a flag.
    return single(
        alloc,
        "rename-window -t @{d} -- {f}",
        .{ window, Title{ .text = title } },
    );
}

/// Set the title of a tmux pane, and set the native surface title too
/// because tmux doesn't report pane titles set this way.
fn setPaneTitle(
    alloc: Allocator,
    pane: usize,
    title: []const u8,
) Allocator.Error!Result {
    var result = try single(
        alloc,
        "select-pane -T {f} -t %{d}",
        .{ Title{ .text = title }, pane },
    );
    result.commands.then_native = true;
    return result;
}

fn expectCommands(
    expected: []const u8,
    action: Action,
    ctx: Context,
) !void {
    const result = try translate(std.testing.allocator, action, ctx);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.meta.Tag(Result).commands, std.meta.activeTag(result));
    try std.testing.expectEqualStrings(expected, result.commands.data);
}

fn expectKind(
    expected: std.meta.Tag(Result),
    action: Action,
    ctx: Context,
) !void {
    const result = try translate(std.testing.allocator, action, ctx);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, std.meta.activeTag(result));
}

/// A pane in the middle of a group of three tabs.
const pane_ctx: Context = .{
    .pane = 5,
    .window = 3,
    .tabs = &.{ 1, 3, 7 },
};

test "new_split" {
    try expectCommands("split-window -h -t %5\n", .{ .new_split = .right }, pane_ctx);
    try expectCommands("split-window -hb -t %5\n", .{ .new_split = .left }, pane_ctx);
    try expectCommands("split-window -v -t %5\n", .{ .new_split = .down }, pane_ctx);
    try expectCommands("split-window -vb -t %5\n", .{ .new_split = .up }, pane_ctx);
}

test "new_split auto follows the aspect" {
    var ctx = pane_ctx;
    ctx.wider_than_tall = true;
    try expectCommands("split-window -h -t %5\n", .{ .new_split = .auto }, ctx);
    ctx.wider_than_tall = false;
    try expectCommands("split-window -v -t %5\n", .{ .new_split = .auto }, ctx);
}

test "new_split on the gateway targets the active pane" {
    try expectCommands("split-window -h\n", .{ .new_split = .right }, .{});
    try expectCommands("split-window -vb\n", .{ .new_split = .up }, .{});
}

test "new_tab and new_window record where the window goes" {
    {
        const result = try translate(std.testing.allocator, .new_tab, pane_ctx);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("new-window -a -t @3\n", result.commands.data);
        try std.testing.expectEqual(Affinity.tab, result.commands.affinity);
        try std.testing.expect(!result.commands.then_native);
    }
    {
        const result = try translate(std.testing.allocator, .new_window, pane_ctx);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("new-window\n", result.commands.data);
        try std.testing.expectEqual(Affinity.window, result.commands.affinity);
    }

    // The gateway can create windows too. Its tab goes after tmux's
    // current window, or after its last one.
    try expectCommands("new-window -a\n", .new_tab, .{});
    try expectCommands("new-window -a -t '{end}'\n", .new_tab, .{ .new_tab_position = .end });
    try expectCommands("new-window\n", .new_window, .{});
}

test "new_tab goes where window-new-tab-position says" {
    // A bare new-window would fill the first free index, which can be
    // before the current tab.
    try expectCommands("new-window -a -t @3\n", .new_tab, pane_ctx);

    var end = pane_ctx;
    end.new_tab_position = .end;
    try expectCommands("new-window -a -t @7\n", .new_tab, end);

    // The last tab is the current one for both positions.
    end.window = 7;
    try expectCommands("new-window -a -t @7\n", .new_tab, end);

    // Without group information the window itself is the last tab.
    var ungrouped = pane_ctx;
    ungrouped.tabs = &.{};
    ungrouped.new_tab_position = .end;
    try expectCommands("new-window -a -t @3\n", .new_tab, ungrouped);
}

test "close_surface kills the pane" {
    try expectCommands("kill-pane -t %5\n", .close_surface, pane_ctx);

    // Closing the gateway leaves control mode, which isn't ours to
    // translate.
    try expectKind(.native, .close_surface, .{});
}

test "close_tab" {
    try expectCommands("kill-window -t @3\n", .{ .close_tab = .this }, pane_ctx);
    try expectCommands(
        "kill-window -t @1\nkill-window -t @7\n",
        .{ .close_tab = .other },
        pane_ctx,
    );
    try expectCommands("kill-window -t @7\n", .{ .close_tab = .right }, pane_ctx);
}

test "close_tab edge cases" {
    // Nothing right of the last tab, nothing else in a lone tab.
    var last = pane_ctx;
    last.window = 7;
    try expectKind(.consumed, .{ .close_tab = .right }, last);

    var lone = pane_ctx;
    lone.tabs = &.{3};
    try expectKind(.consumed, .{ .close_tab = .other }, lone);
    try expectCommands("kill-window -t @3\n", .{ .close_tab = .this }, lone);

    // No group information still lets the current window close.
    var ungrouped = pane_ctx;
    ungrouped.tabs = &.{};
    try expectCommands("kill-window -t @3\n", .{ .close_tab = .this }, ungrouped);

    // The gateway shows no tmux window.
    try expectKind(.native, .{ .close_tab = .this }, .{});
    try expectKind(.native, .{ .close_tab = .other }, .{});
}

test "close_window kills every window of the group" {
    try expectCommands(
        "kill-window -t @1\nkill-window -t @3\nkill-window -t @7\n",
        .close_window,
        pane_ctx,
    );

    var ungrouped = pane_ctx;
    ungrouped.tabs = &.{};
    try expectCommands("kill-window -t @3\n", .close_window, ungrouped);

    try expectKind(.native, .close_window, .{});
}

test "closing stays native when it may need confirmation" {
    // The apprt's own close asks first and then kills the pane or window
    // through its native close events.
    var confirm = pane_ctx;
    confirm.confirm_close = true;
    try expectKind(.native, .close_surface, confirm);
    try expectKind(.native, .{ .close_tab = .this }, confirm);
    try expectKind(.native, .{ .close_tab = .other }, confirm);
    try expectKind(.native, .close_window, confirm);
}

test "close_all_windows and quit detach" {
    {
        const result = try translate(std.testing.allocator, .close_all_windows, pane_ctx);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.detach.then_native);
    }
    {
        const result = try translate(std.testing.allocator, .quit, pane_ctx);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.detach.then_native);
    }

    // The gateway detaches too.
    try expectKind(.detach, .quit, .{});
    try expectKind(.detach, .close_all_windows, .{});
}

test "goto_split by direction" {
    try expectCommands("select-pane -L -t %5\n", .{ .goto_split = .left }, pane_ctx);
    try expectCommands("select-pane -R -t %5\n", .{ .goto_split = .right }, pane_ctx);
    try expectCommands("select-pane -U -t %5\n", .{ .goto_split = .up }, pane_ctx);
    try expectCommands("select-pane -D -t %5\n", .{ .goto_split = .down }, pane_ctx);
    try expectCommands("select-pane -L\n", .{ .goto_split = .left }, .{});
}

test "goto_split previous and next are relative to the window" {
    try expectCommands(
        "select-pane -t %5\nselect-pane -t @3.+\n",
        .{ .goto_split = .next },
        pane_ctx,
    );
    try expectCommands(
        "select-pane -t %5\nselect-pane -t @3.-\n",
        .{ .goto_split = .previous },
        pane_ctx,
    );

    // The gateway has only tmux's current window to go by.
    try expectCommands("select-pane -t :.+\n", .{ .goto_split = .next }, .{});
    try expectCommands("select-pane -t :.-\n", .{ .goto_split = .previous }, .{});
}

test "resize_split converts pixels to cells" {
    var ctx = pane_ctx;
    ctx.cell_width = 10;
    ctx.cell_height = 20;

    // The adjustment comes last, after the target.
    try expectCommands("resize-pane -R -t %5 5\n", .{ .resize_split = .{ .right, 50 } }, ctx);
    try expectCommands("resize-pane -L -t %5 5\n", .{ .resize_split = .{ .left, 50 } }, ctx);
    try expectCommands("resize-pane -D -t %5 2\n", .{ .resize_split = .{ .down, 40 } }, ctx);
    try expectCommands("resize-pane -U -t %5 3\n", .{ .resize_split = .{ .up, 60 } }, ctx);
}

test "resize_split rounds and never resizes by zero cells" {
    var ctx = pane_ctx;
    ctx.cell_width = 10;
    ctx.cell_height = 20;

    try expectCommands("resize-pane -R -t %5 1\n", .{ .resize_split = .{ .right, 3 } }, ctx);
    try expectCommands("resize-pane -R -t %5 2\n", .{ .resize_split = .{ .right, 15 } }, ctx);
    try expectCommands("resize-pane -R -t %5 1\n", .{ .resize_split = .{ .right, 14 } }, ctx);

    // Zero is not a resize at all.
    try expectKind(.consumed, .{ .resize_split = .{ .right, 0 } }, ctx);

    // A cell size we don't have counts the amount as cells.
    ctx.cell_width = 0;
    try expectCommands("resize-pane -R -t %5 7\n", .{ .resize_split = .{ .right, 7 } }, ctx);

    // The gateway has no pane to name.
    ctx = .{ .cell_width = 10, .cell_height = 10 };
    try expectCommands("resize-pane -D 4\n", .{ .resize_split = .{ .down, 40 } }, ctx);
}

test "equalize_splits and toggle_split_zoom" {
    try expectCommands("select-layout -E -t %5\n", .equalize_splits, pane_ctx);
    try expectCommands("resize-pane -Z -t %5\n", .toggle_split_zoom, pane_ctx);
    try expectCommands("select-layout -E\n", .equalize_splits, .{});
    try expectCommands("resize-pane -Z\n", .toggle_split_zoom, .{});
}

test "next_tab and previous_tab follow the group order" {
    try expectCommands("select-window -t @7\n", .next_tab, pane_ctx);
    try expectCommands("select-window -t @1\n", .previous_tab, pane_ctx);
}

test "next_tab and previous_tab wrap" {
    var last = pane_ctx;
    last.window = 7;
    try expectCommands("select-window -t @1\n", .next_tab, last);

    var first = pane_ctx;
    first.window = 1;
    try expectCommands("select-window -t @7\n", .previous_tab, first);
}

test "tab navigation with one tab does nothing" {
    var lone = pane_ctx;
    lone.tabs = &.{3};
    try expectKind(.consumed, .next_tab, lone);
    try expectKind(.consumed, .previous_tab, lone);

    var ungrouped = pane_ctx;
    ungrouped.tabs = &.{};
    try expectKind(.consumed, .next_tab, ungrouped);

    try expectKind(.native, .next_tab, .{});
    try expectKind(.native, .previous_tab, .{});
}

test "last_tab selects the rightmost tab" {
    try expectCommands("select-window -t @7\n", .last_tab, pane_ctx);

    var rightmost = pane_ctx;
    rightmost.window = 7;
    try expectKind(.consumed, .last_tab, rightmost);

    try expectKind(.native, .last_tab, .{});
}

test "goto_tab counts from one" {
    try expectCommands("select-window -t @1\n", .{ .goto_tab = 1 }, pane_ctx);
    try expectCommands("select-window -t @7\n", .{ .goto_tab = 3 }, pane_ctx);
}

test "goto_tab past the end selects the last tab" {
    try expectCommands("select-window -t @7\n", .{ .goto_tab = 4 }, pane_ctx);
    try expectCommands("select-window -t @7\n", .{ .goto_tab = 1000 }, pane_ctx);
}

test "goto_tab with nothing to do" {
    // The current tab, and tab zero which doesn't exist.
    try expectKind(.consumed, .{ .goto_tab = 2 }, pane_ctx);
    try expectKind(.consumed, .{ .goto_tab = 0 }, pane_ctx);
    try expectKind(.native, .{ .goto_tab = 1 }, .{});
}

test "move_tab by one swaps with the neighbor" {
    try expectCommands(
        "swap-window -s @3 -t @7\nselect-window -t @3\n",
        .{ .move_tab = 1 },
        pane_ctx,
    );
    try expectCommands(
        "swap-window -s @3 -t @1\nselect-window -t @3\n",
        .{ .move_tab = -1 },
        pane_ctx,
    );
}

test "move_tab wraps around the group" {
    // Forwards from the last tab lands on the first, which takes a swap
    // for every tab it passes.
    var last = pane_ctx;
    last.window = 7;
    try expectCommands(
        "swap-window -s @7 -t @3\nswap-window -s @7 -t @1\nselect-window -t @7\n",
        .{ .move_tab = 1 },
        last,
    );

    // Backwards from the first tab lands on the last.
    var first = pane_ctx;
    first.window = 1;
    try expectCommands(
        "swap-window -s @1 -t @3\nswap-window -s @1 -t @7\nselect-window -t @1\n",
        .{ .move_tab = -1 },
        first,
    );
}

test "move_tab by several steps passes every tab on the way" {
    var first = pane_ctx;
    first.window = 1;
    first.tabs = &.{ 1, 3, 7, 9 };
    try expectCommands(
        "swap-window -s @1 -t @3\nswap-window -s @1 -t @7\nswap-window -s @1 -t @9\n" ++
            "select-window -t @1\n",
        .{ .move_tab = 3 },
        first,
    );

    // More than a lap is the same as the remainder.
    try expectCommands(
        "swap-window -s @1 -t @3\nselect-window -t @1\n",
        .{ .move_tab = 5 },
        first,
    );
}

test "move_tab with nowhere to go" {
    // A whole lap, and a lone tab.
    try expectKind(.consumed, .{ .move_tab = 3 }, pane_ctx);
    try expectKind(.consumed, .{ .move_tab = 0 }, pane_ctx);

    var lone = pane_ctx;
    lone.tabs = &.{3};
    try expectKind(.consumed, .{ .move_tab = 1 }, lone);

    try expectKind(.native, .{ .move_tab = 1 }, .{});
}

test "move_tab_to_new_window regroups without a command" {
    const result = try translate(std.testing.allocator, .move_tab_to_new_window, pane_ctx);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.regroup_tab);

    var lone = pane_ctx;
    lone.tabs = &.{3};
    try expectKind(.native, .move_tab_to_new_window, lone);
    try expectKind(.native, .move_tab_to_new_window, .{});
}

test "set_tab_title renames the window" {
    try expectCommands(
        "rename-window -t @3 -- 'build logs'\n",
        .{ .set_tab_title = "build logs" },
        pane_ctx,
    );
    try expectKind(.native, .{ .set_tab_title = "x" }, .{});

    // Renaming doesn't also set the title natively: the rename comes
    // back from tmux and that is what updates the tab.
    const result = try translate(
        std.testing.allocator,
        .{ .set_tab_title = "x" },
        pane_ctx,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.commands.then_native);
}

test "an empty tab title goes back to automatic naming" {
    try expectCommands(
        "set-option -w -u -t @3 automatic-rename\n",
        .{ .set_tab_title = "" },
        pane_ctx,
    );
}

test "set_surface_title sets the pane title and the native one" {
    const result = try translate(
        std.testing.allocator,
        .{ .set_surface_title = "editor" },
        pane_ctx,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "select-pane -T 'editor' -t %5\n",
        result.commands.data,
    );
    try std.testing.expect(result.commands.then_native);

    try expectKind(.native, .{ .set_surface_title = "x" }, .{});
}

test "title prompts name what to retitle" {
    const tab = try translate(std.testing.allocator, .prompt_tab_title, pane_ctx);
    defer tab.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), tab.prompt_tab_title);

    const surface = try translate(std.testing.allocator, .prompt_surface_title, pane_ctx);
    defer surface.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), surface.prompt_surface_title);

    try expectKind(.native, .prompt_tab_title, .{});
    try expectKind(.native, .prompt_surface_title, .{});
}

test "titles are quoted for the tmux command parser" {
    // A quote closes the string, is escaped, and reopens it.
    try expectCommands(
        "rename-window -t @3 -- 'it'\\''s'\n",
        .{ .set_tab_title = "it's" },
        pane_ctx,
    );
    try expectCommands(
        "rename-window -t @3 -- ''\\'''\n",
        .{ .set_tab_title = "'" },
        pane_ctx,
    );

    // Everything else is literal inside single quotes, including what
    // would end the command or expand.
    try expectCommands(
        "rename-window -t @3 -- 'a;b $HOME ~ \"q\" \\ {x}'\n",
        .{ .set_tab_title = "a;b $HOME ~ \"q\" \\ {x}" },
        pane_ctx,
    );
    try expectCommands(
        "select-pane -T 'héllo ✓' -t %5\n",
        .{ .set_surface_title = "héllo ✓" },
        pane_ctx,
    );
}

test "titles can't expand tmux formats" {
    try expectCommands(
        "rename-window -t @3 -- '##{window_index} ##(date)'\n",
        .{ .set_tab_title = "#{window_index} #(date)" },
        pane_ctx,
    );
    try expectCommands(
        "select-pane -T '##{pane_id}' -t %5\n",
        .{ .set_surface_title = "#{pane_id}" },
        pane_ctx,
    );
}

test "titles can't end the command line" {
    try expectCommands(
        "rename-window -t @3 -- 'a b c d'\n",
        .{ .set_tab_title = "a\nb\rc\x00d" },
        pane_ctx,
    );
}

test "a title that looks like a flag is an argument" {
    try expectCommands(
        "rename-window -t @3 -- '-x'\n",
        .{ .set_tab_title = "-x" },
        pane_ctx,
    );
    try expectCommands(
        "select-pane -T '-x' -t %5\n",
        .{ .set_surface_title = "-x" },
        pane_ctx,
    );
}

test "clear_screen clears tmux history and the view" {
    const result = try translate(std.testing.allocator, .clear_screen, pane_ctx);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("clear-history -t %5\n", result.commands.data);
    try std.testing.expect(result.commands.then_native);

    // The gateway only has its own plate to clear.
    try expectKind(.native, .clear_screen, .{});
}

test "reset resets the tmux pane and the view" {
    const result = try translate(std.testing.allocator, .reset, pane_ctx);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "send-keys -R -t %5\nclear-history -t %5\n",
        result.commands.data,
    );
    try std.testing.expect(result.commands.then_native);

    // The gateway's plate isn't a tmux pane.
    try expectKind(.native, .reset, .{});
}

test "actions without a tmux meaning stay native" {
    const native_actions = [_]Action{
        .ignore,
        .unbind,
        .{ .csi = "0m" },
        .{ .esc = "x" },
        .{ .text = "x" },
        .paste_from_clipboard,
        .{ .increase_font_size = 1 },
        .{ .search = "x" },
        .select_all,
        .scroll_to_top,
        .{ .scroll_page_lines = 3 },
        .{ .goto_window = .next },
        .toggle_tab_overview,
        .prompt_window_title,
        .{ .set_window_title = "x" },
        .toggle_fullscreen,
        .toggle_command_palette,
        .{ .inspector = .toggle },
        .reload_config,
        .toggle_readonly,
        .undo,
        .redo,
        .{ .activate_key_table = "x" },
        .end_key_sequence,
    };

    for (native_actions) |action| {
        try expectKind(.native, action, pane_ctx);
        try expectKind(.native, action, .{});
    }
}

test "every action has a classification" {
    // The switch in `translate` has no `else`, so this can't fail to
    // compile for a new action without a decision, but it also has to
    // not misbehave for any of them at runtime: a result must be
    // produced and freed cleanly for every tag, with and without a pane.
    inline for (@typeInfo(Action).@"union".field_names) |name| {
        const action = comptime sample(name);
        for ([_]Context{ pane_ctx, .{} }) |ctx| {
            const result = try translate(std.testing.allocator, action, ctx);
            result.deinit(std.testing.allocator);
        }
    }
}

/// An action with the given tag and an arbitrary payload.
fn sample(comptime name: []const u8) Action {
    const T = @FieldType(Action, name);
    const value: T = switch (@typeInfo(T)) {
        .void => {},
        .pointer => "x",
        .int => 1,
        .float => 1,
        .@"enum" => @field(T, @typeInfo(T).@"enum".field_names[0]),
        .@"struct" => switch (T) {
            Action.SplitResizeParameter => .{ .up, 1 },
            Action.WriteScreen => .copy,
            Action.CursorKey => .{ .normal = "x", .application = "x" },
            else => @compileError("no sample for " ++ name),
        },
        else => @compileError("no sample for " ++ name),
    };
    return @unionInit(Action, name, value);
}

test "lines splits commands one at a time" {
    const result = try translate(std.testing.allocator, .close_window, pane_ctx);
    defer result.deinit(std.testing.allocator);

    var it = result.commands.lines();
    try std.testing.expectEqualStrings("kill-window -t @1\n", it.next().?);
    try std.testing.expectEqualStrings("kill-window -t @3\n", it.next().?);
    try std.testing.expectEqualStrings("kill-window -t @7\n", it.next().?);
    try std.testing.expect(it.next() == null);
}
