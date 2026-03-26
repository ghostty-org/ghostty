const std = @import("std");
const build_options = @import("terminal_options");
const Terminal = @import("Terminal.zig");

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(Backing) {
    standard = 0, // ctrl+c/v
    selection = 1,
    primary = 2,

    // Our backing isn't as small as we can in Zig, but a full
    // C int if we're binding to C APIs.
    const Backing = switch (build_options.artifact) {
        .lib => if (build_options.c_abi) c_int else u2,
        .ghostty => switch (@import("../build_config.zig").app_runtime) {
            .gtk => c_int,
            else => u2,
        },
    };

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = gtk: {
        switch (build_options.artifact) {
            .ghostty => {},
            .lib => break :gtk void,
        }

        break :gtk switch (@import("../build_config.zig").app_runtime) {
            .gtk => @import("gobject").ext.defineEnum(
                Clipboard,
                .{ .name = "GhosttyClipboard" },
            ),

            .none => void,
        };
    };

    /// Returns the clipboard type for an OSC 52 kind byte,
    /// or null if the byte is unrecognized.
    pub fn fromOSC52Kind(kind: u8) ?Clipboard {
        return switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => null,
        };
    }

    /// Returns the OSC 52 kind byte for this clipboard type.
    pub fn osc52Kind(self: Clipboard) u8 {
        return switch (self) {
            .standard => 'c',
            .selection => 's',
            .primary => 'p',
        };
    }

    /// Encode an OSC 52 clipboard read response sequence.
    ///
    /// Writes the full `ESC ] 52 ; <kind> ; <base64> ESC \` sequence to the
    /// given writer.
    pub fn encodeOSC52Read(
        self: Clipboard,
        writer: *std.Io.Writer,
        data: []const u8,
    ) std.Io.Writer.Error!void {
        try writer.print("\x1b]52;{c};", .{self.osc52Kind()});

        const enc = std.base64.standard.Encoder;
        var buf: [4]u8 = undefined;
        var i: usize = 0;
        while (i < data.len) {
            const chunk_len = @min(data.len - i, 3);
            const encoded = enc.encode(&buf, data[i..][0..chunk_len]);
            try writer.writeAll(encoded);
            i += chunk_len;
        }

        try writer.writeAll("\x1b\\");
    }
};

test "encode OSC 52 read standard" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Clipboard.standard.encodeOSC52Read(&writer, "hello");

    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", writer.buffered());
}

test "encode OSC 52 read selection" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Clipboard.selection.encodeOSC52Read(&writer, "hello");

    try std.testing.expectEqualStrings("\x1b]52;s;aGVsbG8=\x1b\\", writer.buffered());
}

test "encode OSC 52 read primary" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Clipboard.primary.encodeOSC52Read(&writer, "hello");

    try std.testing.expectEqualStrings("\x1b]52;p;aGVsbG8=\x1b\\", writer.buffered());
}

test "encode OSC 52 read empty data" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try Clipboard.standard.encodeOSC52Read(&writer, "");

    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", writer.buffered());
}

pub const PasteOptions = struct {
    /// True if bracketed paste mode is on.
    bracketed: bool,

    /// Return the encoding options based on the current terminal state.
    pub fn fromTerminal(t: *const Terminal) PasteOptions {
        return .{
            .bracketed = t.modes.get(.bracketed_paste),
        };
    }
};

/// Encode the given data for pasting. The resulting value can be written
/// to the pty to perform a paste of the input data.
///
/// The data can be either a `[]u8` or a `[]const u8`. If the data
/// type is const then `PasteError` may be returned. If the data type
/// is mutable then this function can't return an error.
///
/// This slightly complex calling style allows for initially const
/// data to be passed in without an allocation, since it is rare in normal
/// use cases that the data will need to be modified. In the unlikely case
/// data does need to be modified, the caller can make a mutable copy
/// after seeing the error.
///
/// The data is returned as a set of slices to limit allocations. The caller
/// can combine the slices into a single buffer if desired.
///
/// WARNING: The input data is not checked for safety. See the `isPasteSafe`
/// function to check if the data is safe to paste.
pub fn encodePaste(
    data: anytype,
    opts: PasteOptions,
) switch (@TypeOf(data)) {
    []u8 => [3][]const u8,
    []const u8 => PasteError![3][]const u8,
    else => unreachable,
} {
    // These are the set of byte values that are always replaced by
    // a space (per xterm's behavior) for any text insertion method e.g.
    // a paste, drag and drop, etc. These are copied directly from xterm's
    // source.
    const strip: []const u8 = &.{
        0x00, // NUL
        0x08, // BS
        0x05, // ENQ
        0x04, // EOT
        0x1B, // ESC
        0x7F, // DEL

        // These can be overridden by the running terminal program
        // via tcsetattr, so they aren't totally safe to hardcode like
        // this. In practice, I haven't seen modern programs change these
        // and its a much bigger architectural change to pass these through
        // so for now they're hardcoded.
        0x03, // VINTR (Ctrl+C)
        0x1C, // VQUIT (Ctrl+\)
        0x15, // VKILL (Ctrl+U)
        0x1A, // VSUSP (Ctrl+Z)
        0x11, // VSTART (Ctrl+Q)
        0x13, // VSTOP (Ctrl+S)
        0x17, // VWERASE (Ctrl+W)
        0x16, // VLNEXT (Ctrl+V)
        0x12, // VREPRINT (Ctrl+R)
        0x0F, // VDISCARD (Ctrl+O)
    };

    const mutable = @TypeOf(data) == []u8;

    var result: [3][]const u8 = .{ "", data, "" };

    // If we have any of the strip values, then we need to replace them
    // with spaces. This is what xterm does and it does it regardless
    // of bracketed paste mode. This is a security measure to prevent pastes
    // from containing bytes that could be used to inject commands.
    if (std.mem.indexOfAny(u8, data, strip) != null) {
        if (comptime !mutable) return PasteError.MutableRequired;
        var offset: usize = 0;
        while (std.mem.indexOfAny(
            u8,
            data[offset..],
            strip,
        )) |idx| {
            offset += idx;
            data[offset] = ' ';
            offset += 1;
        }
    }

    // Bracketed paste mode (mode 2004) wraps pasted data in
    // fenceposts so that the terminal can ignore things like newlines.
    if (opts.bracketed) {
        result[0] = "\x1b[200~";
        result[2] = "\x1b[201~";
        return result;
    }

    // Non-bracketed. We have to replace newline with `\r`. This matches
    // the behavior of xterm and other terminals. For `\r\n` this will
    // result in `\r\r` which does match xterm.
    if (comptime mutable) {
        std.mem.replaceScalar(u8, data, '\n', '\r');
    } else if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return PasteError.MutableRequired;
    }

    return result;
}

pub const PasteError = error{
    /// Returned if encoding requires a mutable copy of the data. This
    /// can only be returned if the input data type is const.
    MutableRequired,
};

/// Returns true if the data looks safe to paste. Data is considered
/// unsafe if it contains any of the following:
///
/// - `\n`: Newlines can be used to inject commands.
/// - `\x1b[201~`: This is the end of a bracketed paste. This cane be used
///   to exit a bracketed paste and inject commands.
///
/// We consider any scenario unsafe regardless of current terminal state.
/// For example, even if bracketed paste mode is not active, we still
/// consider `\x1b[201~` unsafe. The existence of these types of bytes
/// should raise suspicion that the producer of the paste data is
/// acting strangely.
pub fn isPasteSafe(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\n") == null and
        std.mem.indexOf(u8, data, "\x1b[201~") == null;
}

test isPasteSafe {
    const testing = std.testing;
    try testing.expect(isPasteSafe("hello"));
    try testing.expect(!isPasteSafe("hello\n"));
    try testing.expect(!isPasteSafe("hello\nworld"));
    try testing.expect(!isPasteSafe("he\x1b[201~llo"));
}

test "encodePaste bracketed" {
    const testing = std.testing;
    const result = try encodePaste(
        @as([]const u8, "hello"),
        .{ .bracketed = true },
    );
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encodePaste unbracketed no newlines" {
    const testing = std.testing;
    const result = try encodePaste(
        @as([]const u8, "hello"),
        .{ .bracketed = false },
    );
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encodePaste unbracketed newlines const" {
    const testing = std.testing;
    try testing.expectError(PasteError.MutableRequired, encodePaste(
        @as([]const u8, "hello\nworld"),
        .{ .bracketed = false },
    ));
}

test "encodePaste unbracketed newlines" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encodePaste(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encodePaste unbracketed windows-stye newline" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\r\nworld");
    defer testing.allocator.free(data);
    const result = encodePaste(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\r\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encodePaste strip unsafe bytes const" {
    const testing = std.testing;
    try testing.expectError(PasteError.MutableRequired, encodePaste(
        @as([]const u8, "hello\x00world"),
        .{ .bracketed = true },
    ));
}

test "encodePaste strip unsafe bytes mutable bracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(data);
    const result = encodePaste(data, .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hel lo world", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encodePaste strip unsafe bytes mutable unbracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x03lo");
    defer testing.allocator.free(data);
    const result = encodePaste(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hel lo", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encodePaste strip multiple unsafe bytes" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "\x00\x08\x7f");
    defer testing.allocator.free(data);
    const result = encodePaste(data, .{ .bracketed = true });
    try testing.expectEqualStrings("   ", result[1]);
}
