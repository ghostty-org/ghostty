const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const cli = @import("../cli.zig");
const internal_os = @import("../os/main.zig");
const formatterpkg = @import("formatter.zig");

const log = std.log.scoped(.config);

pub const ParseError = error{ValueRequired} || Allocator.Error;

/// Path is like a string that represents a path value. The difference is that
/// when loading the configuration the value for this will be automatically
/// expanded relative to the path of the config file (or the home directory).
pub const Path = union(enum) {
    /// No error if the file does not exist.
    optional: [:0]const u8,

    /// The file is required to exist.
    required: [:0]const u8,

    pub fn len(self: Path) usize {
        return switch (self) {
            inline else => |path| path.len,
        };
    }

    pub fn equal(self: Path, other: Path) bool {
        return std.meta.eql(self, other);
    }

    /// Parse the input and return a Path. A leading `?` indicates that the path
    /// is _optional_ and an error should not be logged or displayed to the user
    /// if that path does not exist. Otherwise the path is required and an error
    /// should be logged if the path does not exist.
    pub fn parse(
        /// Allocator to use. This must be an arena allocator because we assume
        /// that any allocations will be cleaned up when the arena.
        arena_alloc: Allocator,
        /// The input.
        input: ?[]const u8,
    ) ParseError!?Path {
        var value = input orelse return error.ValueRequired;

        if (value.len == 0) return null;

        const optional = if (value[0] == '?') opt: {
            value = value[1..];
            break :opt true;
        } else false;

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        if (optional)
            return .{ .optional = try arena_alloc.dupeZ(u8, value) }
        else
            return .{ .required = try arena_alloc.dupeZ(u8, value) };
    }

    /// Parse CLI option.
    pub fn parseCLI(
        /// The path. The value will be overwritten.
        self: *Path,
        /// Allocator to use. This must be an arena allocator because we assume
        /// that any allocations will be cleaned up when the arena.
        arena_alloc: Allocator,
        // The input.
        input: ?[]const u8,
    ) ParseError!void {
        assert(input != null);
        const item = try parse(arena_alloc, input) orelse return;
        if (item.len() == 0) return;
        self.* = item;
    }

    /// Used by formatter.
    pub fn formatEntry(self: *const Path, formatter: anytype) !void {
        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const value = switch (self.*) {
            .optional => |path| std.fmt.bufPrint(
                &buf,
                "?{s}",
                .{path},
            ) catch |err| switch (err) {
                // Required for builds on Linux where NoSpaceLeft
                // isn't an allowed error for fmt.
                error.NoSpaceLeft => return error.OutOfMemory,
            },
            .required => |path| path,
        };

        try formatter.formatEntry([]const u8, value);
    }

    /// Return a clone of the path.
    pub fn clone(
        /// The path to clone.
        self: Path,
        /// This must be an arena allocator because we rely on the arena to
        /// clean up our allocations.
        arena_alloc: Allocator,
    ) Allocator.Error!Path {
        return switch (self) {
            .optional => |path| .{
                .optional = try arena_alloc.dupeZ(u8, path),
            },
            .required => |path| .{
                .required = try arena_alloc.dupeZ(u8, path),
            },
        };
    }

    /// Expand relative paths or paths prefixed with `~/`. The path will be
    /// overwritten.
    pub fn expand(
        /// The path to expand.
        self: *Path,
        /// This must be an arena allocator because we rely on the arena to
        /// clean up our allocations.
        arena_alloc: Allocator,
        /// The base directory to expand relative paths. It must be an absolute
        /// path.
        base: []const u8,
        /// Errors will be added to the list of diagnostics if they occur.
        diags: *cli.DiagnosticList,
    ) !void {
        assert(std.fs.path.isAbsolute(base));

        const path = switch (self.*) {
            .optional, .required => |path| path,
        };

        // If it is already absolute we can ignore it.
        if (path.len == 0 or std.fs.path.isAbsolute(path)) return;

        // If it isn't absolute, we need to make it absolute relative
        // to the base.
        var buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check if the path starts with a tilde and expand it to the
        // home directory on Linux/macOS. We explicitly look for "~/"
        // because we don't support alternate users such as "~alice/"
        if (std.mem.startsWith(u8, path, "~/")) expand: {
            // Windows isn't supported yet
            if (comptime builtin.os.tag == .windows) break :expand;

            const expanded: []const u8 = internal_os.expandHome(
                path,
                &buf,
            ) catch |err| {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintZ(
                        arena_alloc,
                        "error expanding home directory for path {s}: {}",
                        .{ path, err },
                    ),
                });

                // Blank this path so that we don't attempt to resolve it
                // again
                self.* = .{ .required = "" };

                return;
            };

            log.debug(
                "expanding file path from home directory: path={s}",
                .{expanded},
            );

            switch (self.*) {
                .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, expanded),
            }

            return;
        }

        var dir = try std.fs.openDirAbsolute(base, .{});
        defer dir.close();

        const abs = dir.realpath(path, &buf) catch |err| abs: {
            if (err == error.FileNotFound) {
                // The file doesn't exist. Try to resolve the relative path
                // another way.
                const resolved = try std.fs.path.resolve(arena_alloc, &.{ base, path });
                defer arena_alloc.free(resolved);
                @memcpy(buf[0..resolved.len], resolved);
                break :abs buf[0..resolved.len];
            }

            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintZ(
                    arena_alloc,
                    "error resolving file path {s}: {}",
                    .{ path, err },
                ),
            });

            // Blank this path so that we don't attempt to resolve it again
            self.* = .{ .required = "" };

            return;
        };

        log.debug(
            "expanding file path relative={s} abs={s}",
            .{ path, abs },
        );

        switch (self.*) {
            .optional, .required => |*p| p.* = try arena_alloc.dupeZ(u8, abs),
        }
    }

    test "parse" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const Tag = std.meta.Tag(Path);

        {
            const item = (try Path.parse(alloc, "config.1")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("config.1", item.required);
        }

        {
            const item = (try Path.parse(alloc, "?config.2")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("config.2", item.optional);
        }

        {
            const item = (try Path.parse(alloc, "\"?config.3\"")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("?config.3", item.required);
        }

        {
            const item = (try Path.parse(alloc, "?\"config.4\"")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("config.4", item.optional);
        }

        {
            const item = (try Path.parse(alloc, "?")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("", item.optional);
        }

        {
            const item = (try Path.parse(alloc, "\"\"")).?;
            try testing.expectEqual(Tag.required, @as(Tag, item));
            try testing.expectEqualStrings("", item.required);
        }

        {
            const item = (try Path.parse(alloc, "?\"\"")).?;
            try testing.expectEqual(Tag.optional, @as(Tag, item));
            try testing.expectEqualStrings("", item.optional);
        }
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const Tag = std.meta.Tag(Path);
        var item: Path = undefined;

        try item.parseCLI(alloc, "config.1");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("config.1", item.required);

        try item.parseCLI(alloc, "?config.2");
        try testing.expectEqual(Tag.optional, @as(Tag, item));
        try testing.expectEqualStrings("config.2", item.optional);

        try item.parseCLI(alloc, "\"?config.3\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);

        // Zero-length values, ignored

        try item.parseCLI(alloc, "?");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);

        try item.parseCLI(alloc, "\"\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);

        try item.parseCLI(alloc, "?\"\"");
        try testing.expectEqual(Tag.required, @as(Tag, item));
        try testing.expectEqualStrings("?config.3", item.required);
    }

    test "formatConfig single item" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var item: Path = undefined;
        try item.parseCLI(alloc, "A");
        try item.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.items);
    }

    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var item: Path = undefined;
        try item.parseCLI(alloc, "A");
        try item.parseCLI(alloc, "?B");
        try item.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = ?B\n", buf.items);
    }
};

/// RepeatablePath is like repeatable string but represents a path value. The
/// difference is that when loading the configuration any values for this will
/// be automatically expanded relative to the path of the config file (or the home
/// directory).
pub const RepeatablePath = struct {
    value: std.ArrayListUnmanaged(Path) = .{},

    pub fn parseCLI(self: *RepeatablePath, alloc: Allocator, input: ?[]const u8) ParseError!void {
        const item = try Path.parse(alloc, input) orelse {
            self.value.clearRetainingCapacity();
            return;
        };

        if (item.len() == 0) {
            // This handles the case of zero length paths after removing any ?
            // prefixes or surrounding quotes. In this case, we don't reset the
            // list.
            return;
        }

        try self.value.append(alloc, item);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const RepeatablePath, alloc: Allocator) Allocator.Error!RepeatablePath {
        const value = try self.value.clone(alloc);
        for (value.items) |*item| {
            item.* = try item.clone(alloc);
        }

        return .{
            .value = value,
        };
    }

    /// Compare if two of our value are equal. Required by Config.
    pub fn equal(self: RepeatablePath, other: RepeatablePath) bool {
        if (self.value.items.len != other.value.items.len) return false;
        for (self.value.items, other.value.items) |a, b| {
            if (!a.equal(b)) return false;
        }

        return true;
    }

    /// Used by Formatter
    pub fn formatEntry(self: RepeatablePath, formatter: anytype) !void {
        if (self.value.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        for (self.value.items) |item| {
            const value = switch (item) {
                .optional => |path| std.fmt.bufPrint(
                    &buf,
                    "?{s}",
                    .{path},
                ) catch |err| switch (err) {
                    // Required for builds on Linux where NoSpaceLeft
                    // isn't an allowed error for fmt.
                    error.NoSpaceLeft => return error.OutOfMemory,
                },
                .required => |path| path,
            };

            try formatter.formatEntry([]const u8, value);
        }
    }

    /// Expand all the paths relative to the base directory.
    pub fn expand(
        self: *RepeatablePath,
        alloc: Allocator,
        base: []const u8,
        diags: *cli.DiagnosticList,
    ) !void {
        for (self.value.items) |*path| {
            try path.expand(alloc, base, diags);
        }
    }
    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "config.1");
        try list.parseCLI(alloc, "?config.2");
        try list.parseCLI(alloc, "\"?config.3\"");

        try testing.expectEqual(@as(usize, 3), list.value.items.len);

        // Zero-length values, ignored
        try list.parseCLI(alloc, "?");
        try list.parseCLI(alloc, "\"\"");

        try testing.expectEqual(@as(usize, 3), list.value.items.len);

        const Tag = std.meta.Tag(Path);
        try testing.expectEqual(Tag.required, @as(Tag, list.value.items[0]));
        try testing.expectEqualStrings("config.1", list.value.items[0].required);

        try testing.expectEqual(Tag.optional, @as(Tag, list.value.items[1]));
        try testing.expectEqualStrings("config.2", list.value.items[1].optional);

        try testing.expectEqual(Tag.required, @as(Tag, list.value.items[2]));
        try testing.expectEqualStrings("?config.3", list.value.items[2].required);

        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.value.items.len);
    }

    test "formatConfig empty" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var list: RepeatablePath = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
    }

    test "formatConfig single item" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "A");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.items);
    }

    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatablePath = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "?B");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A\na = ?B\n", buf.items);
    }
};
