//! Virtual-memory operations shared by terminal page owners.
//!
//! Terminal pages use page-aligned, page-multiple mappings. This module can
//! discard the physical pages behind one of those mappings without releasing
//! its virtual address range, then prepare the same range for reuse. It does
//! not allocate memory or decide which terminal pages should be discarded.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.terminal_mem);

/// What guarantee decommit must provide when the OS cannot discard a mapping.
pub const DecommitMode = enum {
    /// The dirty prefix must read as zero after this call, even when physical
    /// reclamation is unavailable. Bytes after the prefix must already be zero.
    zero,

    /// Physical-memory reclamation is required. Do not touch the mapping when
    /// reclamation is unsupported or fails; report the failure to the caller.
    strict,
};

/// Return whether this target can reclaim physical memory for `mode` while
/// retaining the mapping's virtual address range.
///
/// Test builds support both modes because `decommit` simulates reclamation by
/// clearing the supplied range. Runtime reclamation is intentionally limited
/// to 64-bit Linux and Darwin. Other targets must leave strict callers' memory
/// resident; zero mode still provides its documented memset fallback through
/// `decommit` even when this function returns false.
pub inline fn canReclaim(comptime mode: DecommitMode) bool {
    // Both modes use the same retained-mapping primitives. Keeping the switch
    // exhaustive makes additions to DecommitMode choose target support
    // explicitly rather than inheriting it accidentally.
    return switch (mode) {
        .zero, .strict => supported: {
            // Tests never call into the OS because their allocator ranges can
            // share mappings with unrelated allocations. `decommit` simulates
            // successful reclamation by zeroing the requested range instead,
            // so both modes are always available to tests on every target.
            if (builtin.is_test) break :supported true;

            // Compression currently retains complete page mappings for its
            // lifetime. Limit the initial runtime support to 64-bit address
            // spaces where that virtual-memory cost is negligible and where
            // the retained-mapping behavior has been validated.
            if (builtin.target.ptrBitWidth() != 64) break :supported false;

            // Linux provides MADV_DONTNEED, which immediately discards pages
            // from a private anonymous mapping and faults them back as zeroes.
            // Zig reaches this through the raw syscall path without libc.
            if (builtin.target.os.tag == .linux) break :supported true;

            // Darwin provides the paired MADV_FREE_REUSABLE/FREE_REUSE
            // operations used below. Darwin requires libc independently of
            // this feature, so using its madvise entry point adds no new
            // dependency to libghostty-vt.
            if (builtin.target.os.tag.isDarwin()) break :supported true;

            // Other targets have no retained-mapping reclamation contract in
            // this module. Zero mode can still clear through its memset
            // fallback, but strict callers must leave their mapping resident.
            break :supported false;
        },
    };
}

/// Discard physical pages while retaining a mapping's virtual address range.
///
/// The complete mapping must be page-aligned and a multiple of the minimum
/// system page size. `dirty_len` identifies the prefix whose contents may be
/// nonzero. Strict mode requires the complete mapping to be dirty because a
/// successful discard invalidates all of its contents.
///
/// The return value reports whether the OS accepted the reclamation request.
/// Test builds return true after simulating reclamation by zeroing dirty bytes.
/// In zero mode, the requested bytes are guaranteed to be zero regardless of
/// the return value.
pub fn decommit(
    comptime mode: DecommitMode,
    memory: []align(std.heap.page_size_min) u8,
    dirty_len: usize,
) bool {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);
    assert(dirty_len <= memory.len);
    if (comptime mode == .strict) assert(dirty_len == memory.len);

    // Testing allocator ranges may share an OS mapping with unrelated memory,
    // so madvise is not safe. Zeroing models the only content guarantee callers
    // have after a successful discard.
    if (comptime builtin.is_test) {
        @memset(memory[0..dirty_len], 0);
        return true;
    }

    // DONTNEED immediately reclaims private anonymous pages on Linux and
    // faults them back as zero-filled pages. We deliberately avoid MADV_FREE:
    // it does not reduce RSS until memory pressure and does not guarantee that
    // the next read is zero.
    if (comptime builtin.os.tag == .linux) {
        if (std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.DONTNEED,
        )) |_| return true else |err| {
            log.warn("madvise(DONTNEED) failed err={}", .{err});
            if (comptime mode == .strict) return false;
            // Zero mode falls through to the memset below.
        }
    }

    // FREE_REUSABLE removes the range from the Darwin process footprint while
    // retaining its mapping. Zero mode clears its dirty prefix first because
    // the kernel may preserve the contents. Strict mode avoids that write
    // because its caller will replace the entire mapping after recommit.
    if (comptime builtin.os.tag.isDarwin()) {
        if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);

        if (std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSABLE,
        )) |_| return true else |err| {
            switch (mode) {
                .strict => {
                    log.warn("madvise(FREE_REUSABLE) failed err={}", .{err});
                    return false;
                },

                .zero => {
                    // Plain FREE can still reclaim the already-zero mapping
                    // under pressure and does not require a reuse pairing.
                    std.posix.madvise(
                        memory.ptr,
                        memory.len,
                        std.posix.MADV.FREE,
                    ) catch {};
                    return false;
                },
            }
        }
    }

    if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
    return false;
}

/// Prepare a mapping previously passed to decommit for reuse.
///
/// Linux and test builds need no explicit operation. Darwin pairs
/// FREE_REUSABLE with FREE_REUSE so pages touched by the caller are accounted
/// to the process again. Failure does not invalidate the retained mapping, so
/// reuse can continue after logging the accounting failure.
pub fn recommit(memory: []align(std.heap.page_size_min) u8) void {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);

    if (comptime builtin.is_test) return;
    if (comptime builtin.os.tag.isDarwin()) {
        std.posix.madvise(
            memory.ptr,
            memory.len,
            std.posix.MADV.FREE_REUSE,
        ) catch |err| {
            log.warn("madvise(FREE_REUSE) failed err={}", .{err});
        };
    }
}

test "decommit with zero fallback clears the dirty prefix" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);

    @memset(memory, 0xAA);
    _ = decommit(.zero, memory, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));

    // The tail is already zero by contract, so a partially dirty mapping only
    // needs its dirty prefix cleared.
    @memset(memory[0..1024], 0xAA);
    _ = decommit(.zero, memory, 1024);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
}

test "strict decommit retains the mapping for recommit" {
    const testing = std.testing;
    const memory_len = 2 * std.heap.page_size_min;
    const memory = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        memory_len,
    );
    defer testing.allocator.free(memory);
    @memset(memory, 0xAA);

    const original_ptr = memory.ptr;
    const original_len = memory.len;
    try testing.expect(decommit(.strict, memory, memory.len));
    try testing.expectEqual(original_ptr, memory.ptr);
    try testing.expectEqual(original_len, memory.len);
    try testing.expect(std.mem.allEqual(u8, memory, 0));

    recommit(memory);
    @memset(memory, 0xBB);
    try testing.expect(std.mem.allEqual(u8, memory, 0xBB));
}

test "test builds can reclaim retained mappings" {
    const testing = std.testing;
    try testing.expect(canReclaim(.zero));
    try testing.expect(canReclaim(.strict));
}
