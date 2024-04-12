const std = @import("std");
const assert = std.debug.assert;
const js = @import("main.zig");

/// Possible types of values.
pub const Type = enum {
    undefined,
    null,
    boolean,
    number,
    object,
    string,
    symbol,
    function,
};

/// Ref uniquely identifies a JS value. A JS value can't be physically
/// copied to the WASM environment so we represent it using a 64-bit number
/// into a table that is maintained on the JS side.
///
/// For a JS number (float64), the ref is literally the float64 (bitcasted).
/// For other types, we utilize the unused bits of the IEEE 754 NaN
/// representation to encode additional data into the ref. Bits 0-31
/// are used as an ID and bits 32-34 are used as a type ID.
pub const Ref = packed struct(u64) {
    id: u32 = 0,
    type_id: TypeId = .inferred,
    head: u29 = nanHead,

    /// Predefined refs.
    pub const nan: Ref = .{ .id = 0 };
    pub const @"null": Ref = .{ .id = 1 };
    pub const @"true": Ref = .{ .id = 2 };
    pub const @"false": Ref = .{ .id = 3 };
    pub const @"undefined": Ref = .{ .id = 4 };
    pub const global: Ref = .{ .id = 5 };
    pub const runtime: Ref = .{ .id = 6 };

    /// NaN in IEEE-754 is 0b0111_1111_1111_<anything other than all zeroes>.
    /// We always force NaN to have a 1-bit set in the 4th byte from the MSB
    /// so that we can use the lower 51 bits.
    const nanHead: u29 = 0x7FF8_0000 >> 3;

    /// These are the type_id types we support. This doesn't match the
    /// "Type" enum because some types are inferred based on their structure.
    const TypeId = enum(u3) {
        inferred = 0,
        object = 1,
        string = 2,
        symbol = 3,
        function = 4,
    };

    /// Returns the type of a ref.
    pub fn typeOf(self: Ref) js.Type {
        // If we aren't a NaN then we have to be a number
        if (self.head != nanHead) return .number;

        return switch (self.type_id) {
            .object => .object,
            .string => .string,
            .symbol => .symbol,
            .function => .function,
            .inferred => switch (self.id) {
                0 => .number,
                1 => .null,
                2, 3 => .boolean,
                4 => .undefined,
                5, 6 => .object,
                else => unreachable,
            },
        };
    }

    /// Returns true if the ref should be released.
    ///
    /// We don't need to release raw numbers because they're copied directly
    /// into our environment. And we don't need to release the predefined
    /// values because they're always retained.
    pub fn isReleasable(self: Ref) bool {
        return self.head == nanHead and self.type_id != .inferred;
    }

    pub fn toF64(self: Ref) f64 {
        assert(self.typeOf() == .number);
        return @bitCast(self);
    }

    // This just helps test what JS will do
    test "js comparisons" {
        const testing = std.testing;

        {
            const n: u64 = (@as(u64, @intCast(@as(u32, @intCast(nanHead)) << 3 | 2)) << 32) | 14;
            const ref: Ref = @bitCast(n);
            try testing.expectEqual(nanHead, ref.head);
            try testing.expectEqual(js.Type.string, ref.typeOf());
            try testing.expectEqual(@as(u32, 14), ref.id);
        }
    }

    test "types" {
        const testing = std.testing;

        {
            const ref: Ref = .{ .type_id = .object };
            try testing.expectEqual(js.Type.object, ref.typeOf());
        }
    }

    test "floats" {
        const testing = std.testing;

        {
            const ref = @as(Ref, @bitCast(@as(u64, @bitCast(@as(f64, 1.234)))));
            try testing.expectEqual(js.Type.number, ref.typeOf());
            try testing.expectEqual(@as(f64, 1.234), ref.toF64());
        }

        // zero
        {
            const ref = @as(Ref, @bitCast(@as(u64, @bitCast(@as(f64, 0)))));
            try testing.expectEqual(js.Type.number, ref.typeOf());
            try testing.expectEqual(@as(f64, 0), ref.toF64());
        }
    }

    test "nans" {
        const testing = std.testing;

        // Stdlib nan
        {
            const ref = @as(Ref, @bitCast(@as(u64, @bitCast(std.math.nan(f64)))));
            try testing.expectEqual(js.Type.number, ref.typeOf());
            try testing.expect(std.math.isNan(ref.toF64()));
        }

        // Manual nan
        {
            const ref = @as(Ref, @bitCast(@as(u64, 0x7FF8_0000_0000_0000)));
            try testing.expectEqual(js.Type.number, ref.typeOf());
        }
    }
};

test {
    _ = Ref;
}
