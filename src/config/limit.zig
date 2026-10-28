const std = @import("std");
const formatterpkg = @import("formatter.zig");

/// A configurable integer limit with a declared default and support for the
/// special value `unlimited`.
///
/// Unlimited is stored as the maximum value of the integer type so the value
/// remains directly comparable without optional unwrapping.
pub fn Limit(comptime T: type, comptime default_value: T) type {
    comptime std.debug.assert(@typeInfo(T) == .int);

    return struct {
        const Self = @This();

        value: T = default_value,

        /// The limit initialized with its declared default value.
        pub const default: Self = .{};

        /// Parses an integer limit or the special value "unlimited".
        pub fn parseCLI(input_: ?[]const u8) !Self {
            const input = input_ orelse return error.ValueRequired;
            if (std.mem.eql(u8, input, "unlimited")) {
                return .{ .value = std.math.maxInt(T) };
            }

            return .{
                .value = std.fmt.parseInt(T, input, 0) catch
                    return error.InvalidValue,
            };
        }

        /// Formats the maximum integer value as "unlimited" and all other
        /// values as integers.
        pub fn formatEntry(
            self: Self,
            formatter: formatterpkg.EntryFormatter,
        ) !void {
            if (self.value == std.math.maxInt(T)) {
                try formatter.formatEntry([]const u8, "unlimited");
            } else {
                try formatter.formatEntry(T, self.value);
            }
        }

        /// Returns the configured value, or null for the unlimited sentinel.
        pub fn optional(self: Self) ?T {
            if (self.value == std.math.maxInt(T)) return null;
            return self.value;
        }

        /// Returns an independent copy of this value for Config cloning.
        pub fn clone(
            self: Self,
            _: std.mem.Allocator,
        ) std.mem.Allocator.Error!Self {
            return self;
        }
    };
}

test "Limit default and parsing" {
    const testing = std.testing;
    const TestLimit = Limit(usize, 42);

    try testing.expectEqual(@as(usize, 42), TestLimit.default.value);
    try testing.expectEqual(
        @as(usize, 123),
        (try TestLimit.parseCLI("123")).value,
    );
    try testing.expectEqual(
        std.math.maxInt(usize),
        (try TestLimit.parseCLI("unlimited")).value,
    );
    try testing.expectError(error.InvalidValue, TestLimit.parseCLI("invalid"));
}

test "Limit optional" {
    const testing = std.testing;
    const TestLimit = Limit(u16, 42);

    try testing.expectEqual(@as(?u16, 42), (TestLimit{}).optional());
    try testing.expectEqual(
        @as(?u16, null),
        (TestLimit{ .value = std.math.maxInt(u16) }).optional(),
    );
}

test "Limit formatting" {
    const testing = std.testing;
    const TestLimit = Limit(usize, 42);

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        try (TestLimit{ .value = 123 }).formatEntry(
            formatterpkg.entryFormatter("limit", &buf.writer),
        );
        try testing.expectEqualStrings("limit = 123\n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        try (TestLimit{ .value = std.math.maxInt(usize) }).formatEntry(
            formatterpkg.entryFormatter("limit", &buf.writer),
        );
        try testing.expectEqualStrings(
            "limit = unlimited\n",
            buf.written(),
        );
    }
}
