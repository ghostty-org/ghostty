//! https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;
const string_encoding = @import("../../../os/string_encoding.zig");

const log = std.log.scoped(.osc_semantic_prompt);

/// A single semantic prompt command.
///
/// Technically according to the spec, not all commands have options
/// but it is easier to be "liberal in what we accept" here since
/// all except one do and the spec does also say to ignore unknown
/// options. So, I think this is a fair interpretation.
pub const Command = struct {
    action: Action,
    options_unvalidated: []const u8,

    pub const Action = enum {
        fresh_line, // 'L'
        fresh_line_new_prompt, // 'A'
        new_command, // 'N'
        prompt_start, // 'P'
        end_prompt_start_input, // 'B'
        end_prompt_start_input_terminate_eol, // 'I'
        end_input_start_output, // 'C'
        end_command, // 'D'
    };

    pub fn init(action: Action) Command {
        return .{
            .action = action,
            .options_unvalidated = "",
        };
    }

    /// Read an option for this command. Returns null if unset or invalid.
    pub fn readOption(
        self: Command,
        comptime option: Option,
    ) ?option.Type() {
        return option.read(self.options_unvalidated);
    }

    /// Write the decoded command line (if any) to the writer. If an error
    /// occurs garbage may have been written to the writer.
    pub fn writeCommandLine(self: Command, writer: *std.Io.Writer) (std.Io.Writer.Error || error{DecodeError})!void {
        if (self.readOption(.cmdline)) |command_line| {
            try string_encoding.printfQDecode(writer, command_line);
            return;
        }
        if (self.readOption(.cmdline_url)) |command_line| {
            try string_encoding.urlPercentDecode(writer, command_line);
            return;
        }
        return;
    }
};

pub const Option = enum {
    aid,
    cl,
    prompt_kind,
    err,
    cmdline,
    cmdline_url,

    // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    // Kitty supports a "redraw" option for prompt_start. This is extended
    // by Ghostty with the "last" option. See Redraw the type for more details.
    redraw,

    // Use a special key instead of arrow keys to move the cursor on
    // mouse click. Useful if arrow keys have side-effets like triggering
    // auto-complete. The shell integration script should bind the special
    // key as needed.
    // See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    special_key,

    // If true, the shell is capable of handling mouse click events.
    // Ghostty will then send a click event to the shell when the user
    // clicks somewhere in the prompt. The shell can then move the cursor
    // to that position or perform some other appropriate action. If false,
    // Ghostty may generate a number of fake key events to move the cursor
    // which is not very robust.
    // See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    click_events,

    // Not technically an option that can be set with k=v and only
    // present currently with command 'D' but its easier to just
    // parse it into our options.
    exit_code,

    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .aid => []const u8,
            .cl => Click,
            .prompt_kind => PromptKind,
            .err => []const u8,
            .redraw => Redraw,
            .special_key => bool,
            .click_events => bool,
            .cmdline => []const u8,
            .cmdline_url => []const u8,
            .exit_code => i32,
        };
    }

    fn key(comptime self: Option) []const u8 {
        return switch (self) {
            .aid => "aid",
            .cl => "cl",
            .prompt_kind => "k",
            .err => "err",
            .redraw => "redraw",
            .special_key => "special_key",
            .click_events => "click_events",
            .cmdline => "cmdline",
            .cmdline_url => "cmdline_url",

            // special case, handled before ever calling key
            .exit_code => unreachable,
        };
    }

    /// Read the option value from the raw options string.
    ///
    /// The raw options string is the raw unparsed data after the
    /// OSC 133 command. e.g. for `133;A;aid=14;cl=line`, the
    /// raw options string would be `aid=14;cl=line`.
    ///
    /// Any errors in the raw string will return null since the OSC133
    /// specification says to ignore unknown or malformed options.
    pub fn read(
        comptime self: Option,
        raw: []const u8,
    ) ?self.Type() {
        var remaining = raw;
        while (remaining.len > 0) {
            // Length of the next value is up to the `;` or the
            // end of the string.
            const len = std.mem.indexOfScalar(
                u8,
                remaining,
                ';',
            ) orelse remaining.len;

            // Grab our full value and move our cursor past the `;`
            const full = remaining[0..len];

            // If we're looking for exit_code we special case it.
            // as the first value.
            if (comptime self == .exit_code) {
                return std.fmt.parseInt(
                    i32,
                    full,
                    10,
                ) catch null;
            }

            // Parse our key=value and verify our key matches our
            // expectation.
            const value = value: {
                if (std.mem.indexOfScalar(
                    u8,
                    full,
                    '=',
                )) |eql_idx| {
                    if (std.mem.eql(
                        u8,
                        full[0..eql_idx],
                        self.key(),
                    )) {
                        break :value full[eql_idx + 1 ..];
                    }
                }

                // No match!
                if (len < remaining.len) {
                    remaining = remaining[len + 1 ..];
                    continue;
                }

                break;
            };

            return switch (self) {
                .aid => value,
                .cl => .init(value),
                .prompt_kind => if (value.len == 1) PromptKind.init(value[0]) else null,
                .err => value,
                .redraw => if (std.mem.eql(u8, value, "0"))
                    .false
                else if (std.mem.eql(u8, value, "1"))
                    .true
                else if (std.mem.eql(u8, value, "last"))
                    .last
                else
                    null,
                .special_key, .click_events => if (value.len == 1) switch (value[0]) {
                    '0' => false,
                    '1' => true,
                    else => null,
                } else null,
                .cmdline => value,
                .cmdline_url => value,
                // Handled above
                .exit_code => unreachable,
            };
        }

        // Not found
        return null;
    }
};

/// The `cl` option specifies what kind of cursor key sequences are handled
/// by the application for click-to-move-cursor functionality.
pub const Click = enum {
    /// Value: "line". Allows motion within a single input line using standard
    /// left/right arrow escape sequences. Only a single left/right sequence
    /// should be emitted for double-width characters.
    line,

    /// Value: "m". Allows movement between different lines in the same group,
    /// but only using left/right arrow escape sequences.
    multiple,

    /// Value: "v". Like `multiple` but cursor up/down should be used. The
    /// terminal should be conservative when moving between lines: move the
    /// cursor left to the start of line, emit the needed up/down sequences,
    /// then move the cursor right to the clicked destination.
    conservative_vertical,

    /// Value: "w". Like `conservative_vertical` but specifies that there are
    /// no spurious spaces at the end of the line, and the application editor
    /// handles "smart vertical movement" (moving 2 lines up from position 20,
    /// where the intermediate line is 15 chars wide and the destination is
    /// 18 chars wide, ends at position 18).
    smart_vertical,

    pub fn init(value: []const u8) ?Click {
        return if (value.len == 1) switch (value[0]) {
            'm' => .multiple,
            'v' => .conservative_vertical,
            'w' => .smart_vertical,
            else => null,
        } else if (std.mem.eql(
            u8,
            value,
            "line",
        )) .line else null;
    }
};

pub const PromptKind = enum {
    initial,
    right,
    continuation,
    secondary,

    pub fn init(c: u8) ?PromptKind {
        return switch (c) {
            'i' => .initial,
            'r' => .right,
            'c' => .continuation,
            's' => .secondary,
            else => null,
        };
    }
};

/// The values for the `redraw` extension to OSC133. This was
/// started by Kitty[1] and extended by Ghostty (the "last" option).
///
/// [1]: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
pub const Redraw = enum(u2) {
    /// The shell supports redrawing the full prompt and all continuations.
    /// This is the default value, it does not need to be explicitly set
    /// unless it is to reset a prior other value.
    true,

    /// The shell does NOT support redrawing. In this case, Ghostty will NOT
    /// clear any prompt lines on resize.
    false,

    /// The shell supports redrawing only the LAST line of the prompt.
    /// Ghostty will only clear the last line of the prompt on resize.
    ///
    /// This is specifically introduced because Bash only redraws the last
    /// line. It is literally the only shell that does this and it does this
    /// because its bad and they should feel bad. Don't be like Bash.
    last,
};

/// Parse OSC 133, semantic prompts
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }

    // All valid cases terminate within this block. Any fallthroughs
    // are invalid. This makes some of our parse logic a little less
    // repetitive.
    valid: {
        switch (data[0]) {
            'A' => fresh_line: {
                parser.command = .{ .semantic_prompt = .init(.fresh_line_new_prompt) };
                if (data.len == 1) break :fresh_line;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'B' => end_prompt: {
                parser.command = .{ .semantic_prompt = .init(.end_prompt_start_input) };
                if (data.len == 1) break :end_prompt;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'I' => end_prompt_line: {
                parser.command = .{ .semantic_prompt = .init(.end_prompt_start_input_terminate_eol) };
                if (data.len == 1) break :end_prompt_line;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'C' => end_input: {
                parser.command = .{ .semantic_prompt = .init(.end_input_start_output) };
                if (data.len == 1) break :end_input;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'D' => end_command: {
                parser.command = .{ .semantic_prompt = .init(.end_command) };
                if (data.len == 1) break :end_command;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'L' => {
                if (data.len > 1) break :valid;
                parser.command = .{ .semantic_prompt = .init(.fresh_line) };
            },

            'N' => new_command: {
                parser.command = .{ .semantic_prompt = .init(.new_command) };
                if (data.len == 1) break :new_command;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'P' => prompt_start: {
                parser.command = .{ .semantic_prompt = .init(.prompt_start) };
                if (data.len == 1) break :prompt_start;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            else => break :valid,
        }

        return &parser.command;
    }

    // Any fallthroughs are invalid
    parser.state = .invalid;
    return null;
}

test "OSC 133: end_input_start_output" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expect(cmd.semantic_prompt.readOption(.aid) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == null);
}

test "OSC 133: end_input_start_output extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Cextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_input_start_output with options" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;C;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: end_input_start_output with cmdline" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline 3" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=echo bobr\\nkurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr\nkurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline 4" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=$'echo bobr kurwa'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline 5" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline='echo bobr kurwa'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline 6" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline='echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline 7" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=$'echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline 8" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=$'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline 9" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline=";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("", w.written());
}

test "OSC 133: end_input_start_output with cmdline_url 1" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline_url 2" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr%20kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline_url 3" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr%3bkurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr;kurwa", w.written());
}

test "OSC 133: end_input_start_output with cmdline_url 4" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr%3kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline_url 5" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr%kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline_url 6" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr kurwa%20";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);

    try cmd.semantic_prompt.writeCommandLine(&w.writer);
    try testing.expectEqualStrings("echo bobr kurwa ", w.written());
}

test "OSC 133: end_input_start_output with cmdline_url 7" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr kurwa%2";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: end_input_start_output with cmdline_url 8" {
    const testing = std.testing;

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();

    var p: Parser = .init(null);
    const input = "133;C;cmdline_url=echo bobr kurwa%";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_input_start_output);
    try testing.expectError(error.DecodeError, cmd.semantic_prompt.writeCommandLine(&w.writer));
}

test "OSC 133: fresh_line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;L";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line);
}

test "OSC 133: fresh_line extra contents" {
    const testing = std.testing;

    // Random
    {
        var p: Parser = .init(null);
        const input = "133;Lol";
        for (input) |ch| p.next(ch);
        try testing.expect(p.end(null) == null);
    }

    // Options
    {
        var p: Parser = .init(null);
        const input = "133;L;aid=foo";
        for (input) |ch| p.next(ch);
        try testing.expect(p.end(null) == null);
    }
}

test "OSC 133: fresh_line_new_prompt" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.aid) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == null);
}

test "OSC 133: fresh_line_new_prompt with aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=14";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expectEqualStrings("14", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: fresh_line_new_prompt with '=' in aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=a=b";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expectEqualStrings("a=b", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: fresh_line_new_prompt with cl=line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == .line);
}

test "OSC 133: fresh_line_new_prompt with cl=m" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=m";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == .multiple);
}

test "OSC 133: fresh_line_new_prompt with invalid cl" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;cl=invalid";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == null);
}

test "OSC 133: fresh_line_new_prompt with trailing ;" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
}

test "OSC 133: fresh_line_new_prompt with bare key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;barekey";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.aid) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == null);
}

test "OSC 133: fresh_line_new_prompt with multiple options" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=foo;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == .line);
}

test "OSC 133: fresh_line_new_prompt default redraw" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.redraw) == null);
}

test "OSC 133: fresh_line_new_prompt with redraw=0" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;redraw=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.redraw).? == .false);
}

test "OSC 133: fresh_line_new_prompt with redraw=1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;redraw=1";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.redraw).? == .true);
}

test "OSC 133: fresh_line_new_prompt with invalid redraw" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;redraw=x";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .fresh_line_new_prompt);
    try testing.expect(cmd.semantic_prompt.readOption(.redraw) == null);
}

test "OSC 133: prompt_start" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == null);
}

test "OSC 133: prompt_start with k=i" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=i";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == .initial);
}

test "OSC 133: prompt_start with k=r" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=r";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == .right);
}

test "OSC 133: prompt_start with k=c" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=c";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == .continuation);
}

test "OSC 133: prompt_start with k=s" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=s";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == .secondary);
}

test "OSC 133: prompt_start with invalid k" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;P;k=x";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .prompt_start);
    try testing.expect(cmd.semantic_prompt.readOption(.prompt_kind) == null);
}

test "OSC 133: prompt_start extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Pextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: new_command" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .new_command);
    try testing.expect(cmd.semantic_prompt.readOption(.aid) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == null);
}

test "OSC 133: new_command with aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .new_command);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: new_command with cl=line" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .new_command);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == .line);
}

test "OSC 133: new_command with multiple options" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;N;aid=foo;cl=line";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .new_command);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
    try testing.expect(cmd.semantic_prompt.readOption(.cl) == .line);
}

test "OSC 133: new_command extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Nextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;B";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_prompt_start_input);
}

test "OSC 133: end_prompt_start_input extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Bextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input with options" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;B;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_prompt_start_input);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: end_prompt_start_input_terminate_eol" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;I";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_prompt_start_input_terminate_eol);
}

test "OSC 133: end_prompt_start_input_terminate_eol extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Iextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_prompt_start_input_terminate_eol with options" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;I;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_prompt_start_input_terminate_eol);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
}

test "OSC 133: end_command" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;D";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_command);
    try testing.expect(cmd.semantic_prompt.readOption(.exit_code) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.aid) == null);
    try testing.expect(cmd.semantic_prompt.readOption(.err) == null);
}

test "OSC 133: end_command extra contents" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "133;Dextra";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 133: end_command with exit code 0" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;D;0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_command);
    try testing.expect(cmd.semantic_prompt.readOption(.exit_code) == 0);
}

test "OSC 133: end_command with exit code and aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;D;12;aid=foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .semantic_prompt);
    try testing.expect(cmd.semantic_prompt.action == .end_command);
    try testing.expectEqualStrings("foo", cmd.semantic_prompt.readOption(.aid).?);
    try testing.expect(cmd.semantic_prompt.readOption(.exit_code) == 12);
}

test "Option.read aid" {
    const testing = std.testing;
    try testing.expectEqualStrings("test123", Option.aid.read("aid=test123").?);
    try testing.expectEqualStrings("myaid", Option.aid.read("cl=line;aid=myaid;k=i").?);
    try testing.expect(Option.aid.read("cl=line;k=i") == null);
    try testing.expectEqualStrings("", Option.aid.read("aid=").?);
    try testing.expectEqualStrings("last", Option.aid.read("k=i;aid=last").?);
    try testing.expectEqualStrings("first", Option.aid.read("aid=first;k=i").?);
    try testing.expect(Option.aid.read("") == null);
    try testing.expect(Option.aid.read("aid") == null);
    try testing.expectEqualStrings("value", Option.aid.read(";;aid=value;;").?);
}

test "Option.read cl" {
    const testing = std.testing;
    try testing.expect(Option.cl.read("cl=line").? == .line);
    try testing.expect(Option.cl.read("cl=m").? == .multiple);
    try testing.expect(Option.cl.read("cl=v").? == .conservative_vertical);
    try testing.expect(Option.cl.read("cl=w").? == .smart_vertical);
    try testing.expect(Option.cl.read("cl=invalid") == null);
    try testing.expect(Option.cl.read("aid=foo") == null);
}

test "Option.read prompt_kind" {
    const testing = std.testing;
    try testing.expect(Option.prompt_kind.read("k=i").? == .initial);
    try testing.expect(Option.prompt_kind.read("k=r").? == .right);
    try testing.expect(Option.prompt_kind.read("k=c").? == .continuation);
    try testing.expect(Option.prompt_kind.read("k=s").? == .secondary);
    try testing.expect(Option.prompt_kind.read("k=x") == null);
    try testing.expect(Option.prompt_kind.read("k=ii") == null);
    try testing.expect(Option.prompt_kind.read("k=") == null);
}

test "Option.read err" {
    const testing = std.testing;
    try testing.expectEqualStrings("some_error", Option.err.read("err=some_error").?);
    try testing.expect(Option.err.read("aid=foo") == null);
}

test "Option.read redraw" {
    const testing = std.testing;
    try testing.expect(Option.redraw.read("redraw=1").? == .true);
    try testing.expect(Option.redraw.read("redraw=0").? == .false);
    try testing.expect(Option.redraw.read("redraw=last").? == .last);
    try testing.expect(Option.redraw.read("redraw=2") == null);
    try testing.expect(Option.redraw.read("redraw=10") == null);
    try testing.expect(Option.redraw.read("redraw=") == null);
}

test "Option.read special_key" {
    const testing = std.testing;
    try testing.expect(Option.special_key.read("special_key=1").? == true);
    try testing.expect(Option.special_key.read("special_key=0").? == false);
    try testing.expect(Option.special_key.read("special_key=x") == null);
}

test "Option.read click_events" {
    const testing = std.testing;
    try testing.expect(Option.click_events.read("click_events=1").? == true);
    try testing.expect(Option.click_events.read("click_events=0").? == false);
    try testing.expect(Option.click_events.read("click_events=yes") == null);
}

test "Option.read exit_code" {
    const testing = std.testing;
    try testing.expect(Option.exit_code.read("42").? == 42);
    try testing.expect(Option.exit_code.read("0").? == 0);
    try testing.expect(Option.exit_code.read("-1").? == -1);
    try testing.expect(Option.exit_code.read("abc") == null);
    try testing.expect(Option.exit_code.read("127;aid=foo").? == 127);
}
