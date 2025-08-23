const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// 8-bit unsigned integer.
pub const uint8 = u8;

/// 8-bit signed integer.
pub const int8 = i8;

/// 16-bit unsigned integer.
pub const uint16 = u16;

/// 16-bit signed integer.
pub const int16 = i16;

/// 24-bit unsigned integer.
pub const uint24 = u24;

/// 32-bit unsigned integer.
pub const uint32 = u32;

/// 32-bit signed integer.
pub const int32 = i32;

/// 32-bit signed fixed-point number (16.16)
pub const Fixed = FixedPoint(i32, 16, 16);

/// int16 that describes a quantity in font design units.
pub const FWORD = i16;

/// uint16 that describes a quantity in font design units.
pub const UFWORD = u16;

/// 16-bit signed fixed number with the low 14 bits of fraction (2.14).
pub const F2DOT14 = FixedPoint(i16, 2, 14);

/// Date and time represented in number of seconds since 12:00 midnight, January 1, 1904, UTC. The value is represented as a signed 64-bit integer.
pub const LONGDATETIME = i64;

/// Array of four uint8s (length = 32 bits) used to identify a table,
/// design-variation axis, script, language system, feature, or baseline.
pub const Tag = [4]u8;

/// 8-bit offset to a table, same as uint8, NULL offset = 0x00
pub const Offset8 = u8;

/// Short offset to a table, same as uint16, NULL offset = 0x0000
pub const Offset16 = u16;

/// 24-bit offset to a table, same as uint24, NULL offset = 0x000000
pub const Offset24 = u24;

/// Long offset to a table, same as uint32, NULL offset = 0x00000000
pub const Offset32 = u32;

/// Packed 32-bit value with major and minor version numbers
pub const Version16Dot16 = packed struct(u32) {
    minor: u16,
    major: u16,
};

/// 32-bit signed 26.6 fixed point numbers.
pub const F26Dot6 = FixedPoint(i32, 26, 6);

fn FixedPoint(comptime T: type, int_bits: u64, frac_bits: u64) type {
    const type_info: std.builtin.Type.Int = @typeInfo(T).int;
    comptime assert(int_bits + frac_bits == type_info.bits);

    return packed struct(T) {
        const Self = FixedPoint(T, int_bits, frac_bits);
        const frac_factor: comptime_float = @floatFromInt(std.math.pow(
            u64,
            2,
            frac_bits,
        ));
        const half = @as(T, 1) << @intCast(frac_bits - 1);

        const Frac = std.meta.Int(.unsigned, frac_bits);
        const Int = std.meta.Int(type_info.signedness, int_bits);

        frac: Frac,
        int: Int,

        pub fn to(self: Self, comptime FloatType: type) FloatType {
            return @as(FloatType, @floatFromInt(
                @as(T, @bitCast(self)),
            )) / frac_factor;
        }

        pub fn from(float: anytype) Self {
            return @bitCast(
                @as(T, @intFromFloat(@round(float * frac_factor))),
            );
        }

        /// Round to the nearest integer, .5 rounds away from 0.
        pub fn round(self: Self) T {
            if (self.frac & half != 0)
                return self.int + 1
            else
                return self.int;
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            try writer.print("{d}", .{self.to(f64)});
        }
    };
}

test FixedPoint {
    const testing = std.testing;

    const p26d6 = F26Dot6.from(26.6);
    try testing.expectEqual(F26Dot6{
        .int = 26,
        .frac = 38,
    }, p26d6);
    try testing.expectEqual(26.59375, p26d6.to(f64));
    try testing.expectEqual(27, p26d6.round());

    const n26d6 = F26Dot6.from(-26.6);
    try testing.expectEqual(F26Dot6{
        .int = -27,
        .frac = 26,
    }, n26d6);
    try testing.expectEqual(-26.59375, n26d6.to(f64));
    try testing.expectEqual(-27, n26d6.round());
}

/// Wrapper for parsing a SFNT font and accessing its tables.
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/otff
/// - https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6.html
pub const SFNT = struct {
    const Directory = struct {
        offset: OffsetSubtable,
        records: []TableRecord,

        /// The static (fixed-sized) portion of the table directory
        ///
        /// This struct matches the memory layout of the TrueType/OpenType
        /// TableDirectory, but does not include the TableRecord array, since
        /// that is dynamically sized, so we parse it separately.
        ///
        /// In the TrueType reference manual this
        /// is referred to as the "offset subtable".
        ///
        /// https://learn.microsoft.com/en-us/typography/opentype/spec/otff#table-directory
        const OffsetSubtable = extern struct {
            /// Indicates the type of font file we're reading.
            ///   - 0x00_01_00_00   ----   TrueType
            ///   - 0x74_72_75_65  'true'  TrueType
            ///   - 0x4F_54_54_4F  'OTTO'  OpenType
            ///   - 0x74_79_70_31  'typ1'  PostScript
            sfnt_version: uint32 align(1),
            /// Number of tables.
            num_tables: uint16 align(1),
            /// Maximum power of 2 less than or equal to numTables, times 16 ((2**floor(log2(numTables))) * 16, where “**” is an exponentiation operator).
            search_range: uint16 align(1),
            /// Log2 of the maximum power of 2 less than or equal to numTables (log2(searchRange/16), which is equal to floor(log2(numTables))).
            entry_selector: uint16 align(1),
            /// numTables times 16, minus searchRange ((numTables * 16) - searchRange).
            range_shift: uint16 align(1),

            pub fn format(
                self: OffsetSubtable,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                try writer.print(
                    "OffsetSubtable('{s}'){{ .num_tables = {} }}",
                    .{
                        if (self.sfnt_version == 0x00_01_00_00)
                            &@as([10]u8, "0x00010000".*)
                        else
                            &@as([4]u8, @bitCast(
                                std.mem.nativeToBig(u32, self.sfnt_version),
                            )),
                        self.num_tables,
                    },
                );
            }
        };

        const TableRecord = extern struct {
            /// Table identifier.
            tag: Tag align(1),
            /// Checksum for this table.
            checksum: uint32 align(1),
            /// Offset from beginning of font file.
            offset: Offset32 align(1),
            /// Length of this table.
            length: uint32 align(1),

            pub fn format(
                self: TableRecord,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                try writer.print(
                    "TableRecord(\"{s}\"){{ .checksum = {}, .offset = {}, .length = {} }}",
                    .{
                        self.tag,
                        self.checksum,
                        self.offset,
                        self.length,
                    },
                );
            }
        };
    };

    directory: Directory,

    data: []const u8,

    /// Parse a font from raw data. The struct will keep a
    /// reference to `data` and use it for future operations.
    pub fn init(data: []const u8, alloc: Allocator) !SFNT {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        // SFNT files use big endian, if our native endian is
        // not big we'll need to byte swap the values we read.
        const byte_swap = native_endian != .big;

        var directory: Directory = undefined;

        try reader.readNoEof(std.mem.asBytes(&directory.offset));
        if (byte_swap) std.mem.byteSwapAllFields(
            Directory.OffsetSubtable,
            &directory.offset,
        );

        directory.records = try alloc.alloc(Directory.TableRecord, directory.offset.num_tables);

        try reader.readNoEof(std.mem.sliceAsBytes(directory.records));
        if (byte_swap) for (directory.records) |*record| {
            std.mem.byteSwapAllFields(
                Directory.TableRecord,
                record,
            );
        };

        return .{
            .directory = directory,
            .data = data,
        };
    }

    pub fn deinit(self: SFNT, alloc: Allocator) void {
        alloc.free(self.directory.records);
    }

    /// Returns the bytes of the table with the provided tag if present.
    pub fn getTable(self: SFNT, tag: *const [4]u8) ?[]const u8 {
        for (self.directory.records) |record| {
            if (std.mem.eql(u8, tag, &record.tag)) {
                return self.data[record.offset..][0..record.length];
            }
        }

        return null;
    }
};

const native_endian = @import("builtin").target.cpu.arch.endian();

test "parse font" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const test_font = @import("../embedded.zig").julia_mono;

    const sfnt = try SFNT.init(&test_font.*, alloc);
    defer sfnt.deinit(alloc);

    try testing.expectEqual(19, sfnt.directory.offset.num_tables);
    try testing.expectEqualStrings("prep", &sfnt.directory.records[18].tag);
}

test "get table" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const test_font = @import("../embedded.zig").julia_mono;

    const sfnt = try SFNT.init(&test_font.*, alloc);
    defer sfnt.deinit(alloc);

    const svg = sfnt.getTable("SVG ").?;

    try testing.expectEqual(430, svg.len);
}
