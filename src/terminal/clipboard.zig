const std = @import("std");
const build_config = @import("../build_config.zig");
const build_options = @import("terminal_options");

/// The clipboard type.
///
/// If this is changed, you must also update ghostty.h
pub const Clipboard = enum(Backing) {
    standard = 0, // ctrl+c/v
    selection = 1,
    primary = 2,

    // Our backing isn't as small as we can in Zig, but a full
    // C int if we're binding to C APIs.
    const Backing = switch (build_config.app_runtime) {
        .gtk => c_int,
        else => u2,
    };

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = gtk: {
        switch (build_options.artifact) {
            .ghostty => {},
            .lib => break :gtk void,
        }

        break :gtk switch (build_config.app_runtime) {
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
