const std = @import("std");

const getenv = @import("env.zig").getenv;
const GetEnvResult = @import("env.zig").GetEnvResult;
const ShellEscapeWriter = @import("shell.zig").ShellEscapeWriter;

const log = std.log.scoped(.os_edit);

const Options = struct {
    default_editor: enum {
        /// Return an error if $EDITOR or $VISUAL is not defined.
        failure,
        /// Default to "vi" if $EDITOR or $VISIAL is not defined.
        vi,
    } = .vi,

    pub const default: Options = .{};
};

pub const Error = error{NoEditorConfigured};

pub fn getConfigEditCommand(alloc: std.mem.Allocator, path: []const u8, options: Options) (Error || std.io.Writer.Error || std.mem.Allocator.Error)![:0]const u8 {
    const editor: []const u8 = editor: {
        // VISUAL vs. EDITOR: https://unix.stackexchange.com/questions/4859/visual-vs-editor-what-s-the-difference
        if (try getenv(alloc, "VISUAL")) |v| {
            defer v.deinit(alloc);
            if (v.value.len > 0) break :editor try alloc.dupe(u8, v.value);
        }

        if (try getenv(alloc, "EDITOR")) |v| {
            defer v.deinit(alloc);
            if (v.value.len > 0) break :editor try alloc.dupe(u8, v.value);
        }

        switch (options.default_editor) {
            .failure => {
                log.warn("$EDITOR or $VISUAL must be set to open config in a new window", .{});
                return error.NoEditorConfigured;
            },
            .vi => {
                log.warn("$EDITOR or $VISUAL not set, falling back to vi", .{});
                break :editor try alloc.dupe(u8, "vi");
            },
        }
    };
    defer alloc.free(editor);

    var buffer: std.io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    const writer = &buffer.writer;

    try writer.writeAll(editor);
    try writer.writeByte(' ');
    {
        var sh: ShellEscapeWriter = .init(writer);
        try sh.writer.writeAll(path);
        try sh.writer.flush();
    }
    try writer.flush();

    return try buffer.toOwnedSliceSentinel(0);
}
