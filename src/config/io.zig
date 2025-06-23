const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const string = @import("string.zig");
const formatterpkg = @import("formatter.zig");
const cli = @import("../cli.zig");

/// ReadableIO is some kind of IO source that is readable.
///
/// It can be either a direct string or a filepath. The filepath will
/// be deferred and read later, so it won't be checked for existence
/// or readability at configuration time. This allows using a path that
/// might be produced in an intermediate state.
pub const ReadableIO = union(enum) {
    const Self = @This();

    raw: [:0]const u8,
    path: [:0]const u8,

    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;

        // We create a buffer only to do string parsing and validate
        // it works. We store the value as raw so that our formatting
        // can recreate it.
        {
            const buf = try alloc.alloc(u8, input.len);
            defer alloc.free(buf);
            _ = try string.parse(buf, input);
        }

        // Next, parse the tagged union using normal rules.
        self.* = cli.args.parseTaggedUnion(
            Self,
            alloc,
            input,
        ) catch |err| switch (err) {
            // Invalid values in the tagged union are interpreted as
            // raw values. This lets users pass in simple string values
            // without needing to tag them.
            error.InvalidValue => .{ .raw = try alloc.dupeZ(u8, input) },
            else => return err,
        };
    }

    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .raw => |v| .{ .raw = try alloc.dupeZ(u8, v) },
            .path => |v| .{ .path = try alloc.dupeZ(u8, v) },
        };
    }

    /// Same as clone but also parses the values as Zig strings in
    /// the final resulting value all at once so we can avoid extra
    /// allocations.
    pub fn cloneParsed(
        self: Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        switch (self) {
            inline else => |v, tag| {
                // Parsing can't fail because we validate it in parseCLI
                const copied = try alloc.dupeZ(u8, v);
                const parsed = string.parse(copied, v) catch unreachable;
                assert(copied.ptr == parsed.ptr);

                // If we parsed less than our original length we need
                // to keep it null-terminated.
                if (parsed.len < copied.len) copied[parsed.len] = 0;

                return @unionInit(
                    Self,
                    @tagName(tag),
                    copied[0..parsed.len :0],
                );
            },
        }
    }

    pub fn equal(self: Self, other: Self) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }

        return switch (self) {
            .raw => |v| std.mem.eql(u8, v, other.raw),
            .path => |v| std.mem.eql(u8, v, other.path),
        };
    }

    pub fn formatEntry(self: Self, formatter: anytype) !void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        switch (self) {
            inline else => |v, tag| {
                writer.writeAll(@tagName(tag)) catch return error.OutOfMemory;
                writer.writeByte(':') catch return error.OutOfMemory;
                writer.writeAll(v) catch return error.OutOfMemory;
            },
        }

        const written = fbs.getWritten();
        try formatter.formatEntry(
            []const u8,
            written,
        );
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "foo");
            try testing.expect(io == .raw);
            try testing.expectEqualStrings("foo", io.raw);
        }
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "raw:foo");
            try testing.expect(io == .raw);
            try testing.expectEqualStrings("foo", io.raw);
        }
        {
            var io: Self = undefined;
            try Self.parseCLI(&io, alloc, "path:foo");
            try testing.expect(io == .path);
            try testing.expectEqualStrings("foo", io.path);
        }
    }

    test "formatEntry" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();

        var v: Self = undefined;
        try v.parseCLI(alloc, "raw:foo");
        try v.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = raw:foo\n", buf.items);
    }
};

pub const RepeatableReadableIO = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged(ReadableIO) = .{},

    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;

        // Empty value resets the list
        if (value.len == 0) {
            self.list.clearRetainingCapacity();
            return;
        }

        var io: ReadableIO = undefined;
        try ReadableIO.parseCLI(&io, alloc, value);
        try self.list.append(alloc, io);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged(ReadableIO).initCapacity(
            alloc,
            self.list.items.len,
        );
        for (self.list.items) |item| {
            const copy = try item.clone(alloc);
            list.appendAssumeCapacity(copy);
        }

        return .{ .list = list };
    }

    /// See ReadableIO.cloneParsed
    pub fn cloneParsed(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        var list = try std.ArrayListUnmanaged(ReadableIO).initCapacity(
            alloc,
            self.list.items.len,
        );
        for (self.list.items) |item| {
            const copy = try item.cloneParsed(alloc);
            list.appendAssumeCapacity(copy);
        }

        return .{ .list = list };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!a.equal(b)) return false;
        } else return true;
    }

    /// Used by Formatter
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        for (self.list.items) |value| {
            try formatter.formatEntry(ReadableIO, value);
        }
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "raw:A");
        try list.parseCLI(alloc, "path:B");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);

        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.list.items.len);
    }
};

test {
    _ = ReadableIO;
    _ = RepeatableReadableIO;
}
