const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const CircBuf = @import("../datastruct/main.zig").CircBuf;
const cimgui = @import("cimgui");

/// Circular buffer of key events.
pub const EventRing = CircBuf(Event, undefined);

/// Represents a recorded keyboard event.
pub const Event = struct {
    /// The input event.
    event: input.KeyEvent,

    /// The binding that was triggered as a result of this event.
    binding: ?input.Binding.Action = null,

    /// The data sent to the pty as a result of this keyboard event.
    /// This is allocated using the inspector allocator.
    pty: []const u8 = "",

    /// State for the inspector GUI. Do not set this unless you're the inspector.
    imgui_state: struct {
        selected: bool = false,
    } = .{},

    pub fn init(alloc: Allocator, event: input.KeyEvent) !Event {
        var copy = event;
        copy.utf8 = "";
        if (event.utf8.len > 0) copy.utf8 = try alloc.dupe(u8, event.utf8);
        return .{ .event = copy };
    }

    pub fn deinit(self: *const Event, alloc: Allocator) void {
        if (self.event.utf8.len > 0) alloc.free(self.event.utf8);
        if (self.pty.len > 0) alloc.free(self.pty);
    }

    /// Returns a label that can be used for this event. This is null-terminated
    /// so it can be easily used with C APIs.
    pub fn label(self: *const Event, buf: []u8) ![:0]const u8 {
        var buf_stream = std.io.fixedBufferStream(buf);
        const writer = buf_stream.writer();

        switch (self.event.action) {
            .press => try writer.writeAll("Press: "),
            .release => try writer.writeAll("Release: "),
            .repeat => try writer.writeAll("Repeat: "),
        }

        if (self.event.mods.shift) try writer.writeAll("Shift+");
        if (self.event.mods.ctrl) try writer.writeAll("Ctrl+");
        if (self.event.mods.alt) try writer.writeAll("Alt+");
        if (self.event.mods.super) try writer.writeAll("Super+");

        // Write our key. If we have an invalid key we attempt to write
        // the utf8 associated with it if we have it to handle non-ascii.
        try writer.writeAll(switch (self.event.key) {
            .unidentified => if (self.event.utf8.len > 0) self.event.utf8 else @tagName(self.event.key),
            else => @tagName(self.event.key),
        });

        // Deadkey
        if (self.event.composing) try writer.writeAll(" (composing)");

        // Null-terminator
        try writer.writeByte(0);
        return buf[0..(buf_stream.getWritten().len - 1) :0];
    }

    /// Render this event in the inspector GUI.
    pub fn render(self: *const Event) void {
        _ = cimgui.c.igBeginTable(
            "##event",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        if (self.binding) |binding| {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Triggered Binding");
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", @tagName(binding).ptr);
        }

        pty: {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Encoding to Pty");
            _ = cimgui.c.igTableSetColumnIndex(1);
            if (self.pty.len == 0) {
                cimgui.c.igTextDisabled("(no data)");
                break :pty;
            }

            self.renderPty() catch {
                cimgui.c.igTextDisabled("(error rendering pty data)");
                break :pty;
            };
        }

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Action");
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", @tagName(self.event.action).ptr);
        }
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Key");
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", @tagName(self.event.key).ptr);
        }
        if (!self.event.mods.empty()) {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Mods");
            _ = cimgui.c.igTableSetColumnIndex(1);
            if (self.event.mods.shift) cimgui.c.igText("shift ");
            if (self.event.mods.ctrl) cimgui.c.igText("ctrl ");
            if (self.event.mods.alt) cimgui.c.igText("alt ");
            if (self.event.mods.super) cimgui.c.igText("super ");
        }
        if (self.event.composing) {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Composing");
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("true");
        }
        utf8: {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("UTF-8");
            _ = cimgui.c.igTableSetColumnIndex(1);
            if (self.event.utf8.len == 0) {
                cimgui.c.igTextDisabled("(empty)");
                break :utf8;
            }

            self.renderUtf8(self.event.utf8) catch {
                cimgui.c.igTextDisabled("(error rendering utf-8)");
                break :utf8;
            };
        }
    }

    fn renderUtf8(self: *const Event, utf8: []const u8) !void {
        _ = self;

        // Format the codepoint sequence
        var buf: [1024]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();
        if (std.unicode.Utf8View.init(utf8)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                try writer.print("U+{X} ", .{cp});
            }
        } else |_| {
            try writer.writeAll("(invalid utf-8)");
        }
        try writer.writeByte(0);

        // Render as a textbox
        _ = cimgui.c.igInputText(
            "##utf8",
            &buf,
            buf_stream.getWritten().len - 1,
            cimgui.c.ImGuiInputTextFlags_ReadOnly,
            null,
            null,
        );
    }

    fn renderPty(self: *const Event) !void {
        // Format the codepoint sequence
        var buf: [1024]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();

        for (self.pty) |byte| {
            // Print ESC special because its so common
            if (byte == 0x1B) {
                try writer.writeAll("ESC ");
                continue;
            }

            // Print ASCII as-is
            if (byte > 0x20 and byte < 0x7F) {
                try writer.writeByte(byte);
                continue;
            }

            // Everything else as a hex byte
            try writer.print("0x{X} ", .{byte});
        }

        try writer.writeByte(0);

        // Render as a textbox
        _ = cimgui.c.igInputText(
            "##pty",
            &buf,
            buf_stream.getWritten().len - 1,
            cimgui.c.ImGuiInputTextFlags_ReadOnly,
            null,
            null,
        );
    }
};

test "event string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var event = try Event.init(alloc, .{ .key = .key_a });
    defer event.deinit(alloc);

    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings("Press: key_a", try event.label(&buf));
}
