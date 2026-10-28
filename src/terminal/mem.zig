//! Give the physical memory behind terminal pages back to the operating
//! system while keeping their addresses.
//!
//! Terminal page memory is page-aligned and a whole number of pages long.
//! When a page's contents are no longer needed in place (for example, after
//! the page has been compressed), its owner can release the physical memory
//! behind it but keep the address range. Later, the owner can reuse the same
//! range without allocating again.
//!
//! A page goes through three steps:
//!
//! 1. `decommit` releases the physical memory. The range stays mapped, so
//!    reading it is safe. It reads as zeros, or on some platforms as the old
//!    contents, until it is written again.
//! 2. `recommit` prepares the range for use again.
//! 3. The owner writes new contents into the range.
//!
//! For example, a page whose contents were copied somewhere else first:
//!
//! ```zig
//! if (mem.canReclaim(.strict) and mem.decommit(.strict, page, page.len)) {
//!     // The physical memory is released. `page` is still a valid range.
//!     // ...
//!     // Later, before reusing it:
//!     mem.recommit(page);
//!     @memcpy(page, saved_contents);
//! }
//! ```
//!
//! This module does not allocate memory or decide which pages to release.
//!
//! After a successful decommit, the range is still mapped and still counted
//! against the process's memory limits. This is why `recommit` never has to
//! acquire anything and cannot fail. Most platforms get there by asking the
//! kernel to drop the pages in place. FreeBSD has no such request, so it maps
//! fresh memory over the same range instead. That reaches the same state by
//! the time `decommit` returns.
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const windows = @import("../os/windows.zig");

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

/// Returns whether this build can release physical memory for `mode` while
/// keeping the address range.
///
/// Check this before calling `decommit` in strict mode. When it returns
/// false, strict callers should keep their memory as it is:
///
/// ```zig
/// if (!mem.canReclaim(.strict)) return; // Nothing to gain on this target.
/// ```
///
/// Release builds support 64-bit Linux, Darwin, Windows, and FreeBSD. Test
/// builds always return true, because there `decommit` imitates a release by
/// writing zeros. Zero mode works on every target even when this returns
/// false, because `decommit` falls back to writing zeros itself.
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

            // Windows provides DiscardVirtualMemory, which releases the
            // physical pages behind a committed range while keeping it
            // committed, so nothing has to be committed again before reuse.
            // Page memory is already a VirtualAlloc region (see page.zig)
            // and kernel32 is linked by every Windows build.
            if (builtin.target.os.tag == .windows) break :supported true;

            // FreeBSD maps fresh memory over the range (see decommitFreeBSD).
            // The old pages are freed right away and the range reads as zeros
            // afterward. mmap comes from libc, which every FreeBSD build links.
            if (builtin.target.os.tag == .freebsd) break :supported true;

            // Other targets have no retained-mapping reclamation contract in
            // this module. Zero mode can still clear through its memset
            // fallback, but strict callers must leave their mapping resident.
            break :supported false;
        },
    };
}

/// Release the physical memory behind `memory` while keeping its address
/// range.
///
/// `memory` must start on a page boundary and be a whole number of pages
/// long, using the smallest page size the target supports. `dirty_len` is
/// the length of the prefix that may hold nonzero bytes. Everything after it
/// must already be zero. Strict mode requires `dirty_len == memory.len`,
/// because a successful decommit throws away everything in the range.
///
/// Returns true when the operating system released the memory. What false
/// means depends on `mode`:
///
/// - `.strict`: nothing was released and the contents are unchanged, so the
///   caller can keep using the memory as it was.
/// - `.zero`: the memory may still be in use, but the dirty prefix has been
///   cleared. The whole range reads as zeros either way.
///
/// Zero mode suits memory that is about to be reused and only needs to be
/// clean. Only the bytes that were actually written have to be cleared:
///
/// ```zig
/// // Only the first `used` bytes of `page` were ever written.
/// _ = mem.decommit(.zero, page, used);
/// // `page` now reads as all zeros.
/// ```
///
/// In test builds this never calls into the operating system. It clears the
/// dirty prefix and returns true, which imitates a successful release.
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
    if (comptime builtin.target.os.tag == .linux) {
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
    if (comptime builtin.target.os.tag.isDarwin()) {
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

    // DiscardVirtualMemory releases the physical pages behind the range but
    // leaves it committed, so the commit charge stays with the process and a
    // later access finds a zero page or the old contents instead of faulting.
    // Zero mode clears its dirty prefix first, as on Darwin: the bytes read
    // as zero afterward whether or not the discard took. Strict mode skips
    // that write because its caller replaces the entire mapping after
    // recommit. The call reports failure through its return value rather
    // than the thread's last error.
    if (comptime builtin.target.os.tag == .windows) {
        if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);

        const rc = windows.exp.kernel32.DiscardVirtualMemory(
            memory.ptr,
            memory.len,
        );
        if (rc == windows.ERROR_SUCCESS) return true;

        // Zero mode has already cleared its bytes and strict callers must
        // leave the still-resident mapping alone, so there is nothing more
        // to do for either mode.
        log.warn("DiscardVirtualMemory failed err={d}", .{rc});
        return false;
    }

    // FreeBSD's madvise cannot release pages right away, so map fresh memory
    // over the range instead. See decommitFreeBSD for the details.
    if (comptime builtin.target.os.tag == .freebsd) {
        if (decommitFreeBSD(memory)) return true;
        if (comptime mode == .strict) return false;
        // Zero mode falls through to the memset below.
    }

    if (comptime mode == .zero) @memset(memory[0..dirty_len], 0);
    return false;
}

/// The FreeBSD implementation of `decommit`. It maps fresh memory over
/// `memory` at the same address.
///
/// Returns true when the old pages have been released and the range reads
/// as zeros. Returns false when nothing changed and the original contents
/// are still in place.
///
/// FreeBSD's `madvise` cannot do this job. Both `MADV_DONTNEED` and
/// `MADV_FREE` only mark pages as unused. The pages stay in memory, so the
/// process's memory use does not go down, and the old bytes can still be
/// read until the kernel needs that memory for something else.
///
/// Mapping new memory over the range with `MAP_FIXED` does work. The kernel
/// removes the old mapping and adds the new one while holding the process's
/// memory map lock, so no other thread sees the range in between. Terminal
/// pages are private to this process, so removing the old mapping frees
/// their physical memory immediately. The new mapping starts with no
/// physical memory at all. The kernel supplies a zero-filled page the first
/// time each page is touched. The kernel code this relies on
/// (`vm_map_fixed`) behaves the same from FreeBSD 13.0 through 15.1.
///
/// One failure needs extra care. The kernel can remove the old mapping and
/// then fail to add the new one, which leaves nothing mapped at the address.
/// With default settings this cannot happen. It can happen when swap
/// accounting is strict (the `vm.overcommit` sysctl) or a swap limit is set.
/// The new mapping has to reserve swap space before the old mapping's
/// reservation is returned, so for a moment the process needs twice as much.
/// When this happens, we map the range a second time.
fn decommitFreeBSD(memory: []align(std.heap.page_size_min) u8) bool {
    if (mapFixedFreeBSD(memory)) |err| {
        log.warn("mmap(MAP_FIXED) failed err={}", .{err});
    } else return true;

    // Find out whether the kernel removed the old mapping before it failed.
    // It removes the whole range or none of it, so checking the first page
    // is enough. mincore fails with ENOMEM when the address is not mapped.
    var vec: [1]u8 = undefined;
    if (std.posix.mincore(memory.ptr, std.heap.page_size_min, &vec)) |_| {
        return false;
    } else |err| switch (err) {
        error.OutOfMemory => {},
        else => return false,
    }

    // The old contents are already gone, so if this second mapping works,
    // the result is the same as a successful decommit. The old mapping's
    // swap reservation has been returned by now, so this attempt needs no
    // more swap than the process already had.
    if (mapFixedFreeBSD(memory)) |err| {
        // Nothing is mapped at this address, but the caller still owns the
        // range and will use it again. Stop here with a clear message
        // instead of crashing later on an unexplained memory fault.
        std.debug.panic(
            "mmap(MAP_FIXED) could not restore a discarded page err={}",
            .{err},
        );
    }
    return true;
}

/// Map fresh, zero-filled, private memory over `memory` at the same address.
/// Returns null on success or the error code on failure.
///
/// This calls libc's `mmap` directly instead of `std.posix.mmap`. When the
/// kernel removes the old mapping but cannot add the new one, FreeBSD
/// reports `EINVAL`. `std.posix.mmap` treats `EINVAL` as impossible
/// (`unreachable`), which would crash a safe build and is undefined
/// behavior in a release build.
fn mapFixedFreeBSD(memory: []align(std.heap.page_size_min) u8) ?std.c.E {
    const rc = std.c.mmap(
        memory.ptr,
        memory.len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
        -1,
        0,
    );
    if (rc == std.c.MAP_FAILED) return std.c.errno(@as(c_int, -1));
    assert(@intFromPtr(rc) == @intFromPtr(memory.ptr));
    return null;
}

/// Prepare memory released by `decommit` for reuse.
///
/// Call this before writing new contents into a range that was decommitted.
/// Only Darwin does any work here. It tells the kernel the pages are in use
/// again (`MADV_FREE_REUSE`), so they count toward the process's memory
/// footprint once more. On every other platform, the range is already ready
/// to use when `decommit` returns, so this does nothing.
///
/// This cannot fail in a way the caller needs to handle. If the Darwin call
/// fails, only the memory accounting is off. The range is still usable, so
/// the failure is logged and ignored.
pub fn recommit(memory: []align(std.heap.page_size_min) u8) void {
    assert(memory.len > 0);
    assert(@intFromPtr(memory.ptr) % std.heap.page_size_min == 0);
    assert(memory.len % std.heap.page_size_min == 0);

    if (comptime builtin.is_test) return;
    if (comptime builtin.target.os.tag.isDarwin()) {
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

test "FreeBSD decommit releases pages and reads back zeros" {
    if (comptime builtin.target.os.tag != .freebsd) return error.SkipZigTest;

    // In test builds, decommit only writes zeros and never calls into the
    // operating system. Call the FreeBSD implementation directly instead, on
    // memory this test maps for itself and shares with nothing else.
    const testing = std.testing;
    const posix = std.posix;
    const pages = 4;
    const memory = try posix.mmap(
        null,
        pages * std.heap.page_size_min,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);
    @memset(memory, 0xAA);

    try testing.expect(decommitFreeBSD(memory));

    var vec: [pages]u8 = undefined;
    try posix.mincore(memory.ptr, memory.len, &vec);
    for (vec) |v| try testing.expectEqual(0, v & 1);
    try testing.expect(std.mem.allEqual(u8, memory, 0));
}

test "test builds can reclaim retained mappings" {
    const testing = std.testing;
    try testing.expect(canReclaim(.zero));
    try testing.expect(canReclaim(.strict));
}
