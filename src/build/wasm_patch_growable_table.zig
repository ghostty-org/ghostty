//! Build tool that patches a WASM binary to make the function table
//! growable by removing its maximum size limit.
//!
//! Zig's WASM linker doesn't support `--growable-table`, so the table
//! is emitted with max == min. This tool finds the table section (id 4)
//! and changes the limits flag from 0x01 (has max) to 0x00 (no max),
//! removing the max field.
//!
//! Usage: wasm_growable_table <input.wasm> <output.wasm>

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    // This is a one-off patcher, so we leak all our memory on purpose
    // and let the OS clean it up when we exit.
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const alloc = gpa.allocator();

    // Parse args: program input output
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len != 3) {
        std.log.err("usage: wasm_growable_table <input.wasm> <output.wasm>", .{});
        std.process.exit(1);
        unreachable;
    }

    // Patch the file.
    const output: []const u8 = try patchTableGrowable(
        alloc,
        try std.fs.cwd().readFileAlloc(
            alloc,
            args[1],
            std.math.maxInt(usize),
        ),
    );

    // Write our output
    const out_file = try std.fs.cwd().createFile(args[2], .{});
    defer out_file.close();
    try out_file.writeAll(output);
}

/// Patch the WASM binary's table section to remove the maximum size
/// limit, making the table growable. If the table already has no max
/// or no table section is found, the input is returned unchanged.
///
/// The WASM table section (id=4) encodes table limits as:
///   - flags=0x00, min (LEB128)          — no max, growable
///   - flags=0x01, min (LEB128), max (LEB128) — bounded, not growable
///
/// This function rewrites the section to use flags=0x00, dropping the
/// max field entirely.
fn patchTableGrowable(
    alloc: Allocator,
    input: []const u8,
) (error{InvalidWasm} || std.Io.Writer.Error)![]const u8 {
    if (input.len < 8) return error.InvalidWasm;

    // Start after the 8-byte WASM header (magic + version).
    var pos: usize = 8;

    while (pos < input.len) {
        const section_id = input[pos];
        pos += 1;
        const section_size = readLeb128(input, &pos);
        const section_start = pos;

        // We're looking for section 4 (the table section).
        if (section_id != 4) {
            pos = section_start + section_size;
            continue;
        }

        _ = readLeb128(input, &pos); // table count
        pos += 1; // elem_type (0x70 = funcref)
        const flags = input[pos];

        // flags bit 0 indicates whether a max is present.
        if (flags & 1 == 0) {
            // Already no max, nothing to patch.
            return input;
        }

        // Record positions of each field so we can reconstruct
        // the section without the max value.
        const flags_pos = pos;
        pos += 1; // skip flags byte
        const min_start = pos;
        _ = readLeb128(input, &pos); // min
        const max_start = pos;
        _ = readLeb128(input, &pos); // max
        const max_end = pos;
        const section_end = section_start + section_size;

        // Build the new section payload with the max removed:
        //   [table count + elem_type] [flags=0x00] [min] [trailing data]
        var payload: std.Io.Writer.Allocating = .init(alloc);
        try payload.writer.writeAll(input[section_start..flags_pos]);
        try payload.writer.writeByte(0x00); // flags: no max
        try payload.writer.writeAll(input[min_start..max_start]);
        try payload.writer.writeAll(input[max_end..section_end]);

        // Reassemble the full binary:
        //   [everything before this section] [section id] [new size] [new payload] [everything after]
        const before_section = input[0 .. section_start - 1 - uleb128Size(section_size)];
        var result: std.Io.Writer.Allocating = .init(alloc);
        try result.writer.writeAll(before_section);
        try result.writer.writeByte(4); // table section id
        try result.writer.writeUleb128(@as(u32, @intCast(payload.written().len)));
        try result.writer.writeAll(payload.written());
        try result.writer.writeAll(input[section_end..]);
        return result.written();
    }

    // No table section found; return input unchanged.
    return input;
}

/// Decode an unsigned LEB128 value from `bytes` starting at `pos.*`,
/// advancing `pos` past the encoded bytes.
fn readLeb128(bytes: []const u8, pos: *usize) u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        const byte = bytes[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
    }
}

/// Return the number of bytes needed to encode `value` as unsigned LEB128.
fn uleb128Size(value: u32) usize {
    var v = value;
    var size: usize = 0;
    while (true) {
        v >>= 7;
        size += 1;
        if (v == 0) return size;
    }
}

/// Minimal valid WASM module with a bounded table (min=1, max=1).
/// Sections: type(1), table(4), export(7).
const test_wasm_bounded_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version
    // Type section (id=1): 1 type, () -> ()
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    // Table section (id=4): 1 table, funcref, flags=1, min=1, max=1
    0x04, 0x05,
    0x01, 0x70, 0x01, 0x01,
    0x01,
    // Export section (id=7): 0 exports
    0x07, 0x01, 0x00,
};

/// Same module but the table already has no max (flags=0).
const test_wasm_growable_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version
    // Type section (id=1)
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    // Table section (id=4): 1 table, funcref, flags=0, min=1
    0x04, 0x04,
    0x01, 0x70, 0x00, 0x01,
    // Export section (id=7): 0 exports
    0x07, 0x01, 0x00,
};

/// Module with no table section at all.
const test_wasm_no_table = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version
    // Type section (id=1)
    0x01, 0x04, 0x01, 0x60,
    0x00, 0x00,
    // Export section (id=7): 0 exports
    0x07, 0x01,
    0x00,
};

test "patches bounded table to remove max" {
    // We use a non-checking allocator because the patched result is
    // intentionally leaked (matches the real main() usage).
    const result = try patchTableGrowable(
        std.heap.page_allocator,
        &test_wasm_bounded_table,
    );

    // Result should differ from input (max was removed).
    try testing.expect(!std.mem.eql(
        u8,
        result,
        &test_wasm_bounded_table,
    ));

    // Find the table section in the output and verify flags=0x00.
    var pos: usize = 8;
    while (pos < result.len) {
        const id = result[pos];
        pos += 1;
        const size = readLeb128(result, &pos);
        if (id == 4) {
            _ = readLeb128(result, &pos); // table count
            pos += 1; // elem_type
            // flags should now be 0x00 (no max).
            try testing.expectEqual(@as(u8, 0x00), result[pos]);
            return;
        }
        pos += size;
    }
    return error.TableSectionNotFound;
}

test "already growable table is returned unchanged" {
    const result = try patchTableGrowable(
        testing.allocator,
        &test_wasm_growable_table,
    );
    try testing.expectEqual(
        @as([*]const u8, &test_wasm_growable_table),
        result.ptr,
    );
}

test "no table section returns input unchanged" {
    const result = try patchTableGrowable(
        testing.allocator,
        &test_wasm_no_table,
    );
    try testing.expectEqual(@as([*]const u8, &test_wasm_no_table), result.ptr);
}

test "too short input returns InvalidWasm" {
    try testing.expectError(
        error.InvalidWasm,
        patchTableGrowable(testing.allocator, "short"),
    );
}

test "readLeb128 single byte" {
    const bytes = [_]u8{0x05};
    var pos: usize = 0;
    try testing.expectEqual(@as(u32, 5), readLeb128(&bytes, &pos));
    try testing.expectEqual(@as(usize, 1), pos);
}

test "readLeb128 multi byte" {
    // 300 = 0b100101100 → LEB128: 0xAC 0x02
    const bytes = [_]u8{ 0xAC, 0x02 };
    var pos: usize = 0;
    try testing.expectEqual(@as(u32, 300), readLeb128(&bytes, &pos));
    try testing.expectEqual(@as(usize, 2), pos);
}

test "uleb128Size" {
    try testing.expectEqual(@as(usize, 1), uleb128Size(0));
    try testing.expectEqual(@as(usize, 1), uleb128Size(0x7f));
    try testing.expectEqual(@as(usize, 2), uleb128Size(0x80));
    try testing.expectEqual(@as(usize, 2), uleb128Size(300));
    try testing.expectEqual(@as(usize, 5), uleb128Size(std.math.maxInt(u32)));
}
