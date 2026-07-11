//! A compressed terminal page which retains its resident virtual mapping.
//!
//! Terminal pages have two kinds of state: the large `Page.memory` allocation
//! and a comparatively small `Page` value containing offsets, dimensions,
//! dirty state, and allocator metadata. Not all of the latter state lives in
//! the backing memory, so preserving only the memory bytes is insufficient.
//! We preserve the complete `Page` value instead. This follows the same model
//! as `Page.cloneBuf`: page internals use offsets, so a shallow page copy remains
//! valid when its memory contents are restored at the same address.
//!
//! The resident memory is deliberately not freed by this type. `PageList`
//! keeps the virtual range allocated while asking the operating system to
//! discard its physical pages. Keeping the range has two useful properties:
//! the embedded page never contains a dangling pointer, and restoring the page
//! does not require a fallible allocation.
//!
//! The intended state transition is:
//!
//! 1. Create this value while the source page is resident.
//! 2. Ask the OS to decommit the source page's memory.
//! 3. Replace the PageList node's resident state with this value.
//! 4. To restore, recommit the retained range and call `restore`.
//! 5. After committing the resident state, call `deinit` to free the encoded
//!    bytes.
//!
//! If decommit is unavailable or fails, the caller should deinitialize the
//! compressed candidate and leave the source page resident. This type does not
//! perform any virtual-memory operations itself.
//!
//! The planned native implementation uses `MADV_DONTNEED` on Linux and pairs
//! `MADV_FREE_REUSABLE` with `MADV_FREE_REUSE` on Darwin. Targets without a
//! reliable retained-mapping decommit operation should leave page compression
//! disabled rather than free and later reallocate the resident memory.
const Page = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const TerminalPage = @import("../page.zig").Page;
const lz4 = @import("lz4.zig");

/// Complete page metadata together with the retained resident mapping.
///
/// The bytes in `page.memory` may have been discarded by the OS while this
/// value is in compressed state. They must not be read until `restore` has
/// successfully decoded the page.
page: TerminalPage,

/// Exact raw LZ4 block for `page.memory`.
encoded: []u8,

/// Allocator which owns `encoded`.
///
/// The allocator's backing state must outlive this compressed page. Storing
/// the allocator here lets a PageList node restore and discard its compressed
/// state without needing a reference back to the PageList.
alloc: Allocator,

/// Return the largest scratch buffer that can produce a useful compressed
/// representation for `raw_len` bytes.
///
/// This is deliberately smaller than the general LZ4 compression bound. The
/// compressed representation includes an additional slice compared to a
/// resident terminal page, so an encoded block which fills more than this
/// buffer cannot reduce resident memory. Limiting the output here lets a
/// PageList borrow a standard page-pool item as scratch instead of retaining a
/// larger, compression-bound allocation.
///
/// Callers are expected to reuse the scratch memory when practical. The
/// scratch buffer and hash table are never retained by this type.
pub fn requiredScratch(raw_len: usize) lz4.CompressError!usize {
    // Validate the codec's input limit before doing arithmetic based on the
    // raw size. The bound itself is intentionally not returned; see above.
    _ = try lz4.compressBound(raw_len);

    const representation_overhead = @sizeOf(Page) - @sizeOf(TerminalPage);
    if (raw_len <= representation_overhead) return 0;

    // The savings comparison is strict, so reserve one fewer byte than the
    // break-even encoded size.
    return raw_len - representation_overhead - 1;
}

/// Create a compressed representation of `source`.
///
/// `source` is not modified and continues to own its backing allocation. The
/// scratch buffer must be at least `requiredScratch(source.memory.len)` bytes.
/// It must not overlap the source memory. On success, the returned value aliases
/// the source's resident mapping and owns only its exact-sized `encoded`
/// allocation. The allocator and its backing state must remain valid until
/// `deinit` is called.
///
/// Returns null if retaining the compressed representation would not use less
/// memory than the resident representation. An `OutputTooSmall` result from
/// the codec also means the encoding crossed that break-even point and is
/// therefore returned as null. This comparison includes the in-memory size of
/// both representation structs but does not include allocator metadata or the
/// retained virtual address range.
pub fn init(
    alloc: Allocator,
    source: *const TerminalPage,
    scratch: []u8,
    table: *lz4.HashTable,
) (Allocator.Error || lz4.CompressError)!?Page {
    const required = try requiredScratch(source.memory.len);
    if (scratch.len < required) return error.OutputTooSmall;
    if (required == 0) return null;

    const encoded_len = lz4.compress(
        source.memory,
        scratch[0..required],
        table,
    ) catch |err| switch (err) {
        // The scratch limit is the largest representation worth retaining.
        // Running out of room therefore means compression cannot save memory,
        // rather than that the caller failed to provide the documented size.
        error.OutputTooSmall => return null,
        error.InputTooLarge => return err,
    };

    // requiredScratch already accounts for the representation structs. The
    // retained virtual range contributes no resident bytes after PageList
    // decommits it.
    assert(@sizeOf(Page) + encoded_len <
        @sizeOf(TerminalPage) + source.memory.len);

    return .{
        .page = source.*,
        .encoded = try alloc.dupe(u8, scratch[0..encoded_len]),
        .alloc = alloc,
    };
}

/// Free the encoded block.
///
/// This intentionally does not free `page.memory`. The PageList node which
/// supplied the source page continues to own that pool or heap allocation.
pub fn deinit(self: *Page) void {
    self.alloc.free(self.encoded);
    self.* = undefined;
}

/// Restore the embedded terminal page into its retained resident mapping.
///
/// The caller must recommit `page.memory` before calling this on platforms
/// which require an explicit recommit operation. The compressed value remains
/// valid whether decoding succeeds or fails, allowing the caller to retry or
/// discard it. On success the returned page aliases the same resident mapping;
/// it does not own a new allocation.
pub fn restore(self: *const Page) lz4.DecompressError!TerminalPage {
    const result = self.page;
    _ = try lz4.decompress(self.encoded, result.memory);
    return result;
}

/// Clone this page into caller-owned memory without restoring its mapping.
///
/// `memory` must be at least as large as the retained page mapping. Decoding
/// writes only to that buffer, so both the discarded contents of `page.memory`
/// and this value's encoded representation remain unchanged. The returned Page
/// borrows `memory`; the caller must keep it alive for the Page's lifetime and
/// release it directly rather than calling `TerminalPage.deinit`.
pub fn cloneBuf(
    self: *const Page,
    memory: []align(std.heap.page_size_min) u8,
) lz4.DecompressError!TerminalPage {
    assert(memory.len >= self.page.memory.len);

    // Page internals are offsets into the backing buffer, so all metadata can
    // be copied verbatim when paired with an equally laid-out mapping.
    var result = self.page;
    result.memory = memory[0..self.page.memory.len];
    _ = try lz4.decompress(self.encoded, result.memory);
    return result;
}

test "compressed Page retained mapping round trip" {
    const testing = std.testing;

    var resident = try TerminalPage.init(.{
        .cols = 12,
        .rows = 9,
        .styles = 8,
        .grapheme_bytes = 128,
        .string_bytes = 128,
    });
    defer resident.deinit();
    resident.size = .{ .cols = 10, .rows = 7 };
    resident.dirty = true;

    // Put state in both the backing memory and the Page value. In particular,
    // the style and hyperlink sets retain live counters outside Page.memory.
    const rac = resident.getRowAndCell(2, 3);
    rac.cell.* = .init('A');
    try resident.appendGrapheme(rac.row, rac.cell, 0x0301);

    const style_id = try resident.styles.add(resident.memory, .{ .flags = .{
        .bold = true,
    } });
    rac.cell.style_id = style_id;
    rac.row.styled = true;

    const hyperlink_id = try resident.insertHyperlink(.{
        .id = .{ .explicit = "compressed-page" },
        .uri = "https://ghostty.org/docs",
    });
    try resident.setHyperlink(rac.row, rac.cell, hyperlink_id);
    try resident.verifyIntegrity(testing.allocator);

    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);
    const memory_ptr = resident.memory.ptr;
    const memory_len = resident.memory.len;

    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var compressed = (try Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    )).?;
    defer compressed.deinit();

    try testing.expectEqual(memory_ptr, compressed.page.memory.ptr);
    try testing.expectEqual(memory_len, compressed.page.memory.len);
    try testing.expect(compressed.encoded.len < resident.memory.len);
    const expected_encoded = try testing.allocator.dupe(u8, compressed.encoded);
    defer testing.allocator.free(expected_encoded);

    // Virtual-memory operations belong to PageList, so clearing the contents
    // models a successful decommit: none of the resident bytes remain.
    @memset(resident.memory, 0);

    // A clone decodes into independent storage for read-only consumers which
    // must not change the compressed representation. In particular, it does
    // not recommit or overwrite the retained source mapping.
    const clone_memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        resident.memory.len,
    );
    defer testing.allocator.free(clone_memory);
    const cloned = try compressed.cloneBuf(clone_memory);
    try testing.expect(cloned.memory.ptr != memory_ptr);
    try testing.expect(std.mem.allEqual(u8, resident.memory, 0));
    try testing.expectEqualSlices(u8, expected_encoded, compressed.encoded);
    try testing.expectEqualSlices(u8, expected, cloned.memory);
    try testing.expectEqual(resident.size, cloned.size);
    try testing.expect(cloned.dirty);
    try cloned.verifyIntegrity(testing.allocator);

    const restored = try compressed.restore();
    try testing.expectEqual(memory_ptr, restored.memory.ptr);
    try testing.expectEqual(memory_len, restored.memory.len);
    try testing.expectEqualSlices(u8, expected, restored.memory);
    try testing.expectEqual(resident.size, restored.size);
    try testing.expect(restored.dirty);
    try restored.verifyIntegrity(testing.allocator);

    const restored_rac = restored.getRowAndCell(2, 3);
    try testing.expectEqualSlices(
        u21,
        &.{0x0301},
        restored.lookupGrapheme(restored_rac.cell).?,
    );
    try testing.expect(restored.styles.get(
        restored.memory,
        restored_rac.cell.style_id,
    ).flags.bold);

    const restored_hyperlink_id = restored.lookupHyperlink(restored_rac.cell).?;
    const restored_hyperlink = restored.hyperlink_set.get(
        restored.memory,
        restored_hyperlink_id,
    );
    try testing.expectEqualStrings(
        "https://ghostty.org/docs",
        restored_hyperlink.uri.slice(restored.memory),
    );
}

test "compressed Page requires the maximum useful scratch" {
    const testing = std.testing;

    var resident = try TerminalPage.init(.{ .cols = 4, .rows = 4 });
    defer resident.deinit();
    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);

    const required = try requiredScratch(resident.memory.len);
    try testing.expectEqual(
        resident.memory.len - (@sizeOf(Page) - @sizeOf(TerminalPage)) - 1,
        required,
    );
    try testing.expect(required < try lz4.compressBound(resident.memory.len));

    const scratch = try testing.allocator.alloc(u8, required - 1);
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;

    try testing.expectError(error.OutputTooSmall, Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    ));
    try testing.expectEqualSlices(u8, expected, resident.memory);
}

test "compressed Page rejects a representation without savings" {
    const testing = std.testing;

    var resident = try TerminalPage.init(.{
        .cols = 4,
        .rows = 4,
        .styles = 0,
        .grapheme_bytes = 0,
        .string_bytes = 0,
        .hyperlink_bytes = 0,
    });
    defer resident.deinit();

    var prng = std.Random.DefaultPrng.init(0x4C5A_3402);
    prng.random().bytes(resident.memory);

    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });

    try testing.expect((try Page.init(
        failing.allocator(),
        &resident,
        scratch,
        &table,
    )) == null);
    try testing.expect(!failing.has_induced_failure);
}

test "compressed Page can retry after malformed encoded data" {
    const testing = std.testing;

    var resident = try TerminalPage.init(.{ .cols = 8, .rows = 8 });
    defer resident.deinit();
    const expected = try testing.allocator.dupe(u8, resident.memory);
    defer testing.allocator.free(expected);

    const scratch = try testing.allocator.alloc(
        u8,
        try requiredScratch(resident.memory.len),
    );
    defer testing.allocator.free(scratch);
    var table: lz4.HashTable = undefined;
    var compressed = (try Page.init(
        testing.allocator,
        &resident,
        scratch,
        &table,
    )).?;
    defer compressed.deinit();

    const full_encoded = compressed.encoded;
    const first_byte = full_encoded[0];
    defer {
        compressed.encoded = full_encoded;
        compressed.encoded[0] = first_byte;
    }
    compressed.encoded = full_encoded[0..1];
    compressed.encoded[0] = 0xF0;

    const clone_memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        resident.memory.len,
    );
    defer testing.allocator.free(clone_memory);
    try testing.expectError(
        error.TruncatedInput,
        compressed.cloneBuf(clone_memory),
    );
    try testing.expectError(error.TruncatedInput, compressed.restore());

    compressed.encoded = full_encoded;
    compressed.encoded[0] = first_byte;
    @memset(resident.memory, 0);
    const restored = try compressed.restore();
    try testing.expectEqualSlices(u8, expected, restored.memory);
}
