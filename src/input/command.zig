const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
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

    /// Convert this command to a C struct at comptime.
    pub fn comptimeCval(self: Command) C {
        assert(@inComptime());

        return .{
            .action_key = @tagName(self.action),
            .action = std.fmt.comptimePrint("{f}", .{self.action}),
            .title = self.title,
            .description = self.description,
        };
    }

    /// Convert this command to a C struct at runtime.
    ///
    /// This shares memory with the original command.
    ///
    /// The action string is allocated using the provided allocator. You can
    /// free the slice directly if you need to but we recommend an arena
    /// for this.
    pub fn cval(self: Command, alloc: Allocator) Allocator.Error!C {
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        self.action.format(&buf.writer) catch return error.OutOfMemory;
        const action = try buf.toOwnedSliceSentinel(0);

        return .{
            .action_key = @tagName(self.action),
            .action = action.ptr,
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
    @setEvalBranchQuota(100_000);
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

        .copy_to_clipboard => comptime &.{ .{
            .action = .{ .copy_to_clipboard = .mixed },
            .title = "Copy to Clipboard",
            .description = "Copy the selected text to the clipboard in both plain and styled formats.",
        }, .{
            .action = .{ .copy_to_clipboard = .plain },
            .title = "Copy Selection as Plain Text to Clipboard",
            .description = "Copy the selected text as plain text to the clipboard.",
        }, .{
            .action = .{ .copy_to_clipboard = .vt },
            .title = "Copy Selection as ANSI Sequences to Clipboard",
            .description = "Copy the selected text as ANSI escape sequences to the clipboard.",
        }, .{
            .action = .{ .copy_to_clipboard = .html },
            .title = "Copy Selection as HTML to Clipboard",
            .description = "Copy the selected text as HTML to the clipboard.",
        } },

        .copy_url_to_clipboard => comptime &.{.{
            .action = .copy_url_to_clipboard,
            .title = "Copy URL to Clipboard",
            .description = "Copy the URL under the cursor to the clipboard.",
        }},

        .copy_title_to_clipboard => comptime &.{.{
            .action = .copy_title_to_clipboard,
            .title = "Copy Terminal Title to Clipboard",
            .description = "Copy the terminal title to the clipboard. If the terminal title is not set this has no effect.",
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

        .start_search => comptime &.{.{
            .action = .start_search,
            .title = "Start Search",
            .description = "Start a search if one isn't already active.",
        }},

        .search_selection => comptime &.{.{
            .action = .search_selection,
            .title = "Search Selection",
            .description = "Start a search for the current text selection.",
        }},

        .end_search => comptime &.{.{
            .action = .end_search,
            .title = "End Search",
            .description = "End the current search if any and hide any GUI elements.",
        }},

        .navigate_search => comptime &.{ .{
            .action = .{ .navigate_search = .next },
            .title = "Next Search Result",
            .description = "Navigate to the next search result, if any.",
        }, .{
            .action = .{ .navigate_search = .previous },
            .title = "Previous Search Result",
            .description = "Navigate to the previous search result, if any.",
        } },

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

            .{
                .action = .{ .write_screen_file = .{
                    .action = .copy,
                    .emit = .html,
                } },
                .title = "Copy Screen as HTML to Temporary File and Copy Path",
                .description = "Copy the screen contents as HTML to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .paste,
                    .emit = .html,
                } },
                .title = "Copy Screen as HTML to Temporary File and Paste Path",
                .description = "Copy the screen contents as HTML to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .open,
                    .emit = .html,
                } },
                .title = "Copy Screen as HTML to Temporary File and Open",
                .description = "Copy the screen contents as HTML to a temporary file and open it.",
            },

            .{
                .action = .{ .write_screen_file = .{
                    .action = .copy,
                    .emit = .vt,
                } },
                .title = "Copy Screen as ANSI Sequences to Temporary File and Copy Path",
                .description = "Copy the screen contents as ANSI escape sequences to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .paste,
                    .emit = .vt,
                } },
                .title = "Copy Screen as ANSI Sequences to Temporary File and Paste Path",
                .description = "Copy the screen contents as ANSI escape sequences to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_screen_file = .{
                    .action = .open,
                    .emit = .vt,
                } },
                .title = "Copy Screen as ANSI Sequences to Temporary File and Open",
                .description = "Copy the screen contents as ANSI escape sequences to a temporary file and open it.",
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

            .{
                .action = .{ .write_selection_file = .{
                    .action = .copy,
                    .emit = .html,
                } },
                .title = "Copy Selection as HTML to Temporary File and Copy Path",
                .description = "Copy the selection contents as HTML to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .paste,
                    .emit = .html,
                } },
                .title = "Copy Selection as HTML to Temporary File and Paste Path",
                .description = "Copy the selection contents as HTML to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .open,
                    .emit = .html,
                } },
                .title = "Copy Selection as HTML to Temporary File and Open",
                .description = "Copy the selection contents as HTML to a temporary file and open it.",
            },

            .{
                .action = .{ .write_selection_file = .{
                    .action = .copy,
                    .emit = .vt,
                } },
                .title = "Copy Selection as ANSI Sequences to Temporary File and Copy Path",
                .description = "Copy the selection contents as ANSI escape sequences to a temporary file and copy the path to the clipboard.",
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .paste,
                    .emit = .vt,
                } },
                .title = "Copy Selection as ANSI Sequences to Temporary File and Paste Path",
                .description = "Copy the selection contents as ANSI escape sequences to a temporary file and paste the path to the file.",
            },
            .{
                .action = .{ .write_selection_file = .{
                    .action = .open,
                    .emit = .vt,
                } },
                .title = "Copy Selection as ANSI Sequences to Temporary File and Open",
                .description = "Copy the selection contents as ANSI escape sequences to a temporary file and open it.",
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
            .title = "Change Terminal Title…",
            .description = "Prompt for a new title for the current terminal.",
        }},

        .prompt_tab_title => comptime &.{.{
            .action = .prompt_tab_title,
            .title = "Change Tab Title…",
            .description = "Prompt for a new title for the current tab.",
        }},

        .prompt_window_title => comptime &.{.{
            .action = .prompt_window_title,
            .title = "Change Window Title…",
            .description = "Prompt for a new title for the current window.",
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

        .goto_window => comptime &.{
            .{
                .action = .{ .goto_window = .previous },
                .title = "Focus Window: Previous",
                .description = "Focus the previous window, if any.",
            },
            .{
                .action = .{ .goto_window = .next },
                .title = "Focus Window: Next",
                .description = "Focus the next window, if any.",
            },
        },

        .toggle_split_zoom => comptime &.{.{
            .action = .toggle_split_zoom,
            .title = "Toggle Split Zoom",
            .description = "Toggle the zoom state of the current split.",
        }},

        .toggle_readonly => comptime &.{.{
            .action = .toggle_readonly,
            .title = "Toggle Read-Only Mode",
            .description = "Toggle read-only mode for the current surface.",
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

        .show_on_screen_keyboard => comptime &.{.{
            .action = .show_on_screen_keyboard,
            .title = "Show On-Screen Keyboard",
            .description = "Show the on-screen keyboard if present.",
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

        .close_tab => comptime &.{
            .{
                .action = .{ .close_tab = .this },
                .title = "Close Tab",
                .description = "Close the current tab.",
            },
            .{
                .action = .{ .close_tab = .other },
                .title = "Close Other Tabs",
                .description = "Close all tabs in this window except the current one.",
            },
            .{
                .action = .{ .close_tab = .right },
                .title = "Close Tabs to the Right",
                .description = "Close all tabs to the right of the current one.",
            },
        },

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

        .toggle_mouse_reporting => comptime &.{.{
            .action = .toggle_mouse_reporting,
            .title = "Toggle Mouse Reporting",
            .description = "Toggle whether mouse events are reported to terminal applications.",
        }},

        .toggle_background_opacity => comptime &.{.{
            .action = .toggle_background_opacity,
            .title = "Toggle Background Opacity",
            .description = "Toggle the background opacity of a window that started transparent.",
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

        .text => comptime &.{.{
            .action = .{ .text = "👻" },
            .title = "Ghostty",
            .description = "Put a little Ghostty in your terminal.",
        }},

        // No commands because they're parameterized and there
        // aren't obvious values users would use. It is possible that
        // these may have commands in the future if there are very
        // common values that users tend to use.
        .csi,
        .esc,
        .cursor_key,
        .set_font_size,
        .search,
        .scroll_to_row,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .write_scrollback_file,
        .goto_tab,
        .resize_split,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .end_key_sequence,
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
