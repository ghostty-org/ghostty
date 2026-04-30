const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;
const help_strings = @import("help_strings");
const formatter = @import("formatter.zig");

// IMPORTANT: This is in a separate file from formatter.zig because it
// puts a build-time dependency on Config.zig which brings in too much
// into libghostty-vt tests which reference some formattable types.

/// FileFormatter is a formatter implementation that outputs the
/// config in a file-like format. This uses more generous whitespace,
/// can include comments, etc.
pub const FileFormatter = struct {
    alloc: Allocator,
    config: *const Config,

    /// Include comments for documentation of each key
    docs: bool = false,

    /// Only include changed values from the default.
    changed: bool = false,

    /// Implements std.fmt so it can be used directly with std.fmt.
    pub fn format(
        self: FileFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        @setEvalBranchQuota(10_000);

        // If we're change-tracking then we need the default config to
        // compare against.
        var default: ?Config = if (self.changed)
            Config.default(self.alloc) catch return error.WriteFailed
        else
            null;
        defer if (default) |*v| v.deinit();

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (field.name[0] == '_') continue;

            const value = @field(self.config, field.name);
            const do_format = if (default) |d| format: {
                const key = @field(Key, field.name);
                break :format d.changed(self.config, key);
            } else true;

            if (do_format) {
                const do_docs = self.docs and @hasDecl(help_strings.Config, field.name);
                if (do_docs) {
                    const help = @field(help_strings.Config, field.name);
                    var lines = std.mem.splitScalar(u8, help, '\n');
                    while (lines.next()) |line| {
                        try writer.print("# {s}\n", .{line});
                    }
                }

                formatter.formatEntry(
                    field.type,
                    field.name,
                    value,
                    writer,
                ) catch return error.WriteFailed;

                if (do_docs) try writer.print("\n", .{});
            }
        }
    }
};

test "format default config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}

test "format default config changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"font-size" = 42;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
        .changed = true,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}
