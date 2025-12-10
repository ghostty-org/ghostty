const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const formatterpkg = @import("formatter.zig");

/// A command to execute (argv0 and args).
///
/// A command is specified as a simple string such as "nvim a b c".
/// By default, we expect the downstream to do some sort of shell expansion
/// on this string.
///
/// If a command is already expanded and the user does NOT want to do
/// shell expansion (because this usually requires a round trip into
/// /bin/sh or equivalent), specify a `direct:`-prefix. e.g.
/// `direct:nvim a b c`.
///
/// The whitespace before or around the prefix is ignored. For example,
/// `  direct:nvim a b c` and `direct: nvim a b c` are equivalent.
///
/// If the command is not absolute, it'll be looked up via the PATH.
/// For the shell-expansion case, we let the shell do this. For the
/// direct case, we do this directly.
pub const Command = union(enum) {
    const Self = @This();

    /// Execute a command directly, e.g. via `exec`. The format here
    /// is already structured to be ready to passed directly to `exec`
    /// with index zero being the command to execute.
    ///
    /// Index zero is not guaranteed to be an absolute path, and may require
    /// PATH lookup. It is up to the downstream to do this, usually via
    /// delegation to something like `execvp`.
    direct: []const [:0]const u8,

    /// Execute a command via shell expansion. This provides the command
    /// as a single string that is expected to be expanded in some way
    /// (up to the downstream). Usually `/bin/sh -c`.
    shell: [:0]const u8,

    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        // Input is required. Whitespace on the edges isn't needed.
        // Commands must be non-empty.
        const input = input_ orelse return error.ValueRequired;
        const trimmed = std.mem.trim(u8, input, " ");
        if (trimmed.len == 0) return error.ValueRequired;

        // If we have a `:` then we MIGHT have a prefix to specify what
        // tag we should use.
        const tag: std.meta.Tag(Self), const str: []const u8 = tag: {
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |idx| {
                const prefix = trimmed[0..idx];
                if (std.mem.eql(u8, prefix, "direct")) {
                    break :tag .{ .direct, trimmed[idx + 1 ..] };
                } else if (std.mem.eql(u8, prefix, "shell")) {
                    break :tag .{ .shell, trimmed[idx + 1 ..] };
                }
            }

            break :tag .{ .shell, trimmed };
        };

        switch (tag) {
            .shell => {
                // We have a shell command, so we can just dupe it.
                const copy = try alloc.dupeZ(u8, std.mem.trim(u8, str, " "));
                self.* = .{ .shell = copy };
            },

            .direct => {
                // We're not shell expanding, so the arguments are naively
                // split on spaces.
                var builder: std.ArrayListUnmanaged([:0]const u8) = .empty;
                var args = std.mem.splitScalar(
                    u8,
                    std.mem.trim(u8, str, " "),
                    ' ',
                );
                while (args.next()) |arg| {
                    const copy = try alloc.dupeZ(u8, arg);
                    try builder.append(alloc, copy);
                }

                self.* = .{ .direct = try builder.toOwnedSlice(alloc) };
            },
        }
    }

    /// Creates a command as a single string, joining arguments as
    /// necessary with spaces. Its not guaranteed that this is a valid
    /// command; it is only meant to be human readable.
    pub fn string(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error![:0]const u8 {
        return switch (self.*) {
            .shell => |v| try alloc.dupeZ(u8, v),
            .direct => |v| try std.mem.joinZ(alloc, " ", v),
        };
    }

    /// Get an iterator over the arguments array. This may allocate
    /// depending on the active tag of the command.
    ///
    /// For direct commands, this is very cheap and just iterates over
    /// the array. There is no allocation.
    ///
    /// For shell commands, this will use Zig's ArgIteratorGeneral as
    /// a best effort shell string parser. This is not guaranteed to be
    /// 100% accurate, but it works for common cases. This requires allocation.
    pub fn argIterator(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!ArgIterator {
        return switch (self.*) {
            .direct => |v| .{ .direct = .{ .args = v } },
            .shell => |v| .{ .shell = try .init(alloc, v) },
        };
    }

    /// Iterates over each argument in the command.
    pub const ArgIterator = union(enum) {
        shell: std.process.ArgIteratorGeneral(.{}),
        direct: struct {
            i: usize = 0,
            args: []const [:0]const u8,
        },

        /// Return the next argument. This may or may not be a copy
        /// depending on the active tag. If you want to ensure that every
        /// argument is a copy, use the `clone` method first.
        pub fn next(self: *ArgIterator) ?[:0]const u8 {
            return switch (self.*) {
                .shell => |*v| v.next(),
                .direct => |*v| {
                    if (v.i >= v.args.len) return null;
                    defer v.i += 1;
                    return v.args[v.i];
                },
            };
        }

        pub fn deinit(self: *ArgIterator) void {
            switch (self.*) {
                .shell => |*v| v.deinit(),
                .direct => {},
            }
        }
    };

    pub fn clone(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        return switch (self.*) {
            .shell => |v| .{ .shell = try alloc.dupeZ(u8, v) },
            .direct => |v| direct: {
                const copy = try alloc.alloc([:0]const u8, v.len);
                for (v, 0..) |arg, i| copy[i] = try alloc.dupeZ(u8, arg);
                break :direct .{ .direct = copy };
            },
        };
    }

    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        switch (self) {
            .shell => |v| try formatter.formatEntry([]const u8, v),

            .direct => |v| {
                var buf: [4096]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buf);
                writer.writeAll("direct:") catch return error.OutOfMemory;
                for (v) |arg| {
                    writer.writeAll(arg) catch return error.OutOfMemory;
                    writer.writeByte(' ') catch return error.OutOfMemory;
                }

                const written = writer.buffered();
                try formatter.formatEntry(
                    []const u8,
                    written[0..@intCast(written.len - 1)],
                );
            },
        }
    }

    test "Command: parseCLI errors" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var v: Self = undefined;
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, null));
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, ""));
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, " "));
    }

    test "Command: parseCLI shell expanded" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var v: Self = undefined;
        try v.parseCLI(alloc, "echo hello");
        try testing.expect(v == .shell);
        try testing.expectEqualStrings(v.shell, "echo hello");

        // Spaces are stripped
        try v.parseCLI(alloc, " echo hello ");
        try testing.expect(v == .shell);
        try testing.expectEqualStrings(v.shell, "echo hello");
    }

    test "Command: parseCLI direct" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var v: Self = undefined;
        try v.parseCLI(alloc, "direct:echo hello");
        try testing.expect(v == .direct);
        try testing.expectEqual(v.direct.len, 2);
        try testing.expectEqualStrings(v.direct[0], "echo");
        try testing.expectEqualStrings(v.direct[1], "hello");

        // Spaces around the prefix
        try v.parseCLI(alloc, " direct:  echo hello");
        try testing.expect(v == .direct);
        try testing.expectEqual(v.direct.len, 2);
        try testing.expectEqualStrings(v.direct[0], "echo");
        try testing.expectEqualStrings(v.direct[1], "hello");
    }

    test "Command: argIterator shell" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var v: Self = .{ .shell = "echo hello world" };
        var it = try v.argIterator(alloc);
        defer it.deinit();

        try testing.expectEqualStrings(it.next().?, "echo");
        try testing.expectEqualStrings(it.next().?, "hello");
        try testing.expectEqualStrings(it.next().?, "world");
        try testing.expect(it.next() == null);
    }

    test "Command: argIterator direct" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var v: Self = .{ .direct = &.{ "echo", "hello world" } };
        var it = try v.argIterator(alloc);
        defer it.deinit();

        try testing.expectEqualStrings(it.next().?, "echo");
        try testing.expectEqualStrings(it.next().?, "hello world");
        try testing.expect(it.next() == null);
    }

    test "Command: string shell" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var v: Self = .{ .shell = "echo hello world" };
        const str = try v.string(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings(str, "echo hello world");
    }

    test "Command: string direct" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var v: Self = .{ .direct = &.{ "echo", "hello world" } };
        const str = try v.string(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings(str, "echo hello world");
    }

    test "Command: formatConfig shell" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();

        var v: Self = undefined;
        try v.parseCLI(alloc, "echo hello");
        try v.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = echo hello\n", buf.written());
    }

    test "Command: formatConfig direct" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();

        var v: Self = undefined;
        try v.parseCLI(alloc, "direct: echo hello");
        try v.formatEntry(formatterpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = direct:echo hello\n", buf.written());
    }
};

test {
    _ = Command;
}
