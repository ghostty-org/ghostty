const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// TODO:
//   - Only `--long=value` format is accepted. Do we want to allow
//     `--long value`? Not currently allowed.

/// Parse the command line arguments from iter into dst.
///
/// dst must be a struct. The fields and their types will be used to determine
/// the valid CLI flags. See the tests in this file as an example. For field
/// types that are structs, the struct can implement the `parseCLI` function
/// to do custom parsing.
///
/// If the destination type has a field "_arena" of type `?ArenaAllocator`,
/// an arena allocator will be created (or reused if set already) for any
/// allocations. Allocations are necessary for certain types, like `[]const u8`.
///
/// Note: If the arena is already non-null, then it will be used. In this
/// case, in the case of an error some memory might be leaked into the arena.
pub fn parse(comptime T: type, alloc: Allocator, dst: *T, iter: anytype) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    // Make an arena for all our allocations if we support it. Otherwise,
    // use an allocator that always fails. If the arena is already set on
    // the config, then we reuse that. See memory note in parse docs.
    var arena_owned: bool = false;
    const arena_alloc = if (@hasField(T, "_arena")) arena: {
        // If the arena is unset, we create it. We mark that we own it
        // only so that we can clean it up on error.
        if (dst._arena == null) {
            dst._arena = ArenaAllocator.init(alloc);
            arena_owned = true;
        }

        break :arena dst._arena.?.allocator();
    } else std.mem.fail_allocator;
    errdefer if (arena_owned) {
        dst._arena.?.deinit();
        dst._arena = null;
    };

    while (iter.next()) |arg| {
        if (mem.startsWith(u8, arg, "--")) {
            var key: []const u8 = arg[2..];
            const value: ?[]const u8 = value: {
                // If the arg has "=" then the value is after the "=".
                if (mem.indexOf(u8, key, "=")) |idx| {
                    defer key = key[0..idx];
                    break :value key[idx + 1 ..];
                }

                break :value null;
            };

            try parseIntoField(T, arena_alloc, dst, key, value);
        }
    }
}

/// Parse a single key/value pair into the destination type T.
///
/// This may result in allocations. The allocations can only be freed by freeing
/// all the memory associated with alloc. It is expected that alloc points to
/// an arena.
fn parseIntoField(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    key: []const u8,
    value: ?[]const u8,
) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    inline for (info.Struct.fields) |field| {
        if (mem.eql(u8, field.name, key)) {
            // For optional fields, we just treat it as the child type.
            // This lets optional fields default to null but get set by
            // the CLI.
            const Field = switch (@typeInfo(field.field_type)) {
                .Optional => |opt| opt.child,
                else => field.field_type,
            };
            const fieldInfo = @typeInfo(Field);

            // If we are a struct and have parseCLI, we call that and use
            // that to set the value.
            if (fieldInfo == .Struct and @hasDecl(Field, "parseCLI")) {
                const fnInfo = @typeInfo(@TypeOf(Field.parseCLI)).Fn;
                switch (fnInfo.args.len) {
                    // 1 arg = (input) => output
                    1 => @field(dst, field.name) = try Field.parseCLI(value),

                    // 2 arg = (self, input) => void
                    2 => try @field(dst, field.name).parseCLI(value),

                    // 3 arg = (self, alloc, input) => void
                    3 => try @field(dst, field.name).parseCLI(alloc, value),

                    else => @compileError("parseCLI invalid argument count"),
                }

                return;
            }

            // No parseCLI, magic the value based on the type
            @field(dst, field.name) = switch (Field) {
                []const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.alloc(u8, slice.len);
                    mem.copy(u8, buf, slice);
                    break :value buf;
                },

                [:0]const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.allocSentinel(u8, slice.len, 0);
                    mem.copy(u8, buf, slice);
                    buf[slice.len] = 0;
                    break :value buf;
                },

                bool => try parseBool(value orelse "t"),

                u8 => try std.fmt.parseInt(
                    u8,
                    value orelse return error.ValueRequired,
                    0,
                ),

                else => unreachable,
            };

            return;
        }
    }

    return error.InvalidFlag;
}

fn parseBool(v: []const u8) !bool {
    const t = &[_][]const u8{ "1", "t", "T", "true" };
    const f = &[_][]const u8{ "0", "f", "F", "false" };

    inline for (t) |str| {
        if (mem.eql(u8, v, str)) return true;
    }
    inline for (f) |str| {
        if (mem.eql(u8, v, str)) return false;
    }

    return error.InvalidBooleanValue;
}

test "parse: simple" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: bool = false,
        @"b-f": bool = true,

        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");

    // Reparsing works
    var iter2 = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84",
    );
    defer iter2.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter2);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("84", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
}

test "parseIntoField: string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: []const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
}

test "parseIntoField: sentinel string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: [:0]const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
    try testing.expectEqual(@as(u8, 0), data.a[data.a.len]);
}

test "parseIntoField: bool" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: bool,
    } = undefined;

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "t");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "T");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "true");
    try testing.expectEqual(true, data.a);

    // False
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "0");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "f");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "F");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "false");
    try testing.expectEqual(false, data.a);
}

test "parseIntoField: unsigned numbers" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        @"u8": u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "u8", "1");
    try testing.expectEqual(@as(u8, 1), data.@"u8");
}

test "parseIntoField: optional field" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: ?bool = null,
    } = .{};

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a.?);
}

test "parseIntoField: struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            v: []const u8,

            pub fn parseCLI(value: ?[]const u8) !Self {
                _ = value;
                return Self{ .v = "HELLO!" };
            }
        },
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}

/// Returns an interator (implements "next") that reads CLI args by line.
/// Each CLI arg is expected to be a single line. This is used to implement
/// configuration files.
pub fn LineIterator(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        /// The maximum size a single line can be. We don't expect any
        /// CLI arg to exceed this size. Can't wait to git blame this in
        /// like 4 years and be wrong about this.
        pub const MAX_LINE_SIZE = 4096;

        r: ReaderType,
        entry: [MAX_LINE_SIZE]u8 = [_]u8{ '-', '-' } ++ ([_]u8{0} ** (MAX_LINE_SIZE - 2)),

        pub fn next(self: *Self) ?[]const u8 {
            // TODO: detect "--" prefixed lines and give a friendlier error
            const buf = self.r.readUntilDelimiterOrEof(self.entry[2..], '\n') catch {
                // TODO: handle errors
                unreachable;
            } orelse return null;

            // We need to reslice so that we include our '--' at the beginning
            // of our buffer so that we can trick the CLI parser to treat it
            // as CLI args.
            return self.entry[0 .. buf.len + 2];
        }
    };
}

// Constructs a LineIterator (see docs for that).
pub fn lineIterator(reader: anytype) LineIterator(@TypeOf(reader)) {
    return .{ .r = reader };
}

test "LineIterator" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream(
        \\A
        \\B
        \\C
    );

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B", iter.next().?);
    try testing.expectEqualStrings("--C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
