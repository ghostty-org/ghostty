const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Action = @import("Binding.zig").Action;

/// A command is a named binding action that can be executed from
/// something like a command palette.
///
/// A command must be associated with a binding; all commands can be
/// mapped to traditional `keybind` configurations. This restriction
/// makes it so that there is nothing special about commands and likewise
/// it makes it trivial and consistent to define custom commands.
///
/// For apprt implementers: a command palette doesn't have to make use
/// of all the fields here. We try to provide as much information as
/// possible to make it easier to implement a command palette in the way
/// that makes the most sense for the application.
pub const Command = struct {
    action: Action,
    title: [:0]const u8,
    description: [:0]const u8 = "",

    /// ghostty_command_s
    pub const C = extern struct {
        action_key: [*:0]const u8,
        action: [*:0]const u8,
        title: [*:0]const u8,
        description: [*:0]const u8,
    };

    pub fn clone(self: *const Command, alloc: Allocator) Allocator.Error!Command {
        return .{
            .action = try self.action.clone(alloc),
            .title = try alloc.dupeZ(u8, self.title),
            .description = try alloc.dupeZ(u8, self.description),
        };
    }

    pub fn equal(self: Command, other: Command) bool {
        if (self.action.hash() != other.action.hash()) return false;
        if (!std.mem.eql(u8, self.title, other.title)) return false;
        if (!std.mem.eql(u8, self.description, other.description)) return false;
        return true;
    }

    /// Convert this command to a C struct.
    pub fn comptimeCval(self: Command) C {
        assert(@inComptime());

        return .{
            .action_key = @tagName(self.action),
            .action = std.fmt.comptimePrint("{s}", .{self.action}),
            .title = self.title,
            .description = self.description,
        };
    }

    /// Implements a comparison function for std.mem.sortUnstable
    /// and similar functions. The sorting is defined by Ghostty
    /// to be what we prefer. If a caller wants some other sorting,
    /// they should do it themselves.
    pub fn lessThan(_: void, lhs: Command, rhs: Command) bool {
        return std.ascii.orderIgnoreCase(lhs.title, rhs.title) == .lt;
    }
};

pub const defaults: []const Command = defaults: {
    @setEvalBranchQuota(100_000);

    var count: usize = 0;
    for (@typeInfo(Action.Key).@"enum".fields) |field| {
        const action = @field(Action.Key, field.name);
        count += actionCommands(action).len;
    }

    var result: [count]Command = undefined;
    var i: usize = 0;
    for (@typeInfo(Action.Key).@"enum".fields) |field| {
        const action = @field(Action.Key, field.name);
        const commands = actionCommands(action);
        for (commands) |cmd| {
            result[i] = cmd;
            i += 1;
        }
    }

    std.mem.sortUnstable(Command, &result, {}, Command.lessThan);

    assert(i == count);
    const final = result;
    break :defaults &final;
};

/// Defaults in C-compatible form.
pub const defaultsC: []const Command.C = defaults: {
    var result: [defaults.len]Command.C = undefined;
    for (defaults, 0..) |cmd, i| result[i] = cmd.comptimeCval();
    const final = result;
    break :defaults &final;
};

/// Returns the set of commands associated with this action key by
/// default. Not all actions should have commands. As a general guideline,
/// an action should have a command only if it is useful and reasonable
/// to appear in a command palette.
fn actionCommands(action: Action.Key) []const Command {
    // This is implemented as a function and switch rather than a
    // flat comptime const because we want to ensure we get a compiler
    // error when a new binding is added so that the contributor has
    // to consider whether that new binding should have commands or not.
    const result: []const Command = switch (action) {
        // Note: the use of `comptime` prefix on the return values
        // ensures that the data returned is all in the binary and
        // and not pointing to the stack.

        .reset => comptime &.{.{
            .action = .reset,
            .title = "Reset Terminal",
            .description = "Reset the terminal to a clean state.",
        }},

        .copy_to_clipboard => comptime &.{.{
            .action = .copy_to_clipboard,
            .title = "Copy to Clipboard",
            .description = "Copy the selected text to the clipboard.",
        }},

        .copy_url_to_clipboard => comptime &.{.{
            .action = .copy_url_to_clipboard,
            .title = "Copy URL to Clipboard",
            .description = "Copy the URL under the cursor to the clipboard.",
        }},

        .paste_from_clipboard => comptime &.{.{
            .action = .paste_from_clipboard,
            .title = "Paste from Clipboard",
            .description = "Paste the contents of the main clipboard.",
        }},

        .paste_from_selection => comptime &.{.{
            .action = .paste_from_selection,
            .title = "Paste from Selection",
            .description = "Paste the contents of the selection clipboard.",
        }},

        .increase_font_size => comptime &.{.{
            .action = .{ .increase_font_size = 1 },
            .title = "Increase Font Size",
            .description = "Increase the font size by 1 point.",
        }},

        .decrease_font_size => comptime &.{.{
            .action = .{ .decrease_font_size = 1 },
            .title = "Decrease Font Size",
            .description = "Decrease the font size by 1 point.",
        }},

        .reset_font_size => comptime &.{.{
            .action = .reset_font_size,
            .title = "Reset Font Size",
            .description = "Reset the font size to the default.",
        }},

        .clear_screen => comptime &.{.{
            .action = .clear_screen,
            .title = "Clear Screen",
            .description = "Clear the screen and scrollback.",
        }},

        .select_all => comptime &.{.{
            .action = .select_all,
            .title = "Select All",
            .description = "Select all text on the screen.",
        }},

        .scroll_to_top => comptime &.{.{
            .action = .scroll_to_top,
            .title = "Scroll to Top",
            .description = "Scroll to the top of the screen.",
        }},

        .scroll_to_bottom => comptime &.{.{
            .action = .scroll_to_bottom,
            .title = "Scroll to Bottom",
            .description = "Scroll to the bottom of the screen.",
        }},

        .scroll_to_selection => comptime &.{.{
            .action = .scroll_to_selection,
            .title = "Scroll to Selection",
            .description = "Scroll to the selected text.",
        }},

        .scroll_page_up => comptime &.{.{
            .action = .scroll_page_up,
            .title = "Scroll Page Up",
            .description = "Scroll the screen up by a page.",
        }},

        .scroll_page_down => comptime &.{.{
            .action = .scroll_page_down,
            .title = "Scroll Page Down",
            .description = "Scroll the screen down by a page.",
        }},

        .write_screen_file => comptime &.{
            .{
                .action = .{ .write_screen_file = .copy },
                .title = "Copy Screen to Temporary File and Copy Path",
                .description = "Copy the screen contents to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_screen_file = .paste },
                .title = "Copy Screen to Temporary File and Paste Path",
                .description = "Copy the screen contents to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_screen_file = .open },
                .title = "Copy Screen to Temporary File and Open",
                .description = "Copy the screen contents to a temporary file and open it.",
            },
        },

        .write_selection_file => comptime &.{
            .{
                .action = .{ .write_selection_file = .copy },
                .title = "Copy Selection to Temporary File and Copy Path",
                .description = "Copy the selection contents to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_selection_file = .paste },
                .title = "Copy Selection to Temporary File and Paste Path",
                .description = "Copy the selection contents to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_selection_file = .open },
                .title = "Copy Selection to Temporary File and Open",
                .description = "Copy the selection contents to a temporary file and open it.",
            },
        },

        .new_window => comptime &.{.{
            .action = .new_window,
            .title = "New Window",
            .description = "Open a new window.",
        }},

        .new_tab => comptime &.{.{
            .action = .new_tab,
            .title = "New Tab",
            .description = "Open a new tab.",
        }},

        .move_tab => comptime &.{
            .{
                .action = .{ .move_tab = -1 },
                .title = "Move Tab Left",
                .description = "Move the current tab to the left.",
            },
            .{
                .action = .{ .move_tab = 1 },
                .title = "Move Tab Right",
                .description = "Move the current tab to the right.",
            },
        },

        .toggle_tab_overview => comptime &.{.{
            .action = .toggle_tab_overview,
            .title = "Toggle Tab Overview",
            .description = "Toggle the tab overview.",
        }},

        .prompt_surface_title => comptime &.{.{
            .action = .prompt_surface_title,
            .title = "Change Title...",
            .description = "Prompt for a new title for the current terminal.",
        }},

        .new_split => comptime &.{
            .{
                .action = .{ .new_split = .left },
                .title = "Split Left",
                .description = "Split the terminal to the left.",
            },
            .{
                .action = .{ .new_split = .right },
                .title = "Split Right",
                .description = "Split the terminal to the right.",
            },
            .{
                .action = .{ .new_split = .up },
                .title = "Split Up",
                .description = "Split the terminal up.",
            },
            .{
                .action = .{ .new_split = .down },
                .title = "Split Down",
                .description = "Split the terminal down.",
            },
        },

        .goto_split => comptime &.{
            .{
                .action = .{ .goto_split = .previous },
                .title = "Focus Split: Previous",
                .description = "Focus the previous split, if any.",
            },
            .{
                .action = .{ .goto_split = .next },
                .title = "Focus Split: Next",
                .description = "Focus the next split, if any.",
            },
            .{
                .action = .{ .goto_split = .left },
                .title = "Focus Split: Left",
                .description = "Focus the split to the left, if it exists.",
            },
            .{
                .action = .{ .goto_split = .right },
                .title = "Focus Split: Right",
                .description = "Focus the split to the right, if it exists.",
            },
            .{
                .action = .{ .goto_split = .up },
                .title = "Focus Split: Up",
                .description = "Focus the split above, if it exists.",
            },
            .{
                .action = .{ .goto_split = .down },
                .title = "Focus Split: Down",
                .description = "Focus the split below, if it exists.",
            },
        },

        .toggle_split_zoom => comptime &.{.{
            .action = .toggle_split_zoom,
            .title = "Toggle Split Zoom",
            .description = "Toggle the zoom state of the current split.",
        }},

        .equalize_splits => comptime &.{.{
            .action = .equalize_splits,
            .title = "Equalize Splits",
            .description = "Equalize the size of all splits.",
        }},

        .reset_window_size => comptime &.{.{
            .action = .reset_window_size,
            .title = "Reset Window Size",
            .description = "Reset the window size to the default.",
        }},

        .inspector => comptime &.{.{
            .action = .{ .inspector = .toggle },
            .title = "Toggle Inspector",
            .description = "Toggle the inspector.",
        }},

        .show_gtk_inspector => comptime &.{.{
            .action = .show_gtk_inspector,
            .title = "Show the GTK Inspector",
            .description = "Show the GTK inspector.",
        }},

        .open_config => comptime &.{.{
            .action = .open_config,
            .title = "Open Config",
            .description = "Open the config file.",
        }},

        .reload_config => comptime &.{.{
            .action = .reload_config,
            .title = "Reload Config",
            .description = "Reload the config file.",
        }},

        .close_surface => comptime &.{.{
            .action = .close_surface,
            .title = "Close Terminal",
            .description = "Close the current terminal.",
        }},

        .close_tab => comptime &.{.{
            .action = .close_tab,
            .title = "Close Tab",
            .description = "Close the current tab.",
        }},

        .close_window => comptime &.{.{
            .action = .close_window,
            .title = "Close Window",
            .description = "Close the current window.",
        }},

        .close_all_windows => comptime &.{.{
            .action = .close_all_windows,
            .title = "Close All Windows",
            .description = "Close all windows.",
        }},

        .toggle_maximize => comptime &.{.{
            .action = .toggle_maximize,
            .title = "Toggle Maximize",
            .description = "Toggle the maximized state of the current window.",
        }},

        .toggle_fullscreen => comptime &.{.{
            .action = .toggle_fullscreen,
            .title = "Toggle Fullscreen",
            .description = "Toggle the fullscreen state of the current window.",
        }},

        .toggle_window_decorations => comptime &.{.{
            .action = .toggle_window_decorations,
            .title = "Toggle Window Decorations",
            .description = "Toggle the window decorations.",
        }},

        .toggle_window_float_on_top => comptime &.{.{
            .action = .toggle_window_float_on_top,
            .title = "Toggle Float on Top",
            .description = "Toggle the float on top state of the current window.",
        }},

        .toggle_secure_input => comptime &.{.{
            .action = .toggle_secure_input,
            .title = "Toggle Secure Input",
            .description = "Toggle secure input mode.",
        }},

        .check_for_updates => comptime &.{.{
            .action = .check_for_updates,
            .title = "Check for Updates",
            .description = "Check for updates to the application.",
        }},

        .undo => comptime &.{.{
            .action = .undo,
            .title = "Undo",
            .description = "Undo the last action.",
        }},

        .redo => comptime &.{.{
            .action = .redo,
            .title = "Redo",
            .description = "Redo the last undone action.",
        }},

        .quit => comptime &.{.{
            .action = .quit,
            .title = "Quit",
            .description = "Quit the application.",
        }},

        // No commands because they're parameterized and there
        // aren't obvious values users would use. It is possible that
        // these may have commands in the future if there are very
        // common values that users tend to use.
        .csi,
        .esc,
        .text,
        .cursor_key,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .write_scrollback_file,
        .goto_tab,
        .resize_split,
        .crash,
        => comptime &.{},

        // No commands because I'm not sure they make sense in a command
        // palette context.
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .previous_tab,
        .next_tab,
        .last_tab,
        => comptime &.{},

        // No commands for obvious reasons
        .ignore,
        .unbind,
        => comptime &.{},
    };

    // All generated commands should have the same action as the
    // action passed in.
    for (result) |cmd| assert(cmd.action == action);

    return result;
}

test "command defaults" {
    // This just ensures that defaults is analyzed and works.
    const testing = std.testing;
    try testing.expect(defaults.len > 0);
    try testing.expectEqual(defaults.len, defaultsC.len);
}
