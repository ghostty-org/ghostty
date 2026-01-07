const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const cli = @import("../cli.zig");
const internal_os = @import("../os/main.zig");
const formatterpkg = @import("formatter.zig");

const log = std.log.scoped(.config);

pub const ParseError = error{ValueRequired} || Allocator.Error;

/// Working directory configuration. Can be a special value (home, inherit)
/// or a specific path.
pub const WorkingDirectory = union(enum) {
    const Self = @This();

    /// Use the user's home directory (resolved at finalize time)
    home,

    /// Inherit from the launching process (null at runtime)
    inherit,

    /// A specific directory path
    path: [:0]const u8,

    /// Parse the input and return a WorkingDirectory. A value of "home"
    /// maps to `.home`, "inherit" maps to `.inherit`, and any other value
    /// maps to `.path`.
    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input: ?[]const u8,
    ) ParseError!void {
        const value = input orelse return error.ValueRequired;
        const trimmed = std.mem.trim(u8, value, " \n\t");
        if (trimmed.len == 0) return error.ValueRequired;

        if (std.mem.eql(u8, trimmed, "home")) {
            self.* = .home;
        } else if (std.mem.eql(u8, trimmed, "~")) {
            self.* = .home;
        } else if (std.mem.eql(u8, trimmed, "inherit")) {
            self.* = .inherit;
        } else {
            self.* = .{ .path = try alloc.dupeZ(u8, trimmed) };
        }
    }

    /// Expand tilde paths in the `.path` variant. Other variants are unchanged.
    pub fn expand(
        self: *Self,
        arena_alloc: Allocator,
        diags: *cli.DiagnosticList,
    ) !void {
        switch (self.*) {
            .home, .inherit => return,
            .path => |p| {
                // If it's already absolute, we can ignore it
                if (p.len == 0 or std.fs.path.isAbsolute(p)) return;

                // Check if it starts with ~/ and expand it
                if (std.mem.startsWith(u8, p, "~/")) expand: {
                    // Windows isn't supported yet
                    if (comptime builtin.os.tag == .windows) break :expand;

                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const expanded = internal_os.expandHome(p, &buf) catch |err| {
                        try diags.append(arena_alloc, .{
                            .message = try std.fmt.allocPrintSentinel(
                                arena_alloc,
                                "error expanding home directory for working-directory {s}: {}",
                                .{ p, err },
                                0,
                            ),
                        });
                        break :expand;
                    };

                    log.debug(
                        "expanding working-directory from home directory: path={s}",
                        .{expanded},
                    );

                    self.* = .{ .path = try arena_alloc.dupeZ(u8, expanded) };
                }
            },
        }
    }

    /// Used by formatter.
    pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
        const value: []const u8 = switch (self) {
            .home => "home",
            .inherit => "inherit",
            .path => |p| p,
        };
        try formatter.formatEntry([]const u8, value);
    }

    /// Return a clone of the working directory.
    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .home => .home,
            .inherit => .inherit,
            .path => |p| .{ .path = try alloc.dupeZ(u8, p) },
        };
    }

    /// Compare if two working directories are equal.
    pub fn equal(self: Self, other: Self) bool {
        return switch (self) {
            .home => other == .home,
            .inherit => other == .inherit,
            .path => |p| switch (other) {
                .path => |op| std.mem.eql(u8, p, op),
                else => false,
            },
        };
    }

    /// Returns the resolved path string, or null for special values.
    /// Note: `.home` returns null here because it needs to be resolved
    /// during finalize. Use the resolved value after finalize.
    pub fn resolved(self: Self) ?[]const u8 {
        return switch (self) {
            .home, .inherit => null,
            .path => |p| p,
        };
    }

    test "parseCLI: home" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "home");
        try testing.expect(wd == .home);
    }

    test "parseCLI: inherit" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "inherit");
        try testing.expect(wd == .inherit);
    }

    test "parseCLI: path" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "/usr/local");
        try testing.expect(wd == .path);
        try testing.expectEqualStrings(wd.path, "/usr/local");
    }

    test "parseCLI: tilde" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "~");
        try testing.expect(wd == .home);
    }

    test "parseCLI: tilde path" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "~/dev");
        try testing.expect(wd == .path);
        try testing.expectEqualStrings(wd.path, "~/dev");
    }

    test "parseCLI: path with spaces" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try wd.parseCLI(alloc, "/path with spaces");
        try testing.expect(wd == .path);
        try testing.expectEqualStrings(wd.path, "/path with spaces");
    }

    test "parseCLI: null input" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try testing.expectError(error.ValueRequired, wd.parseCLI(alloc, null));
    }

    test "parseCLI: empty string" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = undefined;
        try testing.expectError(error.ValueRequired, wd.parseCLI(alloc, ""));
        try testing.expectError(error.ValueRequired, wd.parseCLI(alloc, "   "));
    }

    test "expand: tilde path" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

        var wd: Self = .{ .path = try alloc.dupeZ(u8, "~/Downloads") };
        var diags = cli.DiagnosticList{};

        try wd.expand(alloc, &diags);
        try testing.expect(wd == .path);
        try testing.expect(std.fs.path.isAbsolute(wd.path));
        try testing.expect(std.mem.endsWith(u8, wd.path, "/Downloads"));
    }

    test "expand: home unchanged" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = .home;
        var diags = cli.DiagnosticList{};

        try wd.expand(alloc, &diags);
        try testing.expect(wd == .home);
    }

    test "expand: inherit unchanged" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var wd: Self = .inherit;
        var diags = cli.DiagnosticList{};

        try wd.expand(alloc, &diags);
        try testing.expect(wd == .inherit);
    }

    test "expand: absolute path unchanged" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const original = "/usr/local";
        var wd: Self = .{ .path = try alloc.dupeZ(u8, original) };
        var diags = cli.DiagnosticList{};

        try wd.expand(alloc, &diags);
        try testing.expect(wd == .path);
        try testing.expectEqualStrings(wd.path, original);
    }

    test "formatEntry: home" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        const wd: Self = .home;
        try wd.formatEntry(formatterpkg.entryFormatter("working-directory", &buf.writer));
        try testing.expectEqualSlices(u8, "working-directory = home\n", buf.written());
    }

    test "formatEntry: inherit" {
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        const wd: Self = .inherit;
        try wd.formatEntry(formatterpkg.entryFormatter("working-directory", &buf.writer));
        try testing.expectEqualSlices(u8, "working-directory = inherit\n", buf.written());
    }

    test "formatEntry: path" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();

        const wd: Self = .{ .path = try alloc.dupeZ(u8, "/usr/local") };
        try wd.formatEntry(formatterpkg.entryFormatter("working-directory", &buf.writer));
        try testing.expectEqualSlices(u8, "working-directory = /usr/local\n", buf.written());
    }

    test "formatEntry: round-trip" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const test_cases = [_][]const u8{ "home", "inherit", "/usr/local", "~/dev" };
        for (test_cases) |input| {
            var wd: Self = undefined;
            try wd.parseCLI(alloc, input);

            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try wd.formatEntry(formatterpkg.entryFormatter("wd", &buf.writer));

            const formatted = buf.written();
            const expected = try std.fmt.allocPrint(alloc, "wd = {s}\n", .{input});
            defer alloc.free(expected);
            try testing.expectEqualSlices(u8, expected, formatted);
        }
    }

    test "clone: home" {
        const testing = std.testing;
        const wd: Self = .home;
        const cloned = try wd.clone(testing.allocator);
        try testing.expect(cloned == .home);
    }

    test "clone: inherit" {
        const testing = std.testing;
        const wd: Self = .inherit;
        const cloned = try wd.clone(testing.allocator);
        try testing.expect(cloned == .inherit);
    }

    test "clone: path deep copy" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const original = try alloc.dupeZ(u8, "/usr/local");
        const wd: Self = .{ .path = original };
        const cloned = try wd.clone(alloc);

        try testing.expect(cloned == .path);
        try testing.expectEqualStrings(cloned.path, "/usr/local");
        // Verify it's a different memory location
        try testing.expect(cloned.path.ptr != original.ptr);
    }

    test "equal: home" {
        const testing = std.testing;
        const wd1: Self = .home;
        const wd2: Self = .home;
        try testing.expect(wd1.equal(wd2));
    }

    test "equal: inherit" {
        const testing = std.testing;
        const wd1: Self = .inherit;
        const wd2: Self = .inherit;
        try testing.expect(wd1.equal(wd2));
    }

    test "equal: path same" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const wd1: Self = .{ .path = try alloc.dupeZ(u8, "/foo") };
        const wd2: Self = .{ .path = try alloc.dupeZ(u8, "/foo") };
        try testing.expect(wd1.equal(wd2));
    }

    test "equal: path different" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const wd1: Self = .{ .path = try alloc.dupeZ(u8, "/foo") };
        const wd2: Self = .{ .path = try alloc.dupeZ(u8, "/bar") };
        try testing.expect(!wd1.equal(wd2));
    }

    test "equal: different variants" {
        const testing = std.testing;
        const wd1: Self = .home;
        const wd2: Self = .inherit;
        try testing.expect(!wd1.equal(wd2));
    }

    test "equal: path vs home" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const wd1: Self = .{ .path = try alloc.dupeZ(u8, "home") };
        const wd2: Self = .home;
        try testing.expect(!wd1.equal(wd2));
    }

    test "resolved: home" {
        const testing = std.testing;
        const wd: Self = .home;
        try testing.expect(wd.resolved() == null);
    }

    test "resolved: inherit" {
        const testing = std.testing;
        const wd: Self = .inherit;
        try testing.expect(wd.resolved() == null);
    }

    test "resolved: path" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const wd: Self = .{ .path = try alloc.dupeZ(u8, "/foo") };
        const resolved_path = wd.resolved();
        try testing.expect(resolved_path != null);
        try testing.expectEqualStrings(resolved_path.?, "/foo");
    }
};
