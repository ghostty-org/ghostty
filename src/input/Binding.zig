//! A binding maps some input trigger to an action. When the trigger
//! occurs, the action is performed.
const Binding = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const build_config = @import("../build_config.zig");
const uucode = @import("uucode");
const EntryFormatter = @import("../config/formatter.zig").EntryFormatter;
const deepEqual = @import("../datastruct/comparison.zig").deepEqual;
const key = @import("key.zig");
const key_mods = @import("key_mods.zig");
const KeyEvent = key.KeyEvent;

/// The trigger that needs to be performed to execute the action.
trigger: Trigger,

/// The action to take if this binding matches
action: Action,

/// Boolean flags that can be set per binding.
flags: Flags = .{},

pub const Error = error{
    InvalidFormat,
    InvalidAction,
};

/// Flags the full binding-scoped flags that can be set per binding.
pub const Flags = packed struct {
    /// True if this binding should consume the input when the
    /// action is triggered.
    consumed: bool = true,

    /// True if this binding should be forwarded to all active surfaces
    /// in the application.
    all: bool = false,

    /// True if this binding is global. Global bindings should work system-wide
    /// and not just while Ghostty is focused. This may not work on all platforms.
    /// See the keybind config documentation for more information.
    global: bool = false,

    /// True if this binding should only be triggered if the action can be
    /// performed. If the action can't be performed then the binding acts as
    /// if it doesn't exist.
    performable: bool = false,

    /// C type
    pub const C = u8;

    /// Converts this to a C-compatible value.
    ///
    /// Sync with ghostty.h for enums.
    pub fn cval(self: Flags) C {
        const Backing = @typeInfo(Flags).@"struct".backing_integer.?;
        return @as(Backing, @bitCast(self));
    }

    test "cval" {
        const testing = std.testing;
        try testing.expectEqual(@as(u8, 0b0001), (Flags{}).cval());
        try testing.expectEqual(@as(u8, 0b0000), (Flags{ .consumed = false }).cval());
        try testing.expectEqual(@as(u8, 0b0011), (Flags{ .all = true }).cval());
        try testing.expectEqual(@as(u8, 0b0101), (Flags{ .global = true }).cval());
        try testing.expectEqual(@as(u8, 0b1001), (Flags{ .performable = true }).cval());
        try testing.expectEqual(@as(u8, 0b1111), (Flags{ .consumed = true, .all = true, .global = true, .performable = true }).cval());
    }
};

/// Full binding parser. The binding parser is implemented as an iterator
/// which yields elements to support multi-key sequences without allocation.
pub const Parser = struct {
    trigger_it: SequenceIterator,
    action: Action,
    flags: Flags = .{},
    chain: bool,

    pub const Elem = union(enum) {
        /// A leader trigger in a sequence.
        leader: Trigger,

        /// The final trigger and action in a sequence.
        binding: Binding,

        /// A chained action `chain=<action>` that should be appended
        /// to the previous binding. Note that any action is parsed, including
        /// invalid actions for chains such as `unbind`. We expect downstream
        /// consumers to validate that the action is valid for chaining.
        chain: Action,
    };

    pub fn init(raw_input: []const u8) Error!Parser {
        const flags, const start_idx = try parseFlags(raw_input);
        const input = raw_input[start_idx..];

        // Find the equal sign. This is more complicated than it seems on
        // the surface because we need to ignore equal signs that are
        // part of the trigger.
        const eql_idx: usize = eql: {
            // TODO: We should change this parser into a real state machine
            // based parser that parses the trigger fully, then yields the
            // action after. The loop below is a total mess.
            var offset: usize = 0;
            while (std.mem.indexOfScalar(
                u8,
                input[offset..],
                '=',
            )) |offset_idx| {
                // Find: '=+ctrl' or '==action'
                const idx = offset + offset_idx;
                if (idx < input.len - 1 and
                    (input[idx + 1] == '+' or
                        input[idx + 1] == '='))
                {
                    offset += offset_idx + 1;
                    continue;
                }

                // Looks like the real equal sign.
                break :eql idx;
            }

            return Error.InvalidFormat;
        };

        // Detect chains. Chains must not have flags.
        const chain = std.mem.eql(u8, input[0..eql_idx], "chain");
        if (chain and start_idx > 0) return Error.InvalidFormat;

        // Sequence iterator goes up to the equal, action is after. We can
        // parse the action now.
        return .{
            .trigger_it = .{
                // This is kind of hacky but we put a dummy trigger
                // for chained inputs. The `next` will never yield this
                // because we have chain set. When we find a nicer way to
                // do this we can remove it, the e2e is tested.
                .input = if (chain) "a" else input[0..eql_idx],
            },
            .action = try .parse(input[eql_idx + 1 ..]),
            .flags = flags,
            .chain = chain,
        };
    }

    fn parseFlags(raw_input: []const u8) Error!struct { Flags, usize } {
        var flags: Flags = .{};

        var start_idx: usize = 0;
        var input: []const u8 = raw_input;
        while (true) {
            // Find the next prefix
            const idx = std.mem.indexOf(u8, input, ":") orelse break;
            const prefix = input[0..idx];

            // If the prefix is one of our flags then set it.
            if (std.mem.eql(u8, prefix, "all")) {
                if (flags.all) return Error.InvalidFormat;
                flags.all = true;
            } else if (std.mem.eql(u8, prefix, "global")) {
                if (flags.global) return Error.InvalidFormat;
                flags.global = true;
            } else if (std.mem.eql(u8, prefix, "unconsumed")) {
                if (!flags.consumed) return Error.InvalidFormat;
                flags.consumed = false;
            } else if (std.mem.eql(u8, prefix, "performable")) {
                if (flags.performable) return Error.InvalidFormat;
                flags.performable = true;
            } else {
                // If we don't recognize the prefix then we're done. We
                // let any unknown prefix fallthrough to trigger-specific
                // parsing in case there are trigger-specific prefixes
                // (none currently but historically there was `physical:`
                // at one point). Breaking here lets us always implement new
                // prefixes.
                break;
            }

            // Move past the prefix
            start_idx += idx + 1;
            input = input[idx + 1 ..];
        }

        return .{ flags, start_idx };
    }

    pub fn next(self: *Parser) Error!?Elem {
        // Get our trigger. If we're out of triggers then we're done.
        const trigger = (try self.trigger_it.next()) orelse return null;

        // If this is our last trigger then it is our final binding.
        if (!self.trigger_it.done()) {
            // Global/all bindings can't be sequences
            if (self.flags.global or self.flags.all) return error.InvalidFormat;
            return .{ .leader = trigger };
        }

        // If we're a chain then return it as-is.
        if (self.chain) return .{ .chain = self.action };

        // Out of triggers, yield the final action.
        return .{ .binding = .{
            .trigger = trigger,
            .action = self.action,
            .flags = self.flags,
        } };
    }

    pub fn reset(self: *Parser) void {
        self.trigger_it.i = 0;
    }
};

/// An iterator that yields each trigger in a sequence of triggers. For
/// example, the sequence "ctrl+a>ctrl+b" would yield "ctrl+a" and then
/// "ctrl+b". The iterator approach allows us to parse a sequence of
/// triggers without allocations.
const SequenceIterator = struct {
    /// The input of triggers. This is expected to be ONLY triggers. Things
    /// like the "unconsumed:" prefix or action must be stripped before
    /// passing to this iterator.
    input: []const u8,
    i: usize = 0,

    /// Returns the next trigger in the sequence if there is no parsing error.
    pub fn next(self: *SequenceIterator) Error!?Trigger {
        if (self.done()) return null;
        const rem = self.input[self.i..];
        const idx = std.mem.indexOf(u8, rem, ">") orelse rem.len;
        defer self.i += idx + 1;
        return try .parse(rem[0..idx]);
    }

    /// Returns true if there are no more triggers to parse.
    pub fn done(self: *const SequenceIterator) bool {
        return self.i > self.input.len;
    }
};

/// Parse a single, non-sequenced binding. To support sequences you must
/// use parse. This is a convenience function for single bindings aimed
/// primarily at tests.
///
/// This doesn't support `chain` either, since chaining requires some
/// stateful concept of a prior binding.
fn parseSingle(raw_input: []const u8) (Error || error{
    UnexpectedChain,
    UnexpectedSequence,
})!Binding {
    var p = try Parser.init(raw_input);
    const elem = (try p.next()) orelse return Error.InvalidFormat;
    return switch (elem) {
        .leader => error.UnexpectedSequence,
        .binding => elem.binding,
        .chain => error.UnexpectedChain,
    };
}

/// Returns true if lhs should be sorted before rhs
pub fn lessThan(_: void, lhs: Binding, rhs: Binding) bool {
    const lhs_count: usize = blk: {
        var count: usize = 0;
        if (lhs.trigger.mods.super) count += 1;
        if (lhs.trigger.mods.ctrl) count += 1;
        if (lhs.trigger.mods.shift) count += 1;
        if (lhs.trigger.mods.alt) count += 1;
        break :blk count;
    };
    const rhs_count: usize = blk: {
        var count: usize = 0;
        if (rhs.trigger.mods.super) count += 1;
        if (rhs.trigger.mods.ctrl) count += 1;
        if (rhs.trigger.mods.shift) count += 1;
        if (rhs.trigger.mods.alt) count += 1;
        break :blk count;
    };

    if (lhs_count != rhs_count)
        return lhs_count > rhs_count;

    if (lhs.trigger.mods.int() != rhs.trigger.mods.int())
        return lhs.trigger.mods.int() > rhs.trigger.mods.int();

    const lhs_key: c_int = blk: {
        switch (lhs.trigger.key) {
            .physical => break :blk @intFromEnum(lhs.trigger.key.physical),
            .unicode => break :blk @intCast(lhs.trigger.key.unicode),
        }
    };
    const rhs_key: c_int = blk: {
        switch (rhs.trigger.key) {
            .physical => break :blk @intFromEnum(rhs.trigger.key.physical),
            .unicode => break :blk @intCast(rhs.trigger.key.unicode),
        }
    };

    return lhs_key < rhs_key;
}

/// The set of actions that a keybinding can take.
pub const Action = union(enum) {
    /// Ignore this key combination.
    ///
    /// Ghostty will not process this combination nor forward it to the child
    /// process within the terminal, but it may still be processed by the OS or
    /// other applications.
    ignore,

    /// Unbind a previously bound key binding.
    ///
    /// This cannot unbind bindings that were not bound by Ghostty or the user
    /// (e.g. bindings set by the OS or some other application).
    unbind,

    /// Send a CSI sequence.
    ///
    /// The value should be the CSI sequence without the CSI header (`ESC [` or
    /// `\x1b[`).
    ///
    /// For example, `csi:0m` can be sent to reset all styles of the current text.
    csi: []const u8,

    /// Send an `ESC` sequence.
    esc: []const u8,

    /// Send the specified text.
    ///
    /// Uses Zig string literal syntax. This is currently not validated.
    /// If the text is invalid (i.e. contains an invalid escape sequence),
    /// the error will currently only show up in logs.
    text: []const u8,

    /// Send data to the pty depending on whether cursor key mode is enabled
    /// (`application`) or disabled (`normal`).
    cursor_key: CursorKey,

    /// Reset the terminal.
    ///
    /// This can fix a lot of issues when a running program puts the terminal
    /// into a broken state, equivalent to running the `reset` command.
    ///
    /// If you do this while in a TUI program such as vim, this may break
    /// the program. If you do this while in a shell, you may have to press
    /// enter after to get a new prompt.
    reset,

    /// Copy the selected text to the clipboard.
    copy_to_clipboard: CopyToClipboard,

    /// Paste the contents of the default clipboard.
    paste_from_clipboard,

    /// Paste the contents of the selection clipboard.
    paste_from_selection,

    /// If there is a URL under the cursor, copy it to the default clipboard.
    copy_url_to_clipboard,

    /// Copy the terminal title to the clipboard. If the terminal title is not
    /// set or is empty this has no effect.
    copy_title_to_clipboard,

    /// Increase the font size by the specified amount in points (pt).
    ///
    /// For example, `increase_font_size:1.5` will increase the font size
    /// by 1.5 points.
    increase_font_size: f32,

    /// Decrease the font size by the specified amount in points (pt).
    ///
    /// For example, `decrease_font_size:1.5` will decrease the font size
    /// by 1.5 points.
    decrease_font_size: f32,

    /// Reset the font size to the original configured size.
    reset_font_size,

    /// Set the font size to the specified size in points (pt).
    ///
    /// For example, `set_font_size:14.5` will set the font size
    /// to 14.5 points.
    set_font_size: f32,

    /// Start a search for the given text. If the text is empty, then
    /// the search is canceled. A canceled search will not disable any GUI
    /// elements showing search. For that, the explicit end_search binding
    /// should be used.
    ///
    /// If a previous search is active, it is replaced.
    search: []const u8,

    /// Start a search for the current text selection. If there is no
    /// selection, this does nothing. If a search is already active, this
    /// changes the search terms.
    search_selection,

    /// Navigate the search results. If there is no active search, this
    /// is not performed.
    navigate_search: NavigateSearch,

    /// Start a search if it isn't started already. This doesn't set any
    /// search terms, but opens the UI for searching.
    start_search,

    /// End the current search if any and hide any GUI elements.
    end_search,

    /// Clear the screen and all scrollback.
    clear_screen,

    /// Select all text on the screen.
    select_all,

    /// Scroll to the top of the screen.
    scroll_to_top,

    /// Scroll to the bottom of the screen.
    scroll_to_bottom,

    /// Scroll to the selected text.
    scroll_to_selection,

    /// Scroll to the given absolute row in the screen with 0 being
    /// the first row.
    scroll_to_row: usize,

    /// Scroll the screen up by one page.
    scroll_page_up,

    /// Scroll the screen down by one page.
    scroll_page_down,

    /// Scroll the screen by the specified fraction of a page.
    ///
    /// Positive values scroll downwards, and negative values scroll upwards.
    ///
    /// For example, `scroll_page_fractional:0.5` would scroll the screen
    /// downwards by half a page, while `scroll_page_fractional:-1.5` would
    /// scroll it upwards by one and a half pages.
    scroll_page_fractional: f32,

    /// Scroll the screen by the specified amount of lines.
    ///
    /// Positive values scroll downwards, and negative values scroll upwards.
    ///
    /// For example, `scroll_page_lines:3` would scroll the screen downwards
    /// by 3 lines, while `scroll_page_lines:-10` would scroll it upwards by 10
    /// lines.
    scroll_page_lines: i16,

    /// Adjust the current selection in the given direction or position,
    /// relative to the cursor.
    ///
    /// WARNING: This does not create a new selection, and does nothing when
    /// there currently isn't one.
    ///
    /// Valid arguments are:
    ///
    ///   - `left`, `right`
    ///
    ///     Adjust the selection one cell to the left or right respectively.
    ///
    ///   - `up`, `down`
    ///
    ///     Adjust the selection one line upwards or downwards respectively.
    ///
    ///   - `page_up`, `page_down`
    ///
    ///     Adjust the selection one page upwards or downwards respectively.
    ///
    ///   - `home`, `end`
    ///
    ///     Adjust the selection to the top-left or the bottom-right corner
    ///     of the screen respectively.
    ///
    ///   - `beginning_of_line`, `end_of_line`
    ///
    ///     Adjust the selection to the beginning or the end of the line
    ///     respectively.
    ///
    adjust_selection: AdjustSelection,

    /// Jump the viewport forward or back by the given number of prompts.
    ///
    /// Requires shell integration.
    ///
    /// Positive values scroll downwards, and negative values scroll upwards.
    jump_to_prompt: i16,

    /// Write the entire scrollback into a temporary file with the specified
    /// action. The action determines what to do with the filepath.
    ///
    /// Valid actions are:
    ///
    ///   - `copy`
    ///
    ///     Copy the file path into the clipboard.
    ///
    ///   - `paste`
    ///
    ///     Paste the file path into the terminal.
    ///
    ///   - `open`
    ///
    ///     Open the file in the default OS editor for text files.
    ///
    ///     The default OS editor is determined by using `open` on macOS
    ///     and `xdg-open` on Linux.
    ///
    write_scrollback_file: WriteScreen,

    /// Write the contents of the screen into a temporary file with the
    /// specified action.
    ///
    /// See `write_scrollback_file` for possible actions.
    write_screen_file: WriteScreen,

    /// Write the currently selected text into a temporary file with the
    /// specified action.
    ///
    /// See `write_scrollback_file` for possible actions.
    ///
    /// Does nothing when no text is selected.
    write_selection_file: WriteScreen,

    /// Open a new window.
    ///
    /// If the application isn't currently focused,
    /// this will bring it to the front.
    new_window,

    /// Open a new tab.
    new_tab,

    /// Go to the previous tab.
    previous_tab,

    /// Go to the next tab.
    next_tab,

    /// Go to the last tab.
    last_tab,

    /// Go to the tab with the specific index, starting from 1.
    ///
    /// If the tab number is higher than the number of tabs,
    /// this will go to the last tab.
    goto_tab: usize,

    /// Moves a tab by a relative offset.
    ///
    /// Positive values move the tab forwards, and negative values move it
    /// backwards. If the new position is out of bounds, it is wrapped around
    /// cyclically within the tab list.
    ///
    /// For example, `move_tab:1` moves the tab one position forwards, and if
    /// it was already the last tab in the list, it wraps around and becomes
    /// the first tab in the list. Likewise, `move_tab:-1` moves the tab one
    /// position backwards, and if it was the first tab, then it will become
    /// the last tab.
    move_tab: isize,

    /// Toggle the tab overview.
    ///
    /// This is only supported on Linux and when the system's libadwaita
    /// version is 1.4 or newer. The current libadwaita version can be
    /// found by running `ghostty +version`.
    toggle_tab_overview,

    /// Change the title of the current focused surface via a pop-up prompt.
    prompt_surface_title,

    /// Change the title of the current tab via a pop-up prompt. The
    /// title set via this prompt overrides any title set by the terminal
    /// and persists across focus changes within the tab.
    prompt_tab_title,

    /// Change the title of the current window via a pop-up prompt. The
    /// title set via this prompt overrides any title set by the terminal
    /// and persists across focus changes within the tab.
    prompt_window_title,

    /// Create a new split in the specified direction.
    ///
    /// Valid arguments:
    ///
    ///   - `right`, `down`, `left`, `up`
    ///
    ///     Creates a new split in the corresponding direction.
    ///
    ///   - `auto`
    ///
    ///     Creates a new split along the larger direction.
    ///     For example, if the parent split is currently wider than it is tall,
    ///     then a left-right split would be created, and vice versa.
    ///
    new_split: SplitDirection,

    /// Focus on a split either in the specified direction (`right`, `down`,
    /// `left` and `up`), or in the adjacent split in the order of creation
    /// (`previous` and `next`).
    goto_split: SplitFocusDirection,

    /// Focus on either the previous window or the next one ('previous', 'next')
    goto_window: GotoWindow,

    /// Zoom in or out of the current split.
    ///
    /// When a split is zoomed into, it will take up the entire space in
    /// the current tab, hiding other splits. The tab or tab bar would also
    /// reflect this by displaying an icon indicating the zoomed state.
    toggle_split_zoom,

    /// Toggle read-only mode for the current surface.
    ///
    /// When a surface is in read-only mode:
    ///   - No input is sent to the PTY (mouse events, key encoding)
    ///   - Input can still be used at the terminal level to make selections,
    ///     copy/paste (keybinds), scroll, etc.
    ///   - Warn before quit is always enabled in this state even if an active
    ///     process is not running
    toggle_readonly,

    /// Resize the current split in the specified direction and amount in
    /// pixels. The two arguments should be joined with a comma (`,`),
    /// like in `resize_split:up,10`.
    resize_split: SplitResizeParameter,

    /// Equalize the size of all splits in the current window.
    equalize_splits,

    /// Reset the window to the default size. The "default size" is the
    /// size that a new window would be created with. This has no effect
    /// if the window is fullscreen.
    ///
    /// Only implemented on macOS.
    reset_window_size,

    /// Control the visibility of the terminal inspector.
    ///
    /// Valid arguments: `toggle`, `show`, `hide`.
    inspector: InspectorMode,

    /// Show the GTK inspector.
    ///
    /// Has no effect on macOS.
    show_gtk_inspector,

    /// Show the on-screen keyboard if one is present.
    ///
    /// Only implemented on Linux (GTK). On GNOME, the "Screen Keyboard"
    /// accessibility feature must be turned on, which can be found under
    /// Settings > Accessibility > Typing. Other platforms are as of now
    /// untested.
    show_on_screen_keyboard,

    /// Open the configuration file in the default OS editor.
    ///
    /// If your default OS editor isn't configured then this will fail.
    /// Currently, any failures to open the configuration will show up only in
    /// the logs.
    open_config,

    /// Reload the configuration.
    ///
    /// The exact meaning depends on the app runtime in use, but this usually
    /// involves re-reading the configuration file and applying any changes
    /// Note that not all changes can be applied at runtime.
    reload_config,

    /// Close the current "surface", whether that is a window, tab, split, etc.
    ///
    /// This might trigger a close confirmation popup, depending on the value
    /// of the `confirm-close-surface` configuration setting.
    close_surface,

    /// Close the current tab and all splits therein, close all other tabs, or
    /// close every tab to the right of the current one depending on the mode.
    ///
    /// If the mode is not specified, defaults to closing the current tab.
    ///
    /// This might trigger a close confirmation popup, depending on the value
    /// of the `confirm-close-surface` configuration setting.
    close_tab: CloseTabMode,

    /// Close the current window and all tabs and splits therein.
    ///
    /// This might trigger a close confirmation popup, depending on the value
    /// of the `confirm-close-surface` configuration setting.
    close_window,

    /// Close all windows.
    ///
    /// WARNING: This action has been deprecated and has no effect on either
    /// Linux or macOS. Users are instead encouraged to use `all:close_window`
    /// instead.
    close_all_windows,

    /// Maximize or unmaximize the current window.
    ///
    /// This has no effect on macOS as it does not have the concept of
    /// maximized windows.
    toggle_maximize,

    /// Fullscreen or unfullscreen the current window.
    toggle_fullscreen,

    /// Toggle window decorations (titlebar, buttons, etc.) for the current window.
    ///
    /// Only implemented on Linux.
    toggle_window_decorations,

    /// Toggle whether the terminal window should always float on top of other
    /// windows even when unfocused.
    ///
    /// Terminal windows always start as normal (not float-on-top) windows.
    ///
    /// Only implemented on macOS.
    toggle_window_float_on_top,

    /// Toggle secure input mode.
    ///
    /// This is used to prevent apps from monitoring your keyboard input
    /// when entering passwords or other sensitive information.
    ///
    /// This applies to the entire application, not just the focused terminal.
    /// You must manually untoggle it or quit Ghostty entirely to disable it.
    ///
    /// Only implemented on macOS, as this uses a built-in system API.
    toggle_secure_input,

    /// Toggle mouse reporting on or off.
    ///
    /// When mouse reporting is disabled, mouse events will not be reported to
    /// terminal applications even if they request it. This allows you to always
    /// use the mouse for selection and other terminal UI interactions without
    /// applications capturing mouse input.
    ///
    /// This can also be controlled via the `mouse-reporting` configuration
    /// option.
    toggle_mouse_reporting,

    /// Toggle the command palette.
    ///
    /// The command palette is a popup that lets you see what actions
    /// you can perform, their associated keybindings (if any), a search bar
    /// to filter the actions, and the ability to then execute the action.
    ///
    /// This requires libadwaita 1.5 or newer on Linux. The current libadwaita
    /// version can be found by running `ghostty +version`.
    toggle_command_palette,

    /// Toggle the quick terminal.
    ///
    /// The quick terminal, also known as the "Quake-style" or drop-down
    /// terminal, is a terminal window that appears on demand from a keybinding,
    /// often sliding in from a screen edge such as the top. This is useful for
    /// quick access to a terminal without having to open a new window or tab.
    ///
    /// The terminal state is preserved between appearances, so showing the
    /// quick terminal after it was already hidden would display the same
    /// window instead of creating a new one.
    ///
    /// As quick terminals are often useful when other windows are currently
    /// focused, they are best used with *global* keybinds. For example, one
    /// can define the following key bind to toggle the quick terminal from
    /// anywhere within the system by pressing `` Cmd+` ``:
    ///
    /// ```ini
    /// keybind = global:cmd+backquote=toggle_quick_terminal
    /// ```
    ///
    /// The quick terminal has some limitations:
    ///
    ///   - Only one quick terminal instance can exist at a time.
    ///
    ///   - Unlike normal terminal windows, the quick terminal will not be
    ///     restored when the application is restarted on systems that support
    ///     window restoration like macOS.
    ///
    ///   - On Linux, the quick terminal is only supported on Wayland and not
    ///     X11, and only on Wayland compositors that support the `wlr-layer-shell-v1`
    ///     protocol. In practice, this means that only GNOME users would not be
    ///     able to use this feature.
    ///
    ///   - On Linux, slide-in animations are only supported on KDE, and when
    ///     the "Sliding Popups" KWin plugin is enabled.
    ///
    ///     If you do not have this plugin enabled, open System Settings > Apps
    ///     & Windows > Window Management > Desktop Effects, and enable the
    ///     plugin in the plugin list. Ghostty would then need to be restarted
    ///     fully for this to take effect.
    ///
    ///   - Quick terminal tabs are only supported on Linux and not on macOS.
    ///     This is because tabs on macOS require a title bar.
    ///
    ///   - On macOS, a fullscreened quick terminal will always be in non-native
    ///     fullscreen mode. This is a requirement due to how the quick terminal
    ///     is rendered.
    ///
    /// See the various configurations for the quick terminal in the
    /// configuration file to customize its behavior.
    toggle_quick_terminal,

    /// Show or hide all windows. If all windows become shown, we also ensure
    /// Ghostty becomes focused. When hiding all windows, focus is yielded
    /// to the next application as determined by the OS.
    ///
    /// Note: When the focused surface is fullscreen, this method does nothing.
    ///
    /// Only implemented on macOS.
    toggle_visibility,

    /// Toggle the window background opacity between transparent and opaque.
    ///
    /// This does nothing when `background-opacity` is set to 1 or above.
    ///
    /// When `background-opacity` is less than 1, this action will either make
    /// the window transparent or not depending on its current transparency state.
    ///
    /// Only implemented on macOS.
    toggle_background_opacity,

    /// Check for updates.
    ///
    /// Only implemented on macOS.
    check_for_updates,

    /// Undo the last undoable action for the focused surface or terminal,
    /// if possible. This can undo actions such as closing tabs or
    /// windows.
    ///
    /// Not every action in Ghostty can be undone or redone. The list
    /// of actions support undo/redo is currently limited to:
    ///
    ///   - New window, close window
    ///   - New tab, close tab
    ///   - New split, close split
    ///
    /// All actions are only undoable/redoable for a limited time.
    /// For example, restoring a closed split can only be done for
    /// some number of seconds since the split was closed. The exact
    /// amount is configured with the `undo-timeout` configuration settings.
    ///
    /// The undo/redo actions being limited ensures that there is
    /// bounded memory usage over time, closed surfaces don't continue running
    /// in the background indefinitely, and the keybinds become available
    /// for terminal applications to use.
    ///
    /// Only implemented on macOS.
    undo,

    /// Redo the last undoable action for the focused surface or terminal,
    /// if possible. See "undo" for more details on what can and cannot
    /// be undone or redone.
    redo,

    /// End the currently active key sequence, if any, and flush the
    /// keys up to this point to the terminal, excluding the key that
    /// triggered this action.
    ///
    /// For example: `ctrl+w>escape=end_key_sequence` would encode
    /// `ctrl+w` to the terminal and exit the key sequence.
    ///
    /// Normally, an invalid sequence will reset the key sequence and
    /// flush all data including the invalid key. This action allows
    /// you to flush only the prior keys, which is useful when you want
    /// to bind something like a control key (`ctrl+w`) but not send
    /// additional inputs.
    end_key_sequence,

    /// Activate a named key table (see `keybind` configuration documentation).
    /// The named key table will remain active until `deactivate_key_table`
    /// is called. If you want a one-shot key table activation, use the
    /// `activate_key_table_once` action instead.
    ///
    /// If the named key table does not exist, this action has no effect
    /// and performable will report false.
    ///
    /// If the named key table is already the currently active key table,
    /// this action has no effect and performable will report false.
    activate_key_table: []const u8,

    /// Same as activate_key_table, but the key table will only be active
    /// until the first valid keybinding from that table is used (including
    /// any defined `catch_all` bindings).
    ///
    /// The "once" check is only done if this is the currently active
    /// key table. If another key table is activated later, then this
    /// table will remain active until it pops back out to being the
    /// active key table.
    activate_key_table_once: []const u8,

    /// Deactivate the currently active key table, if any. The next most
    /// recently activated key table (if any) will become active again.
    /// If no key table is active, this action has no effect.
    deactivate_key_table,

    /// Deactivate all active key tables. If no active key table exists,
    /// this will report performable as false.
    deactivate_all_key_tables,

    /// Quit Ghostty.
    quit,

    /// Crash Ghostty in the desired thread for the focused surface.
    ///
    /// WARNING: This is a hard crash (panic) and data can be lost.
    ///
    /// The purpose of this action is to test crash handling. For some
    /// users, it may be useful to test crash reporting functionality in
    /// order to determine if it all works as expected.
    ///
    /// The value determines the crash location:
    ///
    ///   - `main`
    ///
    ///     Crash on the main (GUI) thread.
    ///
    ///   - `io`
    ///
    ///     Crash on the IO thread for the focused surface.
    ///
    ///   - `render`
    ///
    ///     Crash on the render thread for the focused surface.
    ///
    crash: CrashThread,

    pub const Key = @typeInfo(Action).@"union".tag_type.?;

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            Action,
            .{ .name = "GhosttyBindingAction" },
        ),

        .none => void,
    };

    pub const CrashThread = enum {
        main,
        io,
        render,
    };

    pub const CursorKey = struct {
        normal: []const u8,
        application: []const u8,

        pub fn clone(
            self: CursorKey,
            alloc: Allocator,
        ) Allocator.Error!CursorKey {
            return .{
                .normal = try alloc.dupe(u8, self.normal),
                .application = try alloc.dupe(u8, self.application),
            };
        }

        pub fn format(
            self: CursorKey,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            _ = self;
            _ = writer;
            @panic("formatting not supported");
        }
    };

    pub const NavigateSearch = enum {
        previous,
        next,
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
        left,
        up,
        auto, // splits along the larger direction

        pub const default: SplitDirection = .auto;
    };

    pub const SplitFocusDirection = enum {
        previous,
        next,
        up,
        left,
        down,
        right,

        pub fn parse(input: []const u8) !SplitFocusDirection {
            return std.meta.stringToEnum(SplitFocusDirection, input) orelse {
                // For backwards compatibility we map "top" and "bottom" onto the enum
                // values "up" and "down"
                if (std.mem.eql(u8, input, "top")) {
                    return .up;
                } else if (std.mem.eql(u8, input, "bottom")) {
                    return .down;
                } else {
                    return Error.InvalidFormat;
                }
            };
        }

        test "parse" {
            const testing = std.testing;

            try testing.expectEqual(.previous, try SplitFocusDirection.parse("previous"));
            try testing.expectEqual(.next, try SplitFocusDirection.parse("next"));

            try testing.expectEqual(.up, try SplitFocusDirection.parse("up"));
            try testing.expectEqual(.left, try SplitFocusDirection.parse("left"));
            try testing.expectEqual(.down, try SplitFocusDirection.parse("down"));
            try testing.expectEqual(.right, try SplitFocusDirection.parse("right"));

            try testing.expectEqual(.up, try SplitFocusDirection.parse("top"));
            try testing.expectEqual(.down, try SplitFocusDirection.parse("bottom"));

            try testing.expectError(error.InvalidFormat, SplitFocusDirection.parse(""));
            try testing.expectError(error.InvalidFormat, SplitFocusDirection.parse("green"));
        }
    };

    pub const SplitResizeDirection = enum {
        up,
        down,
        left,
        right,
    };

    pub const GotoWindow = enum {
        previous,
        next,
    };

    pub const SplitResizeParameter = struct {
        SplitResizeDirection,
        u16,
    };

    pub const CopyToClipboard = enum {
        plain,
        vt,
        html,

        /// This type will mix multiple distinct types with a set content-type
        /// such as text/html for html, so that the OS/application can choose
        /// what is best when pasting.
        mixed,

        pub const default: CopyToClipboard = .mixed;
    };

    pub const WriteScreen = struct {
        action: WriteScreen.Action,
        emit: WriteScreen.Format,

        pub const copy: WriteScreen = .{ .action = .copy, .emit = .plain };
        pub const paste: WriteScreen = .{ .action = .paste, .emit = .plain };
        pub const open: WriteScreen = .{ .action = .open, .emit = .plain };

        pub const Action = enum {
            copy,
            paste,
            open,
        };

        pub const Format = enum {
            plain,
            vt,
            html,
        };

        pub fn parse(param: []const u8) !WriteScreen {
            // If we don't have a `,`, default to the plain format. This is
            // also very important for backwards compatibility before Ghostty
            // 1.3 which didn't support output formats.
            const idx = std.mem.indexOfScalar(u8, param, ',') orelse return .{
                .action = try Binding.Action.parseEnum(
                    WriteScreen.Action,
                    param,
                ),
                .emit = .plain,
            };

            return .{
                .action = try Binding.Action.parseEnum(
                    WriteScreen.Action,
                    param[0..idx],
                ),
                .emit = try Binding.Action.parseEnum(
                    WriteScreen.Format,
                    param[idx + 1 ..],
                ),
            };
        }

        pub fn clone(
            self: WriteScreen,
            alloc: Allocator,
        ) Allocator.Error!WriteScreen {
            _ = alloc;
            return self;
        }

        pub fn format(self: WriteScreen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{t},{t}", .{
                self.action,
                self.emit,
            });
        }
    };

    // Extern because it is used in the embedded runtime ABI.
    pub const InspectorMode = enum {
        toggle,
        show,
        hide,
    };

    pub const CloseTabMode = enum {
        this,
        other,
        right,

        pub const default: CloseTabMode = .this;
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
        const field_info = @typeInfo(field.type);

        // Fields can provide a custom "parse" function
        if (field_info == .@"struct" or
            field_info == .@"union" or
            field_info == .@"enum")
        {
            if (@hasDecl(field.type, "parse") and
                @typeInfo(@TypeOf(field.type.parse)) == .@"fn")
            {
                return try field.type.parse(param);
            }
        }

        return switch (field_info) {
            .@"enum" => try parseEnum(field.type, param),
            .int => try parseInt(field.type, param),
            .float => try parseFloat(field.type, param),
            .@"struct" => |info| blk: {
                // Only tuples are supported to avoid ambiguity with field
                // ordering
                comptime assert(info.is_tuple);

                var it = std.mem.splitAny(u8, param, ",");
                var value: field.type = undefined;
                inline for (info.fields) |field_| {
                    const next = it.next() orelse return Error.InvalidFormat;
                    @field(value, field_.name) = switch (@typeInfo(field_.type)) {
                        .@"enum" => try parseEnum(field_.type, next),
                        .int => try parseInt(field_.type, next),
                        .float => try parseFloat(field_.type, next),
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

        const actionInfo = @typeInfo(Action).@"union";
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
                        // Get the parameter after the colon. The parameter
                        // can be optional for action types that can have a
                        // "default" decl.
                        const idx = colonIdx orelse {
                            switch (@typeInfo(field.type)) {
                                .@"struct",
                                .@"union",
                                .@"enum",
                                => if (@hasDecl(field.type, "default")) {
                                    return @unionInit(
                                        Action,
                                        field.name,
                                        @field(field.type, "default"),
                                    );
                                },

                                else => {},
                            }

                            return Error.InvalidFormat;
                        };

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

    /// The scope of an action. The scope is the context in which an action
    /// must be executed.
    pub const Scope = enum {
        app,
        surface,
    };

    /// Returns the scope of an action.
    pub fn scope(self: Action) Scope {
        return switch (self) {
            // Doesn't really matter, so we'll see app.
            .ignore,
            .unbind,
            => .app,

            // Obviously app actions.
            .open_config,
            .reload_config,
            .close_all_windows,
            .quit,
            .toggle_quick_terminal,
            .toggle_visibility,
            .check_for_updates,
            .show_gtk_inspector,
            => .app,

            // These are app but can be special-cased in a surface context.
            .new_window,
            .undo,
            .redo,
            => .app,

            // Obviously surface actions.
            .csi,
            .esc,
            .text,
            .cursor_key,
            .search,
            .navigate_search,
            .search_selection,
            .start_search,
            .end_search,
            .reset,
            .copy_to_clipboard,
            .copy_url_to_clipboard,
            .copy_title_to_clipboard,
            .paste_from_clipboard,
            .paste_from_selection,
            .increase_font_size,
            .decrease_font_size,
            .reset_font_size,
            .set_font_size,
            .prompt_surface_title,
            .prompt_tab_title,
            .prompt_window_title,
            .clear_screen,
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
            .close_surface,
            .close_tab,
            .close_window,
            .toggle_maximize,
            .toggle_fullscreen,
            .toggle_window_decorations,
            .toggle_window_float_on_top,
            .toggle_secure_input,
            .toggle_mouse_reporting,
            .toggle_command_palette,
            .toggle_background_opacity,
            .show_on_screen_keyboard,
            .reset_window_size,
            .activate_key_table,
            .activate_key_table_once,
            .deactivate_key_table,
            .deactivate_all_key_tables,
            .end_key_sequence,
            .crash,
            => .surface,

            // These are less obvious surface actions. They're surface
            // actions because they are relevant to the surface they
            // come from. For example `new_window` needs to be sourced to
            // a surface so inheritance can be done correctly.
            .new_tab,
            .previous_tab,
            .next_tab,
            .last_tab,
            .goto_tab,
            .move_tab,
            .toggle_tab_overview,
            .new_split,
            .goto_split,
            .goto_window,
            .toggle_split_zoom,
            .toggle_readonly,
            .resize_split,
            .equalize_splits,
            .inspector,
            => .surface,
        };
    }

    /// Returns a union type that only contains actions that are scoped to
    /// the given scope.
    pub fn Scoped(comptime s: Scope) type {
        @setEvalBranchQuota(100_000);

        const all_fields = @typeInfo(Action).@"union".fields;

        // Find all fields that are app-scoped
        var i: usize = 0;
        var union_fields: [all_fields.len]std.builtin.Type.UnionField = undefined;
        var enum_fields: [all_fields.len]std.builtin.Type.EnumField = undefined;
        for (all_fields) |field| {
            const action = @unionInit(Action, field.name, undefined);
            if (action.scope() == s) {
                union_fields[i] = field;
                enum_fields[i] = .{ .name = field.name, .value = i };
                i += 1;
            }
        }

        // Build our union
        return @Type(.{ .@"union" = .{
            .layout = .auto,
            .tag_type = @Type(.{ .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, i),
                .fields = enum_fields[0..i],
                .decls = &.{},
                .is_exhaustive = true,
            } }),
            .fields = union_fields[0..i],
            .decls = &.{},
        } });
    }

    /// Returns the scoped version of this action. If the action is not
    /// scoped to the given scope then this returns null.
    ///
    /// The benefit of this function is that it allows us to use Zig's
    /// exhaustive switch safety to ensure we always properly handle certain
    /// scoped actions.
    pub fn scoped(self: Action, comptime s: Scope) ?Scoped(s) {
        switch (self) {
            inline else => |v, tag| {
                // Use comptime to prune out non-app actions
                if (comptime @unionInit(
                    Action,
                    @tagName(tag),
                    undefined,
                ).scope() != s) return null;

                // Initialize our app action
                return @unionInit(
                    Scoped(s),
                    @tagName(tag),
                    v,
                );
            },
        }
    }

    /// Implements the formatter for the fmt package. This encodes the
    /// action back into the format used by parse.
    pub fn format(
        self: Action,
        writer: *std.Io.Writer,
    ) !void {
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
        writer: *std.Io.Writer,
        value: anytype,
    ) !void {
        const Value = @TypeOf(value);
        const value_info = @typeInfo(Value);
        switch (Value) {
            void => {},
            []const u8 => try std.zig.stringEscape(value, writer),
            else => switch (value_info) {
                .@"enum" => try writer.print("{t}", .{value}),
                .float => try writer.print("{d}", .{value}),
                .int => try writer.print("{d}", .{value}),
                .@"struct" => |info| format: {
                    if (@hasDecl(Value, "format")) {
                        try value.format(writer);
                        break :format;
                    }

                    if (!info.is_tuple) {
                        @compileError("unhandled struct type: " ++ @typeName(Value));
                    } else {
                        inline for (info.fields, 0..) |field, i| {
                            try formatValue(writer, @field(value, field.name));
                            if (i + 1 < info.fields.len) try writer.writeAll(",");
                        }
                    }
                },
                else => @compileError("unhandled type: " ++ @typeName(Value)),
            },
        }
    }

    /// Clone this action with the given allocator. The allocator
    /// should be an arena-style allocator since fine-grained
    /// deallocation is not possible.
    pub fn clone(self: Action, alloc: Allocator) Allocator.Error!Action {
        return switch (self) {
            inline else => |value, tag| @unionInit(
                Action,
                @tagName(tag),
                try cloneValue(alloc, value),
            ),
        };
    }

    fn cloneValue(
        alloc: Allocator,
        value: anytype,
    ) Allocator.Error!@TypeOf(value) {
        return switch (@typeInfo(@TypeOf(value))) {
            .void,
            .int,
            .float,
            .@"enum",
            => value,

            .pointer => |info| slice: {
                comptime assert(info.size == .slice);
                break :slice try alloc.dupe(
                    info.child,
                    value,
                );
            },

            .@"struct" => |info| if (info.is_tuple)
                value
            else
                try value.clone(alloc),

            else => {
                @compileLog(@TypeOf(value));
                @compileError("unexpected type");
            },
        };
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hash(self: Action) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashIncremental(&hasher);
        return hasher.final();
    }

    /// Hash the action into the given hasher.
    fn hashIncremental(self: Action, hasher: anytype) void {
        // Always has the active tag.
        const Tag = @typeInfo(Action).@"union".tag_type.?;
        std.hash.autoHash(hasher, @as(Tag, self));

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
                        hasher,
                        @as(u32, @bitCast(field)),
                    ),
                    f64 => std.hash.autoHash(
                        hasher,
                        @as(u64, @bitCast(field)),
                    ),

                    // Everything else automatically handle.
                    else => std.hash.autoHashStrat(
                        hasher,
                        field,
                        .DeepRecursive,
                    ),
                }
            },
        }
    }

    /// Compares two actions for equality.
    pub fn equal(self: Action, other: Action) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            inline else => |field_self, tag| {
                const field_other = @field(other, @tagName(tag));
                return deepEqual(
                    @TypeOf(field_self),
                    field_self,
                    field_other,
                );
            },
        };
    }

    /// For the Set.Context
    const bindingSetEqual = equal;
};

/// Trigger is the associated key state that can trigger an action.
/// This is an extern struct because this is also used in the C API.
///
/// This must be kept in sync with include/ghostty.h ghostty_input_trigger_s
pub const Trigger = struct {
    /// The key that has to be pressed for a binding to take action.
    key: Trigger.Key = .{ .physical = .unidentified },

    /// The key modifiers that must be active for this to match.
    mods: key.Mods = .{},

    pub const Key = union(C.Tag) {
        /// key is the "physical" version. This is the same as mapped for
        /// standard US keyboard layouts. For non-US keyboard layouts, this
        /// is used to bind to a physical key location rather than a translated
        /// key.
        physical: key.Key,

        /// This is used for binding to keys that produce a certain unicode
        /// codepoint. This is useful for binding to keys that don't have a
        /// registered keycode with Ghostty.
        unicode: u21,

        /// A catch-all key that matches any key press that is otherwise
        /// unbound.
        catch_all,
    };

    /// The extern struct used for triggers in the C API.
    pub const C = extern struct {
        tag: Tag = .physical,
        key: C.Key = .{ .physical = .unidentified },
        mods: key.Mods = .{},

        pub const Tag = enum(c_int) {
            physical,
            unicode,
            catch_all,
        };

        pub const Key = extern union {
            physical: key.Key,
            unicode: u32,
        };
    };

    /// Parse a single trigger. The input is expected to be ONLY the trigger
    /// (i.e. in the sequence `a=ignore` input is only `a`). The trigger may
    /// not be part of a sequence (i.e. `a>b`). This parses exactly a single
    /// trigger.
    pub fn parse(input: []const u8) !Trigger {
        if (input.len == 0) return Error.InvalidFormat;
        var result: Trigger = .{};
        var rem: []const u8 = input;
        loop: while (rem.len > 0) {
            const idx = std.mem.indexOfScalar(u8, rem, '+') orelse rem.len;
            const part = rem[0..idx];
            rem = if (idx >= rem.len) "" else rem[idx + 1 ..];

            // Check if its a modifier
            const modsInfo = @typeInfo(key.Mods).@"struct";
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
            inline for (key_mods.alias) |pair| {
                if (std.mem.eql(u8, part, pair[0])) {
                    // Repeat not allowed
                    const field = @tagName(pair[1]);
                    if (@field(result.mods, field)) return Error.InvalidFormat;
                    @field(result.mods, field) = true;
                    continue :loop;
                }
            }

            // Anything after this point is a key and we only support
            // single keys.
            if (!result.isKeyUnset()) return Error.InvalidFormat;

            // If the part is empty it means that it is actually
            // a literal `+`, which we treat as a Unicode character.
            if (part.len == 0) {
                result.key = .{ .unicode = '+' };
                continue :loop;
            }

            // Check if its a key
            const keysInfo = @typeInfo(key.Key).@"enum";
            inline for (keysInfo.fields) |field| {
                if (!std.mem.eql(u8, field.name, "unidentified")) {
                    if (std.mem.eql(u8, part, field.name)) {
                        const keyval = @field(key.Key, field.name);
                        result.key = .{ .physical = keyval };
                        continue :loop;
                    }
                }
            }

            // If we're still unset and we have exactly one unicode
            // character then we can use that as a key.
            if (result.isKeyUnset()) unicode: {
                // Invalid UTF8 drops to invalid format
                const view = std.unicode.Utf8View.init(part) catch break :unicode;
                var it = view.iterator();

                // No codepoints or multiple codepoints drops to invalid format
                const cp = it.nextCodepoint() orelse break :unicode;
                if (it.nextCodepoint() != null) break :unicode;

                result.key = .{ .unicode = cp };
                continue :loop;
            }

            // Look for a matching w3c name next.
            if (key.Key.fromW3C(part)) |w3c_key| {
                result.key = .{ .physical = w3c_key };
                continue :loop;
            }

            // Check for catch_all. We do this near the end since its unlikely
            // in most cases that we're setting a catch-all key.
            if (std.mem.eql(u8, part, "catch_all")) {
                result.key = .catch_all;
                continue :loop;
            }

            // If we're still unset then we look for backwards compatible
            // keys with Ghostty 1.1.x. We do this last so its least likely
            // to impact performance for modern users.
            if (backwards_compatible_keys.get(part)) |old_key| {
                result.key = old_key;
                continue :loop;
            }

            // We didn't recognize this value
            return Error.InvalidFormat;
        }

        return result;
    }

    /// The values that are backwards compatible with Ghostty 1.1.x.
    /// Ghostty 1.2+ doesn't support these anymore since we moved to
    /// W3C key codes.
    const backwards_compatible_keys = std.StaticStringMap(Key).initComptime(.{
        .{ "zero", Key{ .unicode = '0' } },
        .{ "one", Key{ .unicode = '1' } },
        .{ "two", Key{ .unicode = '2' } },
        .{ "three", Key{ .unicode = '3' } },
        .{ "four", Key{ .unicode = '4' } },
        .{ "five", Key{ .unicode = '5' } },
        .{ "six", Key{ .unicode = '6' } },
        .{ "seven", Key{ .unicode = '7' } },
        .{ "eight", Key{ .unicode = '8' } },
        .{ "nine", Key{ .unicode = '9' } },
        .{ "plus", Key{ .unicode = '+' } },
        .{ "apostrophe", Key{ .unicode = '\'' } },
        .{ "grave_accent", Key{ .physical = .backquote } },
        .{ "left_bracket", Key{ .physical = .bracket_left } },
        .{ "right_bracket", Key{ .physical = .bracket_right } },
        .{ "up", Key{ .physical = .arrow_up } },
        .{ "down", Key{ .physical = .arrow_down } },
        .{ "left", Key{ .physical = .arrow_left } },
        .{ "right", Key{ .physical = .arrow_right } },
        .{ "kp_0", Key{ .physical = .numpad_0 } },
        .{ "kp_1", Key{ .physical = .numpad_1 } },
        .{ "kp_2", Key{ .physical = .numpad_2 } },
        .{ "kp_3", Key{ .physical = .numpad_3 } },
        .{ "kp_4", Key{ .physical = .numpad_4 } },
        .{ "kp_5", Key{ .physical = .numpad_5 } },
        .{ "kp_6", Key{ .physical = .numpad_6 } },
        .{ "kp_7", Key{ .physical = .numpad_7 } },
        .{ "kp_8", Key{ .physical = .numpad_8 } },
        .{ "kp_9", Key{ .physical = .numpad_9 } },
        .{ "kp_add", Key{ .physical = .numpad_add } },
        .{ "kp_subtract", Key{ .physical = .numpad_subtract } },
        .{ "kp_multiply", Key{ .physical = .numpad_multiply } },
        .{ "kp_divide", Key{ .physical = .numpad_divide } },
        .{ "kp_decimal", Key{ .physical = .numpad_decimal } },
        .{ "kp_enter", Key{ .physical = .numpad_enter } },
        .{ "kp_equal", Key{ .physical = .numpad_equal } },
        .{ "kp_separator", Key{ .physical = .numpad_separator } },
        .{ "kp_left", Key{ .physical = .numpad_left } },
        .{ "kp_right", Key{ .physical = .numpad_right } },
        .{ "kp_up", Key{ .physical = .numpad_up } },
        .{ "kp_down", Key{ .physical = .numpad_down } },
        .{ "kp_page_up", Key{ .physical = .numpad_page_up } },
        .{ "kp_page_down", Key{ .physical = .numpad_page_down } },
        .{ "kp_home", Key{ .physical = .numpad_home } },
        .{ "kp_end", Key{ .physical = .numpad_end } },
        .{ "kp_insert", Key{ .physical = .numpad_insert } },
        .{ "kp_delete", Key{ .physical = .numpad_delete } },
        .{ "kp_begin", Key{ .physical = .numpad_begin } },
        .{ "left_shift", Key{ .physical = .shift_left } },
        .{ "right_shift", Key{ .physical = .shift_right } },
        .{ "left_control", Key{ .physical = .control_left } },
        .{ "right_control", Key{ .physical = .control_right } },
        .{ "left_alt", Key{ .physical = .alt_left } },
        .{ "right_alt", Key{ .physical = .alt_right } },
        .{ "left_super", Key{ .physical = .meta_left } },
        .{ "right_super", Key{ .physical = .meta_right } },

        // Physical variants. This is a blunt approach to this but its
        // glue for backwards compatibility so I'm not too worried about
        // making this super nice.
        .{ "physical:zero", Key{ .physical = .digit_0 } },
        .{ "physical:one", Key{ .physical = .digit_1 } },
        .{ "physical:two", Key{ .physical = .digit_2 } },
        .{ "physical:three", Key{ .physical = .digit_3 } },
        .{ "physical:four", Key{ .physical = .digit_4 } },
        .{ "physical:five", Key{ .physical = .digit_5 } },
        .{ "physical:six", Key{ .physical = .digit_6 } },
        .{ "physical:seven", Key{ .physical = .digit_7 } },
        .{ "physical:eight", Key{ .physical = .digit_8 } },
        .{ "physical:nine", Key{ .physical = .digit_9 } },
        .{ "physical:apostrophe", Key{ .physical = .quote } },
        .{ "physical:grave_accent", Key{ .physical = .backquote } },
        .{ "physical:left_bracket", Key{ .physical = .bracket_left } },
        .{ "physical:right_bracket", Key{ .physical = .bracket_right } },
        .{ "physical:up", Key{ .physical = .arrow_up } },
        .{ "physical:down", Key{ .physical = .arrow_down } },
        .{ "physical:left", Key{ .physical = .arrow_left } },
        .{ "physical:right", Key{ .physical = .arrow_right } },
        .{ "physical:kp_0", Key{ .physical = .numpad_0 } },
        .{ "physical:kp_1", Key{ .physical = .numpad_1 } },
        .{ "physical:kp_2", Key{ .physical = .numpad_2 } },
        .{ "physical:kp_3", Key{ .physical = .numpad_3 } },
        .{ "physical:kp_4", Key{ .physical = .numpad_4 } },
        .{ "physical:kp_5", Key{ .physical = .numpad_5 } },
        .{ "physical:kp_6", Key{ .physical = .numpad_6 } },
        .{ "physical:kp_7", Key{ .physical = .numpad_7 } },
        .{ "physical:kp_8", Key{ .physical = .numpad_8 } },
        .{ "physical:kp_9", Key{ .physical = .numpad_9 } },
        .{ "physical:kp_add", Key{ .physical = .numpad_add } },
        .{ "physical:kp_subtract", Key{ .physical = .numpad_subtract } },
        .{ "physical:kp_multiply", Key{ .physical = .numpad_multiply } },
        .{ "physical:kp_divide", Key{ .physical = .numpad_divide } },
        .{ "physical:kp_decimal", Key{ .physical = .numpad_decimal } },
        .{ "physical:kp_enter", Key{ .physical = .numpad_enter } },
        .{ "physical:kp_equal", Key{ .physical = .numpad_equal } },
        .{ "physical:kp_separator", Key{ .physical = .numpad_separator } },
        .{ "physical:kp_left", Key{ .physical = .numpad_left } },
        .{ "physical:kp_right", Key{ .physical = .numpad_right } },
        .{ "physical:kp_up", Key{ .physical = .numpad_up } },
        .{ "physical:kp_down", Key{ .physical = .numpad_down } },
        .{ "physical:kp_page_up", Key{ .physical = .numpad_page_up } },
        .{ "physical:kp_page_down", Key{ .physical = .numpad_page_down } },
        .{ "physical:kp_home", Key{ .physical = .numpad_home } },
        .{ "physical:kp_end", Key{ .physical = .numpad_end } },
        .{ "physical:kp_insert", Key{ .physical = .numpad_insert } },
        .{ "physical:kp_delete", Key{ .physical = .numpad_delete } },
        .{ "physical:kp_begin", Key{ .physical = .numpad_begin } },
        .{ "physical:left_shift", Key{ .physical = .shift_left } },
        .{ "physical:right_shift", Key{ .physical = .shift_right } },
        .{ "physical:left_control", Key{ .physical = .control_left } },
        .{ "physical:right_control", Key{ .physical = .control_right } },
        .{ "physical:left_alt", Key{ .physical = .alt_left } },
        .{ "physical:right_alt", Key{ .physical = .alt_right } },
        .{ "physical:left_super", Key{ .physical = .meta_left } },
        .{ "physical:right_super", Key{ .physical = .meta_right } },
    });

    /// Returns true if this trigger has no key set.
    pub fn isKeyUnset(self: Trigger) bool {
        return switch (self.key) {
            .physical => |v| v == .unidentified,
            .unicode, .catch_all => false,
        };
    }

    /// Returns a hash code that can be used to uniquely identify this trigger.
    pub fn hash(self: Trigger) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashIncremental(&hasher);
        return hasher.final();
    }

    /// Hash the trigger into the given hasher.
    fn hashIncremental(self: Trigger, hasher: anytype) void {
        std.hash.autoHash(hasher, std.meta.activeTag(self.key));
        switch (self.key) {
            .physical => |v| std.hash.autoHash(hasher, v),
            .unicode => |cp| std.hash.autoHash(
                hasher,
                foldedCodepoint(cp),
            ),
            .catch_all => {},
        }
        std.hash.autoHash(hasher, self.mods.binding());
    }

    /// The codepoint we use for comparisons. Case folding can result
    /// in more codepoints so we need to use a 3 element array.
    fn foldedCodepoint(cp: u21) [3]u21 {
        // ASCII fast path
        if (uucode.ascii.isAlphabetic(cp)) {
            return .{ uucode.ascii.toLower(cp), 0, 0 };
        }

        // Unicode slow path. Case folding can result in more codepoints.
        // If more codepoints are produced then we return the codepoint
        // as-is which isn't correct but until we have a failing test
        // then I don't want to handle this.
        var buffer: [1]u21 = undefined;
        const slice = uucode.get(.case_folding_full, cp).with(&buffer, cp);
        var array: [3]u21 = [_]u21{0} ** 3;
        @memcpy(array[0..slice.len], slice);
        return array;
    }

    /// Returns true if two triggers are equal.
    pub fn equal(self: Trigger, other: Trigger) bool {
        if (self.mods != other.mods) return false;
        const self_tag = std.meta.activeTag(self.key);
        const other_tag = std.meta.activeTag(other.key);
        if (self_tag != other_tag) return false;
        return switch (self.key) {
            .physical => |v| v == other.key.physical,
            .unicode => |v| v == other.key.unicode,
            .catch_all => true,
        };
    }

    /// Returns true if two triggers are equal using folded codepoints.
    pub fn foldedEqual(self: Trigger, other: Trigger) bool {
        if (self.mods != other.mods) return false;
        const self_tag = std.meta.activeTag(self.key);
        const other_tag = std.meta.activeTag(other.key);
        if (self_tag != other_tag) return false;
        return switch (self.key) {
            .physical => |v| v == other.key.physical,
            .unicode => |v| deepEqual(
                [3]u21,
                foldedCodepoint(v),
                foldedCodepoint(other.key.unicode),
            ),
            .catch_all => true,
        };
    }

    /// For the Set.Context
    const bindingSetEqual = foldedEqual;

    /// Convert the trigger to a C API compatible trigger.
    pub fn cval(self: Trigger) C {
        return .{
            .tag = self.key,
            .key = switch (self.key) {
                .physical => |v| .{ .physical = v },
                .unicode => |v| .{ .unicode = @intCast(v) },
                // catch_all has no associated value so its an error
                // for a C consumer to look at it.
                .catch_all => undefined,
            },
            .mods = self.mods,
        };
    }

    /// Format implementation for fmt package.
    pub fn format(
        self: Trigger,
        writer: *std.Io.Writer,
    ) !void {
        // Modifiers first
        if (self.mods.super) try writer.writeAll("super+");
        if (self.mods.ctrl) try writer.writeAll("ctrl+");
        if (self.mods.alt) try writer.writeAll("alt+");
        if (self.mods.shift) try writer.writeAll("shift+");

        // Key
        switch (self.key) {
            .physical => |k| try writer.print("{t}", .{k}),
            .unicode => |c| try writer.print("{u}", .{c}),
            .catch_all => try writer.writeAll("catch_all"),
        }
    }
};

/// A structure that contains a set of bindings and focuses on fast lookup.
/// The use case is that this will be called on EVERY key input to look
/// for an associated action so it must be fast.
pub const Set = struct {
    const HashMap = std.ArrayHashMapUnmanaged(
        Trigger,
        Value,
        Context(Trigger),
        true,
    );

    const ReverseMap = std.ArrayHashMapUnmanaged(
        Action,
        Trigger,
        Context(Action),
        true,
    );

    /// The set of bindings.
    bindings: HashMap = .{},

    /// The reverse mapping of action to binding. Note that multiple
    /// bindings can map to the same action and this map will only have
    /// the most recently added binding for an action.
    ///
    /// Sequenced triggers are never present in the reverse map at this time.
    /// This is a conscious decision since the primary use case of the reverse
    /// map is to support GUI toolkit keyboard accelerators and no mainstream
    /// GUI toolkit supports sequences.
    ///
    /// Performable triggers are also not present in the reverse map. This
    /// is so that GUI toolkits don't register performable triggers as
    /// menu shortcuts (the primary use case of the reverse map). GUI toolkits
    /// such as GTK handle menu shortcuts too early in the event lifecycle
    /// for performable to work so this is a conscious decision to ease the
    /// integration with GUI toolkits.
    reverse: ReverseMap = .{},

    /// The chain parent is the information necessary to attach a chained
    /// action to the proper location in our mapping. It tracks both the
    /// entry in the hashmap and the set it belongs to, which is needed
    /// to properly update reverse mappings when converting a leaf to
    /// a chained action.
    chain_parent: ?ChainParent = null,

    /// Information about a chain parent entry, including which set it
    /// belongs to. This is needed because reverse mappings are only
    /// maintained in the root set, but the chain parent entry may be
    /// in a nested set (for leader key sequences).
    const ChainParent = struct {
        key_ptr: *Trigger,
        value_ptr: *Value,
        set: *Set,
    };

    /// The entry type for the forward mapping of trigger to action.
    pub const Value = union(enum) {
        /// This key is a leader key in a sequence. You must follow the given
        /// set to find the next key in the sequence.
        leader: *Set,

        /// This trigger completes a sequence and the value is the action
        /// to take along with the flags that may define binding behavior.
        leaf: Leaf,

        /// A set of actions to take in response to a trigger.
        leaf_chained: LeafChained,

        /// Implements the formatter for the fmt package. This encodes the
        /// action back into the format used by parse.
        pub fn format(
            self: Value,
            writer: *std.Io.Writer,
        ) !void {
            switch (self) {
                .leader => |set| {
                    // the leader key was already printed.
                    var iter = set.bindings.iterator();
                    while (iter.next()) |binding| {
                        try writer.print(
                            ">{s}{s}",
                            .{ binding.key_ptr.*, binding.value_ptr.* },
                        );
                    }
                },

                .leaf => |leaf| {
                    // action implements the format
                    try writer.print("={s}", .{leaf.action});
                },
            }
        }

        /// Writes the configuration entries for the binding
        /// that this value is part of.
        ///
        /// The value may be part of multiple configuration entries
        /// if they're all part of the same prefix sequence (e.g. 'a>b', 'a>c').
        /// These will result in multiple separate entries in the configuration.
        ///
        /// `buffer_stream` is a FixedBufferStream used for temporary storage
        /// that is shared between calls to nested levels of the set.
        /// For example, 'a>b>c=x' and 'a>b>d=y' will reuse the 'a>b' written
        /// to the buffer before flushing it to the formatter with 'c=x' and 'd=y'.
        pub fn formatEntries(
            self: Value,
            buffer: *std.Io.Writer,
            formatter: EntryFormatter,
        ) !void {
            switch (self) {
                .leader => |set| {
                    // We'll rewind to this position after each sub-entry,
                    // sharing the prefix between siblings.
                    const pos = buffer.end;

                    var iter = set.bindings.iterator();
                    while (iter.next()) |binding| {
                        // I'm not exactly if this is safe for any arbitrary
                        // writer since the Writer interface does not have any
                        // rewind functions, but for our use case of a
                        // fixed-size buffer writer this should work just fine.
                        buffer.end = pos;
                        buffer.print(">{f}", .{binding.key_ptr.*}) catch return error.OutOfMemory;
                        try binding.value_ptr.*.formatEntries(buffer, formatter);
                    }
                },

                .leaf => |leaf| {
                    // When we get to the leaf, the buffer_stream contains
                    // the full sequence of keys needed to reach this action.
                    buffer.print("={f}", .{leaf.action}) catch return error.OutOfMemory;
                    try formatter.formatEntry([]const u8, buffer.buffer[0..buffer.end]);
                },

                .leaf_chained => |leaf| {
                    const pos = buffer.end;
                    for (leaf.actions.items, 0..) |action, i| {
                        if (i == 0) {
                            buffer.print("={f}", .{action}) catch return error.OutOfMemory;
                        } else {
                            buffer.end = 0;
                            buffer.print("chain={f}", .{action}) catch return error.OutOfMemory;
                        }
                        try formatter.formatEntry([]const u8, buffer.buffer[0..buffer.end]);
                        buffer.end = pos;
                    }
                },
            }
        }
    };

    /// Leaf node of a set is an action to trigger. This is a "leaf" compared
    /// to the inner nodes which are "leaders" for sequences.
    pub const Leaf = struct {
        action: Action,
        flags: Flags,

        pub fn clone(
            self: Leaf,
            alloc: Allocator,
        ) Allocator.Error!Leaf {
            return .{
                .action = try self.action.clone(alloc),
                .flags = self.flags,
            };
        }

        pub fn hash(self: Leaf) u64 {
            var hasher = std.hash.Wyhash.init(0);
            self.action.hash(&hasher);
            std.hash.autoHash(&hasher, self.flags);
            return hasher.final();
        }

        pub fn generic(self: *const Leaf) GenericLeaf {
            return .{
                .flags = self.flags,
                .actions = .{ .single = .{self.action} },
            };
        }
    };

    /// Leaf node of a set that triggers multiple actions in sequence.
    pub const LeafChained = struct {
        actions: std.ArrayList(Action),
        flags: Flags,

        pub fn clone(
            self: LeafChained,
            alloc: Allocator,
        ) Allocator.Error!LeafChained {
            var cloned_actions = try self.actions.clone(alloc);
            errdefer cloned_actions.deinit(alloc);
            for (cloned_actions.items) |*action| {
                action.* = try action.clone(alloc);
            }
            return .{
                .actions = cloned_actions,
                .flags = self.flags,
            };
        }

        pub fn deinit(self: *LeafChained, alloc: Allocator) void {
            self.actions.deinit(alloc);
        }

        pub fn generic(self: *const LeafChained) GenericLeaf {
            return .{
                .flags = self.flags,
                .actions = .{ .many = self.actions.items },
            };
        }
    };

    /// A generic leaf node that can be used to unify the handling of
    /// leaf and leaf_chained.
    pub const GenericLeaf = struct {
        flags: Flags,
        actions: union(enum) {
            single: [1]Action,
            many: []const Action,
        },

        pub fn actionsSlice(self: *const GenericLeaf) []const Action {
            return switch (self.actions) {
                .single => |*arr| arr,
                .many => |slice| slice,
            };
        }
    };

    /// A full key-value entry for the set.
    pub const Entry = HashMap.Entry;

    pub fn deinit(self: *Set, alloc: Allocator) void {
        // Clear any leaders if we have them
        var it = self.bindings.iterator();
        while (it.next()) |entry| switch (entry.value_ptr.*) {
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },

            .leaf_chained => |*l| l.deinit(alloc),

            .leaf => {},
        };

        self.bindings.deinit(alloc);
        self.reverse.deinit(alloc);
        self.* = undefined;
    }

    /// Parse a user input binding and add it to the set. This will handle
    /// the "unbind" case, ensure consumed/unconsumed fields are set correctly,
    /// handle sequences, etc.
    ///
    /// If this returns an OutOfMemory error then the set is in a broken
    /// state and should not be used again. Any Error returned is validated
    /// before any set modifications are made.
    pub fn parseAndPut(
        self: *Set,
        alloc: Allocator,
        input: []const u8,
    ) (Allocator.Error || Error)!void {
        // To make cleanup easier, we ensure that the full sequence is
        // valid before making any set modifications. This is more expensive
        // computationally but it makes cleanup way, way easier.
        var it = try Parser.init(input);
        while (try it.next()) |_| {}
        it.reset();

        // We use recursion so that we can utilize the stack as our state
        // for cleanup.
        const updated_set_ = self.parseAndPutRecurse(
            self,
            alloc,
            &it,
        ) catch |err| err: {
            switch (err) {
                // If this gets sent up to the root then we've unbound
                // all the way up and this put was a success.
                error.SequenceUnbind => break :err null,

                // If our parser input was too short then the format
                // is invalid because we handle all valid cases.
                error.UnexpectedEndOfInput => return error.InvalidFormat,

                // If we had a chain without a parent then the format is wrong.
                error.NoChainParent => return error.InvalidFormat,

                // If we had an invalid action for a chain (e.g. unbind).
                error.InvalidChainAction => return error.InvalidFormat,

                // Unrecoverable
                error.OutOfMemory => return error.OutOfMemory,
            }

            // Errors must never fall through.
            unreachable;
        };

        // If we have an updated set (a binding was added) then we store
        // it for our chain parent. If we didn't update a set then we clear
        // our chain parent since chaining is no longer valid until a
        // valid binding is saved.
        if (updated_set_) |updated_set| {
            // A successful addition must have recorded a chain parent.
            assert(updated_set.chain_parent != null);
            if (updated_set != self) self.chain_parent = updated_set.chain_parent;
            assert(self.chain_parent != null);
        } else {
            self.chain_parent = null;
        }
    }

    const ParseAndPutRecurseError = Allocator.Error || error{
        SequenceUnbind,
        NoChainParent,
        UnexpectedEndOfInput,
        InvalidChainAction,
    };

    /// Returns the set that was ultimately updated if a binding was
    /// added. Unbind does not return a set since nothing was added.
    fn parseAndPutRecurse(
        root: *Set,
        set: *Set,
        alloc: Allocator,
        it: *Parser,
    ) ParseAndPutRecurseError!?*Set {
        const elem = (it.next() catch unreachable) orelse
            return error.UnexpectedEndOfInput;
        switch (elem) {
            .leader => |t| {
                // If we have a leader, we need to upsert a set for it.
                // Since we remove the value, we need to copy it.
                const old: ?Value = if (set.get(t)) |entry|
                    entry.value_ptr.*
                else
                    null;
                if (old) |entry| switch (entry) {
                    // We have an existing leader for this key already
                    // so recurse into this set.
                    .leader => |s| return root.parseAndPutRecurse(
                        s,
                        alloc,
                        it,
                    ) catch |err| switch (err) {
                        // Our child put unbound. If our set is empty we
                        // need to dealloc and continue up. If our set is
                        // not empty then we're done.
                        error.SequenceUnbind => if (s.bindings.count() == 0) {
                            set.remove(alloc, t);
                            return error.SequenceUnbind;
                        } else null,

                        error.NoChainParent,
                        error.UnexpectedEndOfInput,
                        error.InvalidChainAction,
                        error.OutOfMemory,
                        => err,
                    },

                    .leaf, .leaf_chained => {
                        // Remove the existing action. Fallthrough as if
                        // we don't have a leader.
                        set.remove(alloc, t);
                    },
                };

                // Create our new set for this leader
                const next = try alloc.create(Set);
                errdefer alloc.destroy(next);
                next.* = .{};
                errdefer next.deinit(alloc);

                // Insert the leader entry
                try set.bindings.put(alloc, t, .{ .leader = next });

                // Recurse
                return root.parseAndPutRecurse(next, alloc, it) catch |err| switch (err) {
                    // If our action was to unbind, we restore the old
                    // action if we have it.
                    error.SequenceUnbind => {
                        set.remove(alloc, t);
                        if (old) |entry| switch (entry) {
                            .leader => unreachable, // Handled above
                            .leaf => |leaf| set.putFlags(
                                alloc,
                                t,
                                leaf.action,
                                leaf.flags,
                            ) catch {},

                            .leaf_chained => |leaf| chain: {
                                // Rebuild our chain
                                set.putFlags(
                                    alloc,
                                    t,
                                    leaf.actions.items[0],
                                    leaf.flags,
                                ) catch break :chain;
                                for (leaf.actions.items[1..]) |action| {
                                    set.appendChain(
                                        alloc,
                                        action,
                                    ) catch {
                                        set.remove(alloc, t);
                                        break :chain;
                                    };
                                }
                            },
                        };

                        return null;
                    },

                    error.NoChainParent,
                    error.UnexpectedEndOfInput,
                    error.InvalidChainAction,
                    error.OutOfMemory,
                    => return err,
                };
            },

            .binding => |b| switch (b.action) {
                .unbind => {
                    set.remove(alloc, b.trigger);
                    return error.SequenceUnbind;
                },

                else => {
                    try set.putFlags(
                        alloc,
                        b.trigger,
                        b.action,
                        b.flags,
                    );
                    return set;
                },
            },

            .chain => |action| {
                // Chains can only happen on the root.
                assert(set == root);
                // Unbind is not valid for chains.
                if (action == .unbind) return error.InvalidChainAction;
                try set.appendChain(alloc, action);
                return set;
            },
        }
    }

    /// Add a binding to the set. If the binding already exists then
    /// this will overwrite it.
    pub fn put(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
    ) Allocator.Error!void {
        try self.putFlags(alloc, t, action, .{});
    }

    /// Add a binding to the set with explicit flags.
    pub fn putFlags(
        self: *Set,
        alloc: Allocator,
        t: Trigger,
        action: Action,
        flags: Flags,
    ) Allocator.Error!void {
        // unbind should never go into the set, it should be handled prior
        assert(action != .unbind);

        // This is true if we're going to track this entry as
        // a reverse mapping. There are certain scenarios we don't.
        // See the reverse map docs for more information.
        const track_reverse: bool = !flags.performable;

        // No matter what our chained parent becomes invalid because
        // getOrPut invalidates pointers.
        self.chain_parent = null;

        const gop = try self.bindings.getOrPut(alloc, t);
        self.chain_parent = .{
            .key_ptr = gop.key_ptr,
            .value_ptr = gop.value_ptr,
            .set = self,
        };
        errdefer {
            // If we have any errors we can't trust our values here. And
            // we can't restore the old values because they're also invalidated
            // by getOrPut so we just disable chaining.
            self.chain_parent = null;
        }

        if (gop.found_existing) switch (gop.value_ptr.*) {
            // If we have a leader we need to clean up the memory
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },

            // If we have an existing binding for this trigger, we have to
            // update the reverse mapping to remove the old action.
            .leaf => if (track_reverse) {
                const t_hash = t.hash();
                for (0.., self.reverse.values()) |i, *value| {
                    if (t_hash == value.hash()) {
                        self.reverse.swapRemoveAt(i);
                        break;
                    }
                }
            },

            // Chained leaves aren't in the reverse mapping so we just
            // clear it out.
            .leaf_chained => |*l| {
                l.deinit(alloc);
            },
        };

        gop.value_ptr.* = .{ .leaf = .{
            .action = action,
            .flags = flags,
        } };
        errdefer _ = self.bindings.swapRemove(t);

        if (track_reverse) try self.reverse.put(alloc, action, t);
        errdefer if (track_reverse) self.reverse.remove(action);

        // Invariant: after successful put, chain_parent must be valid and point
        // to the entry we just added/updated.
        assert(self.chain_parent != null);
        assert(self.chain_parent.?.key_ptr == gop.key_ptr);
        assert(self.chain_parent.?.value_ptr == gop.value_ptr);
        assert(self.chain_parent.?.value_ptr.* == .leaf);
    }

    /// Append a chained action to the prior set action.
    ///
    /// It is an error if there is no valid prior chain parent.
    pub fn appendChain(
        self: *Set,
        alloc: Allocator,
        action: Action,
    ) (Allocator.Error || error{NoChainParent})!void {
        // Unbind is not a valid chain action; callers must check this.
        assert(action != .unbind);

        const parent = self.chain_parent orelse return error.NoChainParent;
        switch (parent.value_ptr.*) {
            // Leader can never be a chain parent. Verified through various
            // assertions and unit tests.
            .leader => unreachable,

            // If it is already a chained action, we just append the
            // action. Easy!
            .leaf_chained => |*leaf| try leaf.actions.append(
                alloc,
                action,
            ),

            // If it is a leaf, we need to convert it to a leaf_chained.
            // We also need to be careful to remove any prior reverse
            // mappings for this action since chained actions are not
            // part of the reverse mapping.
            .leaf => |leaf| {
                // Setup our failable actions list first.
                var actions: std.ArrayList(Action) = .empty;
                try actions.ensureTotalCapacity(alloc, 2);
                errdefer actions.deinit(alloc);
                actions.appendAssumeCapacity(leaf.action);
                actions.appendAssumeCapacity(action);

                // Convert to leaf_chained first, before fixing up reverse
                // mapping. This is important because fixupReverseForAction
                // searches for other bindings with the same action, and we
                // don't want to find this entry (which is now chained).
                parent.value_ptr.* = .{ .leaf_chained = .{
                    .actions = actions,
                    .flags = leaf.flags,
                } };

                // Clean up our reverse mapping. Chained actions are not
                // part of the reverse mapping, so we need to fix up the
                // reverse map (possibly restoring another trigger for the
                // same action).
                parent.set.fixupReverseForAction(
                    leaf.action,
                    parent.key_ptr.*,
                );
            },
        }
    }

    /// Get a binding for a given trigger.
    pub fn get(self: Set, t: Trigger) ?Entry {
        return self.bindings.getEntry(t);
    }

    /// Get a trigger for the given action. An action can have multiple
    /// triggers so this will return the first one found.
    pub fn getTrigger(self: Set, a: Action) ?Trigger {
        return self.reverse.get(a);
    }

    /// Get an entry for the given key event. This will attempt to find
    /// a binding using multiple parts of the event in the following order:
    ///
    ///   1. Translated key (event.key)
    ///   2. Physical key (event.physical_key)
    ///   3. Unshifted Unicode codepoint (event.unshifted_codepoint)
    ///
    pub fn getEvent(self: *const Set, event: KeyEvent) ?Entry {
        var trigger: Trigger = .{
            .mods = event.mods.binding(),
            .key = .{ .physical = event.key },
        };
        if (self.get(trigger)) |v| return v;

        // If our UTF-8 text is exactly one codepoint, we try to match that.
        if (event.utf8.len > 0) unicode: {
            const view = std.unicode.Utf8View.init(event.utf8) catch break :unicode;
            var it = view.iterator();

            // No codepoints or multiple codepoints drops to invalid format
            const cp = it.nextCodepoint() orelse break :unicode;
            if (it.nextCodepoint() != null) break :unicode;

            trigger.key = .{ .unicode = cp };
            if (self.get(trigger)) |v| return v;
        }

        // Finally fallback to the full unshifted codepoint if we have one.
        // Question: should we be doing this if we have UTF-8 text? I
        // suspect "no" but we don't currently have any failing scenarios
        // to verify this.
        if (event.unshifted_codepoint > 0) {
            trigger.key = .{ .unicode = event.unshifted_codepoint };
            if (self.get(trigger)) |v| return v;
        }

        // Fallback to catch_all with modifiers first, then without modifiers.
        trigger.key = .catch_all;
        if (self.get(trigger)) |v| return v;
        if (!trigger.mods.empty()) {
            trigger.mods = .{};
            if (self.get(trigger)) |v| return v;
        }

        return null;
    }

    /// Remove a binding for a given trigger.
    pub fn remove(self: *Set, alloc: Allocator, t: Trigger) void {
        self.removeExact(alloc, t);
    }

    fn removeExact(self: *Set, alloc: Allocator, t: Trigger) void {
        // Removal always resets our chain parent. We could make this
        // finer grained but the way it is documented is that chaining
        // must happen directly after sets so this works.
        self.chain_parent = null;

        var entry = self.bindings.get(t) orelse return;
        _ = self.bindings.swapRemove(t);

        switch (entry) {
            // For a leader removal, we need to deallocate our child set.
            // Leaders are never part of reverse maps so no other accounting
            // needs to be done.
            .leader => |s| {
                s.deinit(alloc);
                alloc.destroy(s);
            },

            // For an action we need to fix up the reverse mapping.
            .leaf => |leaf| self.fixupReverseForAction(
                leaf.action,
                t,
            ),

            // Chained leaves are never in our reverse mapping so no
            // cleanup is required.
            .leaf_chained => |*l| {
                l.deinit(alloc);
            },
        }
    }

    /// Fix up the reverse mapping after removing an action.
    ///
    /// When an action is removed from a binding (either by removal or by
    /// converting to a chained action), we need to update the reverse mapping.
    /// If another binding has the same action, we update the reverse mapping
    /// to point to that binding. Otherwise, we remove the action from the
    /// reverse mapping entirely.
    ///
    /// The `old` parameter is the trigger that was previously bound to this
    /// action. It is used to check if the reverse mapping still points to
    /// this trigger; if not, no fixup is needed since the reverse map already
    /// points to a different trigger for this action.
    ///
    /// Note: we'd LIKE to replace this with the most recent binding but
    /// our hash map obviously has no concept of ordering so we have to
    /// choose whatever. Maybe a switch to an array hash map here.
    fn fixupReverseForAction(
        self: *Set,
        action: Action,
        old: Trigger,
    ) void {
        const entry = self.reverse.getEntry(action) orelse return;

        // If our value is not the same as the old trigger, we can
        // ignore it because our reverse mapping points somewhere else.
        if (!entry.value_ptr.equal(old)) return;

        // It is the same trigger, so let's now go through our bindings
        // and try to find another trigger that maps to the same action.
        const action_hash = action.hash();
        var it = self.bindings.iterator();
        while (it.next()) |it_entry| {
            switch (it_entry.value_ptr.*) {
                .leader, .leaf_chained => {},
                .leaf => |leaf_search| {
                    if (leaf_search.action.hash() == action_hash) {
                        entry.value_ptr.* = it_entry.key_ptr.*;
                        return;
                    }
                },
            }
        }

        // No other trigger points to this action so we remove
        // the reverse mapping completely.
        _ = self.reverse.swapRemove(action);
    }

    /// Deep clone the set.
    pub fn clone(self: *const Set, alloc: Allocator) !Set {
        var result: Set = .{
            .bindings = try self.bindings.clone(alloc),
            .reverse = try self.reverse.clone(alloc),
        };

        // If we have any leaders we need to clone them.
        {
            var it = result.bindings.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.*) {
                // Leaves could have data to clone (i.e. text actions
                // contain allocated strings).
                .leaf => |*s| s.* = try s.clone(alloc),

                .leaf_chained => |*s| s.* = try s.clone(alloc),

                // Must be deep cloned.
                .leader => |*s| {
                    const ptr = try alloc.create(Set);
                    errdefer alloc.destroy(ptr);
                    ptr.* = try s.*.clone(alloc);
                    errdefer ptr.deinit(alloc);
                    s.* = ptr;
                },
            };
        }

        // We need to clone the action keys in the reverse map since
        // they may contain allocated values.
        for (result.reverse.keys()) |*action| {
            action.* = try action.clone(alloc);
        }

        return result;
    }

    /// The hash map context for the set. This defines how the hash map
    /// gets the hash key and checks for equality.
    fn Context(comptime KeyType: type) type {
        return struct {
            pub fn hash(ctx: @This(), k: KeyType) u32 {
                _ = ctx;
                // This seems crazy at first glance but this is also how
                // the Zig standard library handles hashing for array
                // hash maps!
                return @truncate(k.hash());
            }

            pub fn eql(
                ctx: @This(),
                a: KeyType,
                b: KeyType,
                b_index: usize,
            ) bool {
                _ = ctx;
                _ = b_index;
                return a.bindingSetEqual(b);
            }
        };
    }
};

test "parse: triggers" {
    const testing = std.testing;

    // single character
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = 'a' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("a=ignore"),
    );

    // single modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("ctrl+a=ignore"));

    // multiple modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true, .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+ctrl+a=ignore"));

    // key can come before modifier
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("a+shift=ignore"));

    // physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+key_a=ignore"));

    // unicode keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'ö' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("shift+ö=ignore"));

    // unconsumed keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .consumed = false },
    }, try parseSingle("unconsumed:shift+a=ignore"));

    // unconsumed physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .consumed = false },
    }, try parseSingle("unconsumed:key_a+shift=ignore"));

    // performable keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .performable = true },
    }, try parseSingle("performable:shift+a=ignore"));

    // invalid key
    try testing.expectError(Error.InvalidFormat, parseSingle("foo=ignore"));

    // repeated control
    try testing.expectError(Error.InvalidFormat, parseSingle("shift+shift+a=ignore"));

    // multiple character
    try testing.expectError(Error.InvalidFormat, parseSingle("a+b=ignore"));
}

test "parse: w3c key names" {
    const testing = std.testing;

    // Exact match
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .physical = .key_a } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("KeyA=ignore"),
    );

    // Case-sensitive
    try testing.expectError(Error.InvalidFormat, parseSingle("Keya=ignore"));
}

test "parse: catch_all" {
    const testing = std.testing;

    // Basic catch_all
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .catch_all },
            .action = .{ .ignore = {} },
        },
        try parseSingle("catch_all=ignore"),
    );

    // catch_all with modifiers
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .mods = .{ .ctrl = true },
                .key = .catch_all,
            },
            .action = .{ .ignore = {} },
        },
        try parseSingle("ctrl+catch_all=ignore"),
    );
}

test "parse: plus sign" {
    const testing = std.testing;

    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '+' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("+=ignore"),
    );

    // Modifier
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .key = .{ .unicode = '+' },
                .mods = .{ .ctrl = true },
            },
            .action = .{ .ignore = {} },
        },
        try parseSingle("ctrl++=ignore"),
    );

    try testing.expectError(Error.InvalidFormat, parseSingle("++=ignore"));
}

test "parse: equals sign" {
    const testing = std.testing;

    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '=' } },
            .action = .ignore,
        },
        try parseSingle("==ignore"),
    );

    // Modifier
    try testing.expectEqual(
        Binding{
            .trigger = .{
                .key = .{ .unicode = '=' },
                .mods = .{ .ctrl = true },
            },
            .action = .ignore,
        },
        try parseSingle("ctrl+==ignore"),
    );

    try testing.expectError(Error.InvalidFormat, parseSingle("=ignore"));
}

test "parse: text action equals sign" {
    const testing = std.testing;
    {
        const binding = try parseSingle("==text:=");
        try testing.expectEqual(Trigger{ .key = .{ .unicode = '=' } }, binding.trigger);
        try testing.expectEqualStrings("=", binding.action.text);
    }

    {
        const binding = try parseSingle("==text:=hello");
        try testing.expectEqual(Trigger{ .key = .{ .unicode = '=' } }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }

    {
        const binding = try parseSingle("ctrl+==text:=hello");
        try testing.expectEqual(Trigger{
            .key = .{ .unicode = '=' },
            .mods = .{ .ctrl = true },
        }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }

    {
        const binding = try parseSingle("=+ctrl=text:=hello");
        try testing.expectEqual(Trigger{
            .key = .{ .unicode = '=' },
            .mods = .{ .ctrl = true },
        }, binding.trigger);
        try testing.expectEqualStrings("=hello", binding.action.text);
    }
}

// For Ghostty 1.2+ we changed our key names to match the W3C and removed
// `physical:`. This tests the backwards compatibility with the old format.
// Note that our backwards compatibility isn't 100% perfect since triggers
// like `a` now map to unicode instead of "translated" (which was also
// removed). But we did our best here with what was unambiguous.
test "parse: backwards compatibility with <= 1.1.x" {
    const testing = std.testing;

    // simple, for sanity
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = '0' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("zero=ignore"),
    );
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .physical = .digit_0 } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("physical:zero=ignore"),
    );

    // duplicates
    try testing.expectError(Error.InvalidFormat, parseSingle("zero+one=ignore"));

    // test our full map
    for (
        Trigger.backwards_compatible_keys.keys(),
        Trigger.backwards_compatible_keys.values(),
    ) |k, v| {
        var buf: [128]u8 = undefined;
        try testing.expectEqual(
            Binding{
                .trigger = .{ .key = v },
                .action = .{ .ignore = {} },
            },
            try parseSingle(try std.fmt.bufPrint(&buf, "{s}=ignore", .{k})),
        );
    }
}

test "parse: global triggers" {
    const testing = std.testing;

    // global keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .global = true },
    }, try parseSingle("global:shift+a=ignore"));

    // global physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .global = true },
    }, try parseSingle("global:key_a+shift=ignore"));

    // global unconsumed keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{
            .global = true,
            .consumed = false,
        },
    }, try parseSingle("unconsumed:global:a+shift=ignore"));

    // global sequences not allowed
    {
        var p = try Parser.init("global:a>b=ignore");
        try testing.expectError(Error.InvalidFormat, p.next());
    }
}

test "parse: all triggers" {
    const testing = std.testing;

    // all keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .all = true },
    }, try parseSingle("all:shift+a=ignore"));

    // all physical keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .physical = .key_a },
        },
        .action = .{ .ignore = {} },
        .flags = .{ .all = true },
    }, try parseSingle("all:key_a+shift=ignore"));

    // all unconsumed keys
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .shift = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
        .flags = .{
            .all = true,
            .consumed = false,
        },
    }, try parseSingle("unconsumed:all:a+shift=ignore"));

    // all sequences not allowed
    {
        var p = try Parser.init("all:a>b=ignore");
        try testing.expectError(Error.InvalidFormat, p.next());
    }
}

test "Trigger: equal" {
    const testing = std.testing;

    // Equal physical keys
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        try testing.expect(t1.equal(t2));
    }

    // Different physical keys
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_down }, .mods = .{ .ctrl = true } };
        try testing.expect(!t1.equal(t2));
    }

    // Different mods
    {
        const t1: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true } };
        const t2: Trigger = .{ .key = .{ .physical = .arrow_up }, .mods = .{ .shift = true } };
        try testing.expect(!t1.equal(t2));
    }

    // Equal unicode keys
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        try testing.expect(t1.equal(t2));
    }

    // Different unicode keys
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .unicode = 'b' }, .mods = .{} };
        try testing.expect(!t1.equal(t2));
    }

    // Different key types
    {
        const t1: Trigger = .{ .key = .{ .unicode = 'a' }, .mods = .{} };
        const t2: Trigger = .{ .key = .{ .physical = .key_a }, .mods = .{} };
        try testing.expect(!t1.equal(t2));
    }

    // catch_all
    {
        const t1: Trigger = .{ .key = .catch_all, .mods = .{} };
        const t2: Trigger = .{ .key = .catch_all, .mods = .{} };
        try testing.expect(t1.equal(t2));
    }

    // catch_all with different mods
    {
        const t1: Trigger = .{ .key = .catch_all, .mods = .{} };
        const t2: Trigger = .{ .key = .catch_all, .mods = .{ .alt = true } };
        try testing.expect(!t1.equal(t2));
    }
}

test "parse: modifier aliases" {
    const testing = std.testing;

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("cmd+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .super = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("command+a=ignore"));

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("opt+a=ignore"));
    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .alt = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("option+a=ignore"));

    try testing.expectEqual(Binding{
        .trigger = .{
            .mods = .{ .ctrl = true },
            .key = .{ .unicode = 'a' },
        },
        .action = .{ .ignore = {} },
    }, try parseSingle("control+a=ignore"));
}

test "parse: action invalid" {
    const testing = std.testing;

    // invalid action
    try testing.expectError(Error.InvalidAction, parseSingle("a=nopenopenope"));
}

test "parse: action no parameters" {
    const testing = std.testing;

    // no parameters
    try testing.expectEqual(
        Binding{
            .trigger = .{ .key = .{ .unicode = 'a' } },
            .action = .{ .ignore = {} },
        },
        try parseSingle("a=ignore"),
    );
    try testing.expectError(Error.InvalidFormat, parseSingle("a=ignore:A"));
}

test "parse: action with string" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=csi:A");
        try testing.expect(binding.action == .csi);
        try testing.expectEqualStrings("A", binding.action.csi);
    }
    // parameter
    {
        const binding = try parseSingle("a=esc:A");
        try testing.expect(binding.action == .esc);
        try testing.expectEqualStrings("A", binding.action.esc);
    }
}

test "parse: action with enum" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=new_split:right");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.right, binding.action.new_split);
    }
}

test "parse: action with enum with default" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=new_split");
        try testing.expect(binding.action == .new_split);
        try testing.expectEqual(Action.SplitDirection.auto, binding.action.new_split);
    }
}

test "parse: action with int" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=jump_to_prompt:-1");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, -1), binding.action.jump_to_prompt);
    }
    {
        const binding = try parseSingle("a=jump_to_prompt:10");
        try testing.expect(binding.action == .jump_to_prompt);
        try testing.expectEqual(@as(i16, 10), binding.action.jump_to_prompt);
    }
}

test "parse: action with float" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=scroll_page_fractional:-0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, -0.5), binding.action.scroll_page_fractional);
    }
    {
        const binding = try parseSingle("a=scroll_page_fractional:+0.5");
        try testing.expect(binding.action == .scroll_page_fractional);
        try testing.expectEqual(@as(f32, 0.5), binding.action.scroll_page_fractional);
    }
}

test "parse: action with a tuple" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=resize_split:up,10");
        try testing.expect(binding.action == .resize_split);
        try testing.expectEqual(Action.SplitResizeDirection.up, binding.action.resize_split[0]);
        try testing.expectEqual(@as(u16, 10), binding.action.resize_split[1]);
    }

    // missing parameter
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up"));

    // too many
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up,10,12"));

    // invalid type
    try testing.expectError(Error.InvalidFormat, parseSingle("a=resize_split:up,four"));
}

test "parse: chain" {
    const testing = std.testing;

    // Valid
    {
        var p = try Parser.init("chain=new_tab");
        try testing.expectEqual(Parser.Elem{
            .chain = .new_tab,
        }, try p.next());
        try testing.expect(try p.next() == null);
    }

    // Chain can't have flags
    try testing.expectError(error.InvalidFormat, Parser.init("global:chain=ignore"));

    // Chain can't be part of a sequence
    {
        var p = try Parser.init("a>chain=ignore");
        _ = try p.next();
        try testing.expectError(error.InvalidFormat, p.next());
    }
}

test "sequence iterator" {
    const testing = std.testing;

    // single character
    {
        var it: SequenceIterator = .{ .input = "a" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expect(try it.next() == null);
    }

    // multi character
    {
        var it: SequenceIterator = .{ .input = "a>b" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'b' } }, (try it.next()).?);
        try testing.expect(try it.next() == null);
    }

    // empty
    {
        var it: SequenceIterator = .{ .input = "" };
        try testing.expectError(Error.InvalidFormat, it.next());
    }

    // empty starting sequence
    {
        var it: SequenceIterator = .{ .input = ">a" };
        try testing.expectError(Error.InvalidFormat, it.next());
    }

    // empty ending sequence
    {
        var it: SequenceIterator = .{ .input = "a>" };
        try testing.expectEqual(Trigger{ .key = .{ .unicode = 'a' } }, (try it.next()).?);
        try testing.expectError(Error.InvalidFormat, it.next());
    }
}

test "parse: sequences" {
    const testing = std.testing;

    // single character
    {
        var p = try Parser.init("ctrl+a=ignore");
        try testing.expectEqual(Parser.Elem{ .binding = .{
            .trigger = .{
                .mods = .{ .ctrl = true },
                .key = .{ .unicode = 'a' },
            },
            .action = .{ .ignore = {} },
        } }, (try p.next()).?);
        try testing.expect(try p.next() == null);
    }

    // sequence
    {
        var p = try Parser.init("a>b=ignore");
        try testing.expectEqual(Parser.Elem{ .leader = .{
            .key = .{ .unicode = 'a' },
        } }, (try p.next()).?);
        try testing.expectEqual(Parser.Elem{ .binding = .{
            .trigger = .{
                .key = .{ .unicode = 'b' },
            },
            .action = .{ .ignore = {} },
        } }, (try p.next()).?);
        try testing.expect(try p.next() == null);
    }
}

test "set: parseAndPut typical binding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");

    // Creates forward mapping
    {
        const action = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
        try testing.expectEqual(Flags{}, action.flags);
    }

    // Creates reverse mapping
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // Sets up the chain parent properly
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
}

test "set: parseAndPut unconsumed binding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "unconsumed:a=new_window");

    // Creates forward mapping
    {
        const trigger: Trigger = .{ .key = .{ .unicode = 'a' } };
        const action = s.get(trigger).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
        try testing.expectEqual(Flags{ .consumed = false }, action.flags);
    }

    // Creates reverse mapping
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // Sets up the chain parent properly
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }
}

test "set: parseAndPut removed binding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "a=unbind");

    // Creates forward mapping
    {
        const trigger: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(s.get(trigger) == null);
    }
    try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);

    // Sets up the chain parent properly
    try testing.expect(s.chain_parent == null);
}

test "set: put sets chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });

    // chain_parent should be set
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }

    // chain_parent value should be a leaf
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
}

test "set: putFlags sets chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );

    // chain_parent should be set
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("a", buf.written());
    }

    // chain_parent value should be a leaf with correct flags
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
    try testing.expect(!s.chain_parent.?.value_ptr.*.leaf.flags.consumed);
}

test "set: sequence sets chain_parent to final leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");

    // chain_parent should be set and point to 'b' (the final leaf)
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("b", buf.written());
    }

    // chain_parent value should be a leaf
    try testing.expect(s.chain_parent.?.value_ptr.* == .leaf);
    try testing.expect(s.chain_parent.?.value_ptr.*.leaf.action == .new_window);
}

test "set: multiple leaves under leader updates chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");

    // After first binding, chain_parent should be 'b'
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("b", buf.written());
    }

    try s.parseAndPut(alloc, "a>c=new_tab");

    // After second binding, chain_parent should be updated to 'c'
    try testing.expect(s.chain_parent != null);
    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try s.chain_parent.?.key_ptr.format(&buf.writer);
        try testing.expectEqualStrings("c", buf.written());
    }
    try testing.expect(s.chain_parent.?.value_ptr.*.leaf.action == .new_tab);
}

test "set: sequence unbind clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    try testing.expect(s.chain_parent != null);

    try s.parseAndPut(alloc, "a>b=unbind");

    // After unbind, chain_parent should be cleared
    try testing.expect(s.chain_parent == null);
}

test "set: sequence unbind with remaining leaves clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>c=new_tab");
    try s.parseAndPut(alloc, "a>b=unbind");

    // After unbind, chain_parent should be cleared even though 'c' remains
    try testing.expect(s.chain_parent == null);

    // But 'c' should still exist
    const a_entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(a_entry.value_ptr.* == .leader);
    const inner_set = a_entry.value_ptr.*.leader;
    try testing.expect(inner_set.get(.{ .key = .{ .unicode = 'c' } }) != null);
}

test "set: direct remove clears chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.chain_parent != null);

    s.remove(alloc, .{ .key = .{ .unicode = 'a' } });

    // After removal, chain_parent should be cleared
    try testing.expect(s.chain_parent == null);
}

test "set: invalid format preserves chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    const before_key = s.chain_parent.?.key_ptr;
    const before_value = s.chain_parent.?.value_ptr;

    // Try an invalid parse - should fail
    try testing.expectError(error.InvalidAction, s.parseAndPut(alloc, "a=invalid_action_xyz"));

    // chain_parent should be unchanged
    try testing.expect(s.chain_parent != null);
    try testing.expect(s.chain_parent.?.key_ptr == before_key);
    try testing.expect(s.chain_parent.?.value_ptr == before_value);
}

test "set: clone produces null chain_parent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try testing.expect(s.chain_parent != null);

    var cloned = try s.clone(alloc);
    defer cloned.deinit(alloc);

    // Clone should have null chain_parent
    try testing.expect(cloned.chain_parent == null);

    // But should have the binding
    try testing.expect(cloned.get(.{ .key = .{ .unicode = 'a' } }) != null);
}

test "set: clone with leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    // Create a chained binding using parseAndPut with chain=
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");

    // Verify we have a leaf_chained
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 2), entry.value_ptr.leaf_chained.actions.items.len);

    // Clone the set
    var cloned = try s.clone(alloc);
    defer cloned.deinit(alloc);

    // Verify the cloned set has the leaf_chained with same actions
    const cloned_entry = cloned.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(cloned_entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 2), cloned_entry.value_ptr.leaf_chained.actions.items.len);
    try testing.expect(cloned_entry.value_ptr.leaf_chained.actions.items[0] == .new_window);
    try testing.expect(cloned_entry.value_ptr.leaf_chained.actions.items[1] == .new_tab);
}

test "set: clone with leaf_chained containing allocated data" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var s: Set = .{};

    // Create a chained binding with text actions (which have allocated strings)
    try s.parseAndPut(alloc, "a=text:hello");
    try s.parseAndPut(alloc, "chain=text:world");

    // Verify we have a leaf_chained
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);

    // Clone the set
    const cloned = try s.clone(alloc);

    // Verify the cloned set has independent copies of the text
    const cloned_entry = cloned.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(cloned_entry.value_ptr.* == .leaf_chained);
    try testing.expectEqualStrings("hello", cloned_entry.value_ptr.leaf_chained.actions.items[0].text);
    try testing.expectEqualStrings("world", cloned_entry.value_ptr.leaf_chained.actions.items[1].text);

    // Verify the pointers are different (truly cloned, not shared)
    try testing.expect(entry.value_ptr.leaf_chained.actions.items[0].text.ptr !=
        cloned_entry.value_ptr.leaf_chained.actions.items[0].text.ptr);
}

test "set: parseAndPut sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}

test "set: parseAndPut sequence with two actions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>c=new_tab");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'c' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_tab);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}

test "set: parseAndPut overwrite sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_tab");
    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}

test "set: parseAndPut overwrite leader" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_tab");
    try s.parseAndPut(alloc, "a>b=new_window");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leader);
        current = e.leader;
    }
    {
        const t: Trigger = .{ .key = .{ .unicode = 'b' } };
        const e = current.get(t).?.value_ptr.*;
        try testing.expect(e == .leaf);
        try testing.expect(e.leaf.action == .new_window);
        try testing.expectEqual(Flags{}, e.leaf.flags);
    }
}

test "set: parseAndPut unbind sequence unbinds leader" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "a>b=unbind");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(current.get(t) == null);
    }
}

test "set: parseAndPut unbind sequence unbinds leader if not set" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=unbind");
    var current: *Set = &s;
    {
        const t: Trigger = .{ .key = .{ .unicode = 'a' } };
        try testing.expect(current.get(t) == null);
    }
}

test "set: parseAndPut sequence preserves reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "ctrl+a>b=new_window");

    // Creates reverse mapping
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}

test "set: put overwrites sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "ctrl+a>b=new_window");
    try s.put(alloc, .{
        .mods = .{ .ctrl = true },
        .key = .{ .unicode = 'a' },
    }, .{ .new_window = {} });

    // Creates reverse mapping
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}

test "set: maintains reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // should be most recent
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'b');
    }

    // removal should replace
    s.remove(alloc, .{ .key = .{ .unicode = 'b' } });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}

test "set: performable is not part of reverse mappings" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // trigger should be non-performable
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'b' } },
        .{ .new_window = {} },
        .{ .performable = true },
    );
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // removal of performable should do nothing
    s.remove(alloc, .{ .key = .{ .unicode = 'b' } });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}

test "set: overriding a mapping updates reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }

    // should be most recent
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_tab = {} });
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

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);

    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(!s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.* == .leaf);
    try testing.expect(s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*.leaf.flags.consumed);
}

test "set: parseAndPut chain" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");

    // Creates forward mapping as leaf_chained
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
        try testing.expect(chained.actions.items[0] == .new_window);
        try testing.expect(chained.actions.items[1] == .new_tab);
    }

    // Does not create reverse mapping, because reverse mappings are only for
    // non-chained actions.
    {
        try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);
    }
}

test "set: parseAndPut chain without parent is error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    // Chain without a prior binding should fail
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=new_tab"));
}

test "set: parseAndPut chain multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    try s.parseAndPut(alloc, "chain=close_surface");

    // Should have 3 actions chained
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expectEqual(@as(usize, 3), chained.actions.items.len);
        try testing.expect(chained.actions.items[0] == .new_window);
        try testing.expect(chained.actions.items[1] == .new_tab);
        try testing.expect(chained.actions.items[2] == .close_surface);
    }
}

test "set: parseAndPut chain preserves flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "unconsumed:a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");

    // Should preserve unconsumed flag
    {
        const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
        try testing.expect(entry == .leaf_chained);
        const chained = entry.leaf_chained;
        try testing.expect(!chained.flags.consumed);
        try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    }
}

test "set: parseAndPut chain after unbind is error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "a=unbind");

    // Chain after unbind should fail because chain_parent is cleared
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=new_tab"));
}

test "set: parseAndPut chain on sequence" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a>b=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");

    // Navigate to the inner set
    const a_entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
    try testing.expect(a_entry == .leader);
    const inner_set = a_entry.leader;

    // Check the chained binding
    const b_entry = inner_set.get(.{ .key = .{ .unicode = 'b' } }).?.value_ptr.*;
    try testing.expect(b_entry == .leaf_chained);
    const chained = b_entry.leaf_chained;
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}

test "set: parseAndPut chain with unbind is error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "a=new_window");

    // chain=unbind is not valid
    try testing.expectError(error.InvalidFormat, s.parseAndPut(alloc, "chain=unbind"));

    // Original binding should still exist
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?.value_ptr.*;
    try testing.expect(entry == .leaf);
    try testing.expect(entry.leaf.action == .new_window);
}

test "set: getEvent physical" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "ctrl+quote=new_window");

    // Physical matches on physical
    {
        const action = s.getEvent(.{
            .key = .quote,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }

    // Physical does not match on UTF8/codepoint
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "'",
            .unshifted_codepoint = '\'',
        });
        try testing.expect(action == null);
    }
}

test "set: getEvent codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "ctrl+'=new_window");

    // Matches on codepoint
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = '\'',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }

    // Matches on UTF-8
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "'",
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }

    // Doesn't match on physical
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        });
        try testing.expect(action == null);
    }
}

test "set: getEvent codepoint case folding" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "ctrl+A=new_window");

    // Lowercase codepoint
    {
        const action = s.getEvent(.{
            .key = .key_j,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = 'a',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }

    // Uppercase codepoint
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = 'A',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }

    // Negative case for sanity
    {
        const action = s.getEvent(.{
            .key = .key_j,
            .mods = .{ .ctrl = true },
        });
        try testing.expect(action == null);
    }
}

test "set: getEvent catch_all fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "catch_all=ignore");

    // Matches unbound key without modifiers
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{},
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }

    // Matches unbound key with modifiers (falls back to catch_all without mods)
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }

    // Specific binding takes precedence over catch_all
    try s.parseAndPut(alloc, "ctrl+b=new_window");
    {
        const action = s.getEvent(.{
            .key = .key_b,
            .mods = .{ .ctrl = true },
            .unshifted_codepoint = 'b',
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .new_window);
    }
}

test "set: getEvent catch_all with modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.parseAndPut(alloc, "ctrl+catch_all=close_surface");
    try s.parseAndPut(alloc, "catch_all=ignore");

    // Key with ctrl matches catch_all with ctrl modifier
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .ctrl = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .close_surface);
    }

    // Key without mods matches catch_all without mods
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{},
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }

    // Key with different mods falls back to catch_all without mods
    {
        const action = s.getEvent(.{
            .key = .key_a,
            .mods = .{ .alt = true },
        }).?.value_ptr.*.leaf;
        try testing.expect(action.action == .ignore);
    }
}

test "Action: clone" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var a: Action = .ignore;
        const b = try a.clone(alloc);
        try testing.expect(b == .ignore);
    }

    {
        var a: Action = .{ .text = "foo" };
        const b = try a.clone(alloc);
        try testing.expect(b == .text);
    }
}

test "parse: increase_font_size" {
    const testing = std.testing;

    {
        const binding = try parseSingle("a=increase_font_size:1.5");
        try testing.expect(binding.action == .increase_font_size);
        try testing.expectEqual(1.5, binding.action.increase_font_size);
    }
}

test "parse: decrease_font_size" {
    const testing = std.testing;

    {
        const binding = try parseSingle("a=decrease_font_size:2.5");
        try testing.expect(binding.action == .decrease_font_size);
        try testing.expectEqual(2.5, binding.action.decrease_font_size);
    }
}

test "parse: reset_font_size" {
    const testing = std.testing;

    {
        const binding = try parseSingle("a=reset_font_size");
        try testing.expect(binding.action == .reset_font_size);
    }
}

test "parse: set_font_size" {
    const testing = std.testing;

    {
        const binding = try parseSingle("a=set_font_size:13.5");
        try testing.expect(binding.action == .set_font_size);
        try testing.expectEqual(13.5, binding.action.set_font_size);
    }
}

test "parse: copy to clipboard default" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=copy_to_clipboard");
        try testing.expect(binding.action == .copy_to_clipboard);
        try testing.expectEqual(Action.CopyToClipboard.mixed, binding.action.copy_to_clipboard);
    }
}

test "parse: copy to clipboard explicit" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=copy_to_clipboard:html");
        try testing.expect(binding.action == .copy_to_clipboard);
        try testing.expectEqual(Action.CopyToClipboard.html, binding.action.copy_to_clipboard);
    }
}

test "parse: write screen file no format" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=write_screen_file:copy");
        try testing.expect(binding.action == .write_screen_file);
        try testing.expectEqual(Action.WriteScreen.copy, binding.action.write_screen_file);
    }
}

test "parse: write screen file format" {
    const testing = std.testing;

    // parameter
    {
        const binding = try parseSingle("a=write_screen_file:copy,html");
        try testing.expect(binding.action == .write_screen_file);
        try testing.expectEqual(Action.WriteScreen{
            .action = .copy,
            .emit = .html,
        }, binding.action.write_screen_file);
    }
}

test "parse: write screen file format as string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const binding = try parseSingle("a=write_screen_file:copy,html");
        try binding.action.format(&buf.writer);
        try testing.expectEqualStrings("write_screen_file:copy,html", buf.written());
    }
}

test "parse: write screen file invalid" {
    const testing = std.testing;

    // paramet  r
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:,",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:copy,",
    ));
    try testing.expectError(Error.InvalidFormat, parseSingle(
        "a=write_screen_file:copy,html,extra",
    ));
}

test "action: format" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const a: Action = .{ .text = "👻" };

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try a.format(&buf.writer);
    try testing.expectEqualStrings("text:\\xf0\\x9f\\x91\\xbb", buf.written());
}

test "set: appendChain with no parent returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try testing.expectError(error.NoChainParent, s.appendChain(alloc, .{ .new_tab = {} }));
}

test "set: appendChain after put converts to leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });

    // First appendChain converts leaf to leaf_chained and appends the new action
    try s.appendChain(alloc, .{ .new_tab = {} });

    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);

    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}

test "set: appendChain after putFlags preserves flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .new_window = {} },
        .{ .consumed = false },
    );
    try s.appendChain(alloc, .{ .new_tab = {} });

    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);

    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expect(!chained.flags.consumed);
    try testing.expectEqual(@as(usize, 2), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
}

test "set: appendChain multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try s.appendChain(alloc, .{ .new_tab = {} });
    try s.appendChain(alloc, .{ .close_surface = {} });

    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);

    const chained = entry.value_ptr.*.leaf_chained;
    try testing.expectEqual(@as(usize, 3), chained.actions.items.len);
    try testing.expect(chained.actions.items[0] == .new_window);
    try testing.expect(chained.actions.items[1] == .new_tab);
    try testing.expect(chained.actions.items[2] == .close_surface);
}

test "set: appendChain removes reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });

    // Verify reverse mapping exists before chaining
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);

    // Chaining should remove the reverse mapping
    try s.appendChain(alloc, .{ .new_tab = {} });

    // Reverse mapping should be gone since chained actions are not in reverse map
    try testing.expect(s.getTrigger(.{ .new_window = {} }) == null);
}

test "set: appendChain with performable does not affect reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    // Add a non-performable binding first
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);

    // Add a performable binding (not in reverse map) and chain it
    try s.putFlags(
        alloc,
        .{ .key = .{ .unicode = 'a' } },
        .{ .close_surface = {} },
        .{ .performable = true },
    );

    // close_surface was performable, so not in reverse map
    try testing.expect(s.getTrigger(.{ .close_surface = {} }) == null);

    // Chaining the performable binding should not crash or affect anything
    try s.appendChain(alloc, .{ .new_tab = {} });

    // The non-performable new_window binding should still be in reverse map
    try testing.expect(s.getTrigger(.{ .new_window = {} }) != null);
}

test "set: appendChain restores next valid reverse mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: Set = .{};
    defer s.deinit(alloc);

    // Add two bindings for the same action
    try s.put(alloc, .{ .key = .{ .unicode = 'a' } }, .{ .new_window = {} });
    try s.put(alloc, .{ .key = .{ .unicode = 'b' } }, .{ .new_window = {} });

    // Reverse mapping should point to 'b' (most recent)
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'b');
    }

    // Chain an action to 'b', which should restore 'a' in the reverse map
    try s.appendChain(alloc, .{ .new_tab = {} });

    // Now reverse mapping should point to 'a'
    {
        const trigger = s.getTrigger(.{ .new_window = {} }).?;
        try testing.expect(trigger.key.unicode == 'a');
    }
}

test "set: formatEntries leaf_chained" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");

    var s: Set = .{};
    defer s.deinit(alloc);

    // Create a chained binding
    try s.parseAndPut(alloc, "a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");

    // Verify it's a leaf_chained
    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);

    // Format the entries
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Write the trigger first (as formatEntry in Config.zig does)
    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));

    const expected =
        \\keybind = a=new_window
        \\keybind = chain=new_tab
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}

test "set: formatEntries leaf_chained multiple chains" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");

    var s: Set = .{};
    defer s.deinit(alloc);

    // Create a chained binding with 3 actions
    try s.parseAndPut(alloc, "ctrl+a=new_window");
    try s.parseAndPut(alloc, "chain=new_tab");
    try s.parseAndPut(alloc, "chain=close_surface");

    // Verify it's a leaf_chained with 3 actions
    const entry = s.get(.{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } }).?;
    try testing.expect(entry.value_ptr.* == .leaf_chained);
    try testing.expectEqual(@as(usize, 3), entry.value_ptr.leaf_chained.actions.items.len);

    // Format the entries
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));

    const expected =
        \\keybind = ctrl+a=new_window
        \\keybind = chain=new_tab
        \\keybind = chain=close_surface
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}

test "set: formatEntries leaf_chained with text action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const formatterpkg = @import("../config/formatter.zig");

    var s: Set = .{};
    defer s.deinit(alloc);

    // Create a chained binding with text actions
    try s.parseAndPut(alloc, "a=text:hello");
    try s.parseAndPut(alloc, "chain=text:world");

    // Format the entries
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const entry = s.get(.{ .key = .{ .unicode = 'a' } }).?;
    try entry.key_ptr.format(&writer);
    try entry.value_ptr.formatEntries(&writer, formatterpkg.entryFormatter("keybind", &output.writer));

    const expected =
        \\keybind = a=text:hello
        \\keybind = chain=text:world
        \\
    ;
    try testing.expectEqualStrings(expected, output.written());
}
