//! Measures the effect of cold-hints on physical memory (RSS/footprint)
//! for a PageList with deep scrollback across six phases:
//!
//!   1. fill:       grow total-rows rows; RSS after all pages faulted in
//!   2. hint:       apply production lazy hints (MADV_COLD/FREE); RSS unchanged
//!   3. reclaim:    force-reclaim cold pages (MADV_FREE_REUSABLE/DONTNEED)
//!                  and show the immediate RSS drop
//!   4. seq-scroll: scroll-passes sequential passes through all cold pages;
//!                  pass 1 is cold (page faults), passes 2-N are warm (in RAM)
//!   5. re-reclaim: reclaim again to reset state between scroll scenarios
//!   6. rnd-scroll: scroll-passes random-order passes through all cold pages;
//!                  same cold-then-warm pattern as phase 4 but with random access
//!
//! Pass-1 latency (cold) vs pass-2+ latency (warm) shows the cost of page
//! faults on first access to deep scrollback.
//!
//! Usage: ghostty-bench +scrollback-memory
//!        ghostty-bench +scrollback-memory --total-rows=3000000 --hot-rows=10000 --scroll-passes=5
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const PageList = @import("../terminal/PageList.zig");
const Benchmark = @import("Benchmark.zig");

const ScrollbackMemory = @This();

const log = std.log.scoped(.@"scrollback-memory-bench");

const MiB = 1024 * 1024;

opts: Options,
page_list: ?PageList = null,

pub const Options = struct {
    /// Total rows to grow the PageList to. At least hot-rows must be reached
    /// for any cold-hint pages to exist. Default gives ~3 GiB cold zone at
    /// 80 cols (roughly 215 rows/page * 512 KiB/page).
    @"total-rows": u32 = 3_000_000,

    /// Rows to keep hot. Should match scrollback_hot_rows in PageList.zig.
    @"hot-rows": u32 = 10_000,

    /// Terminal column count.
    cols: u16 = 80,

    /// Number of scroll passes per phase. Pass 1 is always cold (page faults);
    /// passes 2-N are warm (pages already in RAM). Comparing pass-1 latency
    /// to pass-2 latency shows the cost of cold scrollback access.
    @"scroll-passes": u32 = 3,
};

pub fn create(alloc: Allocator, opts: Options) !*ScrollbackMemory {
    const ptr = try alloc.create(ScrollbackMemory);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *ScrollbackMemory, alloc: Allocator) void {
    if (self.page_list) |*pl| pl.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *ScrollbackMemory) Benchmark {
    return .init(self, .{
        .setupFn = setup,
        .stepFn = step,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackMemory = @ptrCast(@alignCast(ptr));
    const alloc = std.heap.page_allocator;
    const hot_rows = self.opts.@"hot-rows";
    const total: u32 = self.opts.@"total-rows";

    self.page_list = PageList.init(
        alloc,
        self.opts.cols,
        24,
        null,
    ) catch return error.BenchmarkFailed;

    const pl = &self.page_list.?;

    // Phase 1: fill
    var timer = std.time.Timer.start() catch return error.BenchmarkFailed;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        _ = pl.grow() catch return error.BenchmarkFailed;
    }
    const fill_us = timer.read() / std.time.ns_per_us;
    const rss1 = physicalFootprintBytes();
    log.info("[1/6] fill {d} rows in {d} us  RSS = {d} MiB  total_page_mem = {d} KiB", .{
        total,
        fill_us,
        rss1 / MiB,
        pl.page_size / 1024,
    });

    // Phase 2: production cold-hints (lazy)
    timer.reset();
    applyLazyHints(pl, hot_rows);
    const hint_us = timer.read() / std.time.ns_per_us;
    const rss2 = physicalFootprintBytes();
    const hint_delta: i64 = @as(i64, @intCast(rss2 / MiB)) - @as(i64, @intCast(rss1 / MiB));
    log.info("[2/6] hint cold (lazy) in {d} us  RSS = {d} MiB  delta = {d} MiB", .{
        hint_us,
        rss2 / MiB,
        hint_delta,
    });

    // Phase 3: force-reclaim
    timer.reset();
    forceReclaimColdPages(pl, hot_rows);
    const reclaim_us = timer.read() / std.time.ns_per_us;
    const rss3 = physicalFootprintBytes();
    log.info("[3/6] force reclaim in {d} us  RSS = {d} MiB  reclaimed = {d} MiB", .{
        reclaim_us,
        rss3 / MiB,
        if (rss2 > rss3) (rss2 - rss3) / MiB else 0,
    });

    // Phase 4: rapid sequential scroll passes.
    // Pass 1 is cold (page faults from MADV_FREE_REUSABLE/DONTNEED state).
    // Passes 2-N are warm (pages remain in RAM between passes, no reclaim).
    // The latency gap between pass 1 and pass 2 is the cost of first-access
    // to deep cold scrollback.
    var prev_rss: usize = rss3;
    for (0..self.opts.@"scroll-passes") |pass| {
        const t0 = std.time.Instant.now() catch return error.BenchmarkFailed;
        touchColdPagesSequential(pl, hot_rows);
        const t1 = std.time.Instant.now() catch return error.BenchmarkFailed;
        const pass_us = t1.since(t0) / std.time.ns_per_us;
        const pass_rss = physicalFootprintBytes();
        const delta4: i64 = @as(i64, @intCast(pass_rss / MiB)) - @as(i64, @intCast(prev_rss / MiB));
        log.info("[4/6] seq pass {d}/{d} in {d} us  RSS = {d} MiB  delta = {d} MiB", .{
            pass + 1,
            self.opts.@"scroll-passes",
            pass_us,
            pass_rss / MiB,
            delta4,
        });
        prev_rss = pass_rss;
    }

    // Phase 5: re-reclaim to reset state before random-access scroll passes.
    timer.reset();
    forceReclaimColdPages(pl, hot_rows);
    const rereclaim_us = timer.read() / std.time.ns_per_us;
    const rss5 = physicalFootprintBytes();
    log.info("[5/6] re-reclaim in {d} us  RSS = {d} MiB  reclaimed = {d} MiB", .{
        rereclaim_us,
        rss5 / MiB,
        if (prev_rss > rss5) (prev_rss - rss5) / MiB else 0,
    });

    // Phase 6: rapid random-access scroll passes.
    // Same cold-then-warm pattern as phase 4 but with randomized page order,
    // simulating a user jumping to arbitrary positions in deep scrollback.
    prev_rss = rss5;
    for (0..self.opts.@"scroll-passes") |pass| {
        const t0 = std.time.Instant.now() catch return error.BenchmarkFailed;
        touchColdPagesRandom(pl, hot_rows, alloc) catch return error.BenchmarkFailed;
        const t1 = std.time.Instant.now() catch return error.BenchmarkFailed;
        const pass_us = t1.since(t0) / std.time.ns_per_us;
        const pass_rss = physicalFootprintBytes();
        const delta6: i64 = @as(i64, @intCast(pass_rss / MiB)) - @as(i64, @intCast(prev_rss / MiB));
        log.info("[6/6] rnd  pass {d}/{d} in {d} us  RSS = {d} MiB  delta = {d} MiB", .{
            pass + 1,
            self.opts.@"scroll-passes",
            pass_us,
            pass_rss / MiB,
            delta6,
        });
        prev_rss = pass_rss;
    }
}

/// step: no-op. All timed work is in setup.
fn step(_: *anyopaque) Benchmark.Error!void {}

fn teardown(ptr: *anyopaque) void {
    const self: *ScrollbackMemory = @ptrCast(@alignCast(ptr));
    if (self.page_list) |*pl| {
        pl.deinit();
        self.page_list = null;
    }
}

/// Apply the same lazy hints that production code uses (MADV_COLD on Linux,
/// MADV_FREE on macOS). Pages stay resident until the OS needs memory.
fn applyLazyHints(pl: *PageList, hot_rows: u32) void {
    var warm: usize = 0;
    var it = pl.pages.last;
    while (it) |node| : (it = node.prev) {
        warm += node.data.size.rows;
        if (warm >= hot_rows) {
            var cold = node.prev;
            while (cold) |c| : (cold = c.prev) {
                c.data.hintCold();
            }
            return;
        }
    }
}

/// Write one non-zero byte to every OS page within the slice to force physical
/// backing after MADV_FREE_REUSABLE. Touching only the first byte per Page
/// allocation faults in 1 physical page out of potentially hundreds; striding
/// by page_size_min touches every physical page in the allocation. On macOS,
/// also calls MADV_FREE_REUSE to re-register the allocation with phys_footprint
/// (MADV_FREE_REUSABLE opts pages out of accounting; writes alone are not enough).
fn touchAllOsPages(mem: []align(std.heap.page_size_min) u8) void {
    var offset: usize = 0;
    while (offset < mem.len) : (offset += std.heap.page_size_min) {
        @as(*volatile u8, @ptrCast(&mem[offset])).* = 0xFF;
    }
    if (builtin.os.tag.isDarwin()) {
        // Apple-private constant: MADV_FREE_REUSE = 8 is the counterpart to
        // MADV_FREE_REUSABLE = 7. It re-registers pages with phys_footprint.
        std.posix.madvise(mem.ptr, mem.len, 8) catch {};
    }
}

/// Walk cold pages from oldest to newest and touch every OS page within each
fn touchColdPagesSequential(pl: *PageList, hot_rows: u32) void {
    var warm: usize = 0;
    var it = pl.pages.last;
    while (it) |node| : (it = node.prev) {
        warm += node.data.size.rows;
        if (warm >= hot_rows) {
            var cold = node.prev;
            while (cold) |c| : (cold = c.prev) {
                touchAllOsPages(c.data.memory);
            }
            return;
        }
    }
}

/// Collect cold page pointers, shuffle them with a deterministic PRNG, then
/// touch each one to simulate jumping to an arbitrary scrollback position.
fn touchColdPagesRandom(
    pl: *PageList,
    hot_rows: u32,
    alloc: Allocator,
) !void {
    // Each entry is [addr, len] so touchAllOsPages can stride the full allocation.
    var slices: std.ArrayList([2]usize) = .empty;
    defer slices.deinit(alloc);

    var warm: usize = 0;
    var it = pl.pages.last;
    while (it) |node| : (it = node.prev) {
        warm += node.data.size.rows;
        if (warm >= hot_rows) {
            var cold = node.prev;
            while (cold) |c| : (cold = c.prev) {
                try slices.append(alloc, .{
                    @intFromPtr(c.data.memory.ptr),
                    c.data.memory.len,
                });
            }
            break;
        }
    }

    var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafef00d);
    prng.random().shuffle([2]usize, slices.items);

    for (slices.items) |s| {
        const mem: []align(std.heap.page_size_min) u8 =
            @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(s[0]))[0..s[1]];
        touchAllOsPages(mem);
    }
}

/// Walk backward from the newest page, skip the first hot_rows rows, then
/// call madvise with an immediately-effective advice on every cold page.
fn forceReclaimColdPages(pl: *PageList, hot_rows: u32) void {
    const posix = std.posix;
    // Apple-private constant from <sys/mman.h>. Not in Zig's posix.MADV because
    // it is non-POSIX. Unlike MADV_FREE (5) which is lazy, MADV_FREE_REUSABLE (7)
    // immediately decrements task phys_footprint so the delta shows up in RSS.
    const MADV_FREE_REUSABLE: u32 = 7;
    const advice: u32 = if (builtin.os.tag.isDarwin())
        MADV_FREE_REUSABLE
    else
        @intCast(posix.MADV.DONTNEED); // immediate reclaim on Linux

    var warm: usize = 0;
    var it = pl.pages.last;
    while (it) |node| : (it = node.prev) {
        warm += node.data.size.rows;
        if (warm >= hot_rows) {
            var cold = node.prev;
            while (cold) |c| : (cold = c.prev) {
                posix.madvise(c.data.memory.ptr, c.data.memory.len, advice) catch {};
            }
            return;
        }
    }
}

/// Return the current physical memory footprint in bytes. On macOS this reads
/// task_vm_info.phys_footprint. On Linux it reads VmRSS from
/// /proc/self/status. On other platforms it returns 0.
fn physicalFootprintBytes() usize {
    if (builtin.os.tag.isDarwin()) return macosFootprint();
    if (builtin.os.tag == .linux) return linuxRss();
    return 0;
}

fn macosFootprint() usize {
    const c = @cImport({
        @cInclude("mach/mach.h");
    });
    var info: c.task_vm_info_data_t = undefined;
    var count: c.mach_msg_type_number_t = c.TASK_VM_INFO_COUNT;
    const kr = c.task_info(
        c.mach_task_self(),
        c.TASK_VM_INFO,
        @ptrCast(&info),
        &count,
    );
    if (kr != c.KERN_SUCCESS) return 0;
    return @intCast(info.phys_footprint);
}

fn linuxRss() usize {
    var buf: [4096]u8 = undefined;
    var file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
    defer file.close();
    const n = file.readAll(&buf) catch return 0;
    const contents = buf[0..n];
    // Find "VmRSS:\t<kb> kB"
    const prefix = "VmRSS:";
    const idx = std.mem.indexOf(u8, contents, prefix) orelse return 0;
    const rest = std.mem.trimLeft(u8, contents[idx + prefix.len ..], " \t");
    const end = std.mem.indexOfAny(u8, rest, " \t\n") orelse rest.len;
    const kb = std.fmt.parseInt(usize, rest[0..end], 10) catch return 0;
    return kb * 1024;
}
