//! Benchmarks the terminal binary snapshot codecs (`terminal/snapshot`).
//!
//! Encoding and decoding a snapshot are the hot paths for terminal
//! persistence and handoff, so both directions are measured against the
//! same terminal state.
//!
//! ## Input
//!
//! `--data` names a pre-generated VT byte stream (for example from
//! `ghostty-gen ascii`). The stream is fed to a terminal of the requested
//! dimensions during setup, outside the timed region. The resulting screen
//! and scrollback contents are what each step encodes or decodes.
//!
//! ## Modes
//!
//! * `noop` performs no codec work and establishes loop overhead.
//! * `encode` encodes one complete snapshot per loop into a reusable
//!   buffer. Buffer growth happens on the first iteration only.
//! * `decode` restores one complete snapshot per loop from bytes prepared
//!   during setup. The restored terminal is destroyed inside the step, so
//!   this measures the complete restore lifecycle.
//! * `decode-ready` restores only the renderable prefix per loop using the
//!   incremental decoder and stops at READY, skipping history. Compared
//!   against `decode`, this is the time-to-interactive win of applying
//!   history off the critical path.
//! * `report` encodes once and prints total and per-record-tag sizes, plus
//!   the byte offsets of READY and the first HISTORY record. It is for
//!   inspecting the wire shape, not timing comparisons. `--output` also
//!   writes the encoded snapshot to a file, for example to measure how it
//!   compresses further down the line.
//!
//! ## Kitty Graphics
//!
//! `--kitty-images` transmits that many Kitty graphics images into the
//! terminal during setup, after the input corpus, each placed at the
//! cursor and followed by enough newlines to push it into scrollback, so
//! images end up both on screen and in history. Each image is either the
//! PNG named by `--kitty-image` or a synthetic RGBA image of
//! `--kitty-width` by `--kitty-height` pixels drawn with `--kitty-pattern`.
//! Synthetic images all differ from each other, while a PNG is repeated
//! as it is, so compressors that look back far enough see repeats.
//!
//! ## Examples
//!
//! Build benchmarks in ReleaseFast mode:
//!
//!     zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
//!
//! Generate a deterministic corpus, then measure both directions:
//!
//!     ghostty-gen ascii | head -c 1000000 > /tmp/ascii.vt
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +terminal-snapshot --mode=encode --loops=20 --data=/tmp/ascii.vt' \
//!       'ghostty-bench +terminal-snapshot --mode=decode --loops=20 --data=/tmp/ascii.vt'
//!
//! Measure a terminal with eight 512x512 textured images, then dump the
//! snapshot to see how it compresses further down the line:
//!
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +terminal-snapshot --mode=encode --kitty-images=8 --kitty-width=512 --kitty-height=512' \
//!       'ghostty-bench +terminal-snapshot --mode=decode --kitty-images=8 --kitty-width=512 --kitty-height=512'
//!     ghostty-bench +terminal-snapshot --mode=report --kitty-images=8 --output=/tmp/images.snap
//!     zstd -3 -c /tmp/images.snap | wc -c
const TerminalSnapshot = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const snapshot = terminalpkg.snapshot;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");
const compat_file = @import("../lib/compat/file.zig");

const log = std.log.scoped(.@"terminal-snapshot-bench");

alloc: Allocator,
opts: Options,
terminal: ?Terminal = null,

/// Reused across encode steps so buffer growth is a one-time setup cost.
encoded: std.Io.Writer.Allocating,

pub const Options = struct {
    /// Set by the shared CLI parser for string option ownership.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the operation performed inside the timed benchmark step.
    mode: Mode = .encode,

    /// Number of codec operations per benchmark step. Increase this when
    /// the state is too small for stable `hyperfine` measurements.
    loops: u32 = 1,

    /// The size of the terminal. This affects wrapping, page sizes, and
    /// the amount of state per encoded page.
    @"terminal-rows": u16 = 24,
    @"terminal-cols": u16 = 80,

    /// Pre-generated VT stream fed to the terminal during setup. `-` reads
    /// stdin, although a regular file is recommended so identical state can
    /// be reused across runs. When unset, the terminal is empty.
    data: ?[]const u8 = null,

    /// In report mode, write the encoded snapshot to this path.
    output: ?[]const u8 = null,

    /// Kitty graphics images transmitted during setup. See "Kitty
    /// Graphics" above.
    @"kitty-images": u32 = 0,

    /// A PNG file to transmit for each image. When unset, a synthetic
    /// image is generated instead.
    @"kitty-image": ?[]const u8 = null,

    /// The size of each synthetic image in pixels.
    @"kitty-width": u32 = 256,
    @"kitty-height": u32 = 256,

    /// What each synthetic image looks like, which decides how well its
    /// pixels compress.
    @"kitty-pattern": KittyPattern = .textured,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const KittyPattern = enum {
    /// One color everywhere. Compresses almost completely.
    flat,

    /// Smooth color ramps. Compresses well.
    gradient,

    /// Ramps with a little noise, like a photograph or a rendered
    /// screenshot. Compresses a little.
    textured,

    /// Random bytes. Does not compress.
    noise,
};

pub const Mode = enum {
    /// Establish the benchmark loop overhead.
    noop,

    /// Encode one complete snapshot per loop.
    encode,

    /// Restore one complete snapshot per loop, including its teardown.
    decode,

    /// Restore one renderable READY prefix per loop, including teardown.
    @"decode-ready",

    /// Print encoded sizes by record tag. Not a timing benchmark.
    report,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalSnapshot {
    const ptr = try alloc.create(TerminalSnapshot);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .encoded = .init(alloc),
    };
    return ptr;
}

pub fn destroy(self: *TerminalSnapshot, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.encoded.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalSnapshot) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .encode => stepEncode,
            .decode => stepDecode,
            .@"decode-ready" => stepDecodeReady,
            .report => stepReport,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

/// Build the terminal state every mode shares and, for decode mode, the
/// encoded snapshot it restores. All of this is outside the timed region.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    self.setupImpl() catch |err| {
        log.warn("failed to prepare snapshot benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn setupImpl(self: *TerminalSnapshot) !void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.terminal = try Terminal.init(global.io(), self.alloc, .{
        .cols = self.opts.@"terminal-cols",
        .rows = self.opts.@"terminal-rows",
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    const terminal = &self.terminal.?;

    // Feed the input corpus through the standard VT stream.
    if (try options.dataFile(self.opts.data)) |data_f| {
        defer data_f.close(global.io());

        var stream = terminal.vtStream();
        defer stream.deinit();

        var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var f_reader = data_f.reader(global.io(), &read_buf);
        const r = &f_reader.interface;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try r.readSliceShort(&buf);
            if (n == 0) break; // EOF reached
            stream.nextSlice(buf[0..n]);
        }
    }

    // Kitty graphics images, after the corpus so the last ones are on
    // screen and the earlier ones are in scrollback.
    if (self.opts.@"kitty-images" > 0) try self.setupKittyImages(terminal);

    // Decode restores the same bytes every step. Encode mode also uses
    // this buffer, in which case this is its one-time growth.
    self.encoded.shrinkRetainingCapacity(0);
    try snapshot.encode(
        self.alloc,
        &self.encoded.writer,
        terminal,
        .{ .continuation = .ground },
    );
}

/// Transmit and place the requested Kitty graphics images.
fn setupKittyImages(self: *TerminalSnapshot, terminal: *Terminal) !void {
    const opts = &self.opts;

    // A PNG is sent as it is, for every image. Synthetic images are drawn
    // once per image from a different seed, so no two are alike and a
    // compressor cannot shrink the snapshot by matching whole images.
    const png: ?[]u8 = png: {
        const f = try options.dataFile(opts.@"kitty-image") orelse break :png null;
        defer f.close(global.io());
        break :png try compat_file.readToEndAlloc(f, self.alloc, 64 * 1024 * 1024);
    };
    defer if (png) |bytes| self.alloc.free(bytes);
    const width = opts.@"kitty-width";
    const height = opts.@"kitty-height";
    const rgba: ?[]u8 = if (png == null)
        try self.alloc.alloc(u8, @as(usize, width) * height * 4)
    else
        null;
    defer if (rgba) |bytes| self.alloc.free(bytes);

    const encoder = std.base64.standard.Encoder;
    const encoded = try self.alloc.alloc(u8, encoder.calcSize(
        if (png) |bytes| bytes.len else rgba.?.len,
    ));
    defer self.alloc.free(encoded);

    // Each image covers a block of cells at the cursor, then newlines move
    // the cursor below it so the next image lands lower and earlier ones
    // scroll into history.
    const cols: u32 = @min(opts.@"terminal-cols", 40);
    const rows: u32 = @min(opts.@"terminal-rows", 8);

    var command: std.Io.Writer.Allocating = .init(self.alloc);
    defer command.deinit();
    var stream = terminal.vtStream();
    defer stream.deinit();
    for (0..opts.@"kitty-images") |i| {
        if (rgba) |pixels| drawPattern(pixels, width, height, opts.@"kitty-pattern", i);
        _ = encoder.encode(encoded, png orelse rgba.?);

        command.shrinkRetainingCapacity(0);
        const w = &command.writer;
        var chunks = std.mem.window(u8, encoded, 4096, 4096);
        var first = true;
        while (chunks.next()) |chunk| : (first = false) {
            const more: u8 = @intFromBool(chunks.index != null);
            if (first) {
                try w.print("\x1b_Ga=T,i={d},c={d},r={d},C=1,q=2,m={d},", .{
                    i + 1,
                    cols,
                    rows,
                    more,
                });
                if (png != null) try w.writeAll("f=100;") else try w.print(
                    "f=32,s={d},v={d};",
                    .{ width, height },
                );
            } else try w.print("\x1b_Gm={d};", .{more});
            try w.writeAll(chunk);
            try w.writeAll("\x1b\\");
        }
        for (0..rows) |_| try w.writeAll("\r\n");
        stream.nextSlice(command.written());
    }

    const storage = &terminal.screens.active.kitty_images;
    if (storage.images.count() != opts.@"kitty-images") {
        log.warn(
            "only {d} of {d} kitty images were stored",
            .{ storage.images.count(), opts.@"kitty-images" },
        );
        return error.KittyImagesDropped;
    }
}

/// Fill `rgba` with one image of the pattern. `seed` varies the image.
fn drawPattern(
    rgba: []u8,
    width: u32,
    height: u32,
    pattern: KittyPattern,
    seed: u64,
) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    // Flat and gradient images differ by their base color.
    const base: [3]u8 = .{
        random.int(u8),
        random.int(u8),
        random.int(u8),
    };

    for (0..height) |y| for (0..width) |x| {
        const px = rgba[(y * width + x) * 4 ..][0..4];
        switch (pattern) {
            .flat => px.* = .{ base[0], base[1], base[2], 0xff },
            .gradient, .textured => {
                px.* = .{
                    @intCast((base[0] + x * 255 / width) % 256),
                    @intCast((base[1] + y * 255 / height) % 256),
                    @intCast((base[2] + (x + y) * 255 / (width + height)) % 256),
                    0xff,
                };
                if (pattern == .textured) for (px[0..3]) |*c| {
                    const noise = random.intRangeAtMost(i16, -8, 8);
                    c.* = @intCast(std.math.clamp(@as(i16, c.*) + noise, 0, 255));
                };
            },
            .noise => random.bytes(px),
        }
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.encoded.shrinkRetainingCapacity(0);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        std.mem.doNotOptimizeAway(self.encoded.written());
    }
}

fn stepEncode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const terminal = &self.terminal.?;
    for (0..self.opts.loops) |_| {
        self.encoded.shrinkRetainingCapacity(0);
        snapshot.encode(
            self.alloc,
            &self.encoded.writer,
            terminal,
            .{ .continuation = .ground },
        ) catch |err| {
            log.warn("snapshot encoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(self.encoded.written());
    }
}

fn stepDecode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();
    for (0..self.opts.loops) |_| {
        var reader: std.Io.Reader = .fixed(bytes);
        var decoded = snapshot.decode(
            self.alloc,
            global.io(),
            &reader,
            .{ .max_continuation_bytes = 1024 * 1024 },
        ) catch |err| {
            log.warn("snapshot decoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&decoded);
        decoded.deinit(self.alloc);
    }
}

/// The renderable-prefix half of decode: everything through READY, leaving
/// all history unread. The gap between this and `stepDecode` is the latency
/// class the incremental decoder removes from time-to-interactive.
fn stepDecodeReady(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();
    for (0..self.opts.loops) |_| {
        var reader: std.Io.Reader = .fixed(bytes);
        var decoder: snapshot.Decoder = .init(&reader);
        var decoded = decoder.ready(
            self.alloc,
            global.io(),
            .{ .max_continuation_bytes = 1024 * 1024 },
        ) catch |err| {
            log.warn("snapshot READY decoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&decoded);
        decoded.deinit(self.alloc);
    }
}

/// Print the encoded size grouped by record tag. This shares the encoder
/// with encode mode but deliberately makes no timing claims.
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();

    // A record tag can hold values that `Tag` does not name, so totals are
    // kept per named tag rather than in an EnumArray over every value.
    const tags = comptime std.enums.values(snapshot.record.Tag);
    var payload_totals: [tags.len]u64 = @splat(0);
    var record_counts: [tags.len]u64 = @splat(0);
    var record_total: u64 = 0;

    // Where the decoder can first render, and where scrollback starts
    // arriving: the end of READY and the start of the first HISTORY.
    var ready_end: ?usize = null;
    var history_start: ?usize = null;

    var offset: usize = snapshot.envelope.encoded_len;
    while (offset + snapshot.record.Header.len <= bytes.len) {
        const tag_raw = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const payload_len = std.mem.readInt(
            u32,
            bytes[offset + 2 ..][0..4],
            .little,
        );
        const tag: snapshot.record.Tag = @fromBackingInt(tag_raw);
        const index = std.mem.indexOfScalar(
            snapshot.record.Tag,
            tags,
            tag,
        ) orelse {
            log.warn("unknown record tag {}", .{tag_raw});
            return error.BenchmarkFailed;
        };
        payload_totals[index] += payload_len;
        record_counts[index] += 1;
        record_total += 1;
        offset += snapshot.record.Header.len + payload_len;
        switch (tag) {
            .ready => ready_end = offset,
            .history => if (history_start == null) {
                history_start = offset - snapshot.record.Header.len - payload_len;
            },
            else => {},
        }
    }

    for (tags, payload_totals, record_counts) |tag, payload, records| {
        std.debug.print("terminal-snapshot tag={s} records={d} payload={d}\n", .{
            @tagName(tag),
            records,
            payload,
        });
    }
    std.debug.print(
        "terminal-snapshot total records={d} framing={d} encoded={d}\n",
        .{
            record_total,
            record_total * snapshot.record.Header.len +
                snapshot.envelope.encoded_len,
            bytes.len,
        },
    );
    std.debug.print(
        "terminal-snapshot ready_end={d} history_start={d}\n",
        .{ ready_end orelse 0, history_start orelse 0 },
    );

    if (self.opts.output) |path| {
        std.Io.Dir.cwd().writeFile(global.io(), .{
            .sub_path = path,
            .data = bytes,
        }) catch |err| {
            log.warn("failed to write snapshot to {s} err={}", .{ path, err });
            return error.BenchmarkFailed;
        };
    }
}

test TerminalSnapshot {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot decode round trip" {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .decode,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot report" {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .report,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot kitty images round trip" {
    if (comptime !@import("terminal_options").kitty_graphics) return error.SkipZigTest;
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .decode,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
        .@"kitty-images" = 3,
        .@"kitty-width" = 4,
        .@"kitty-height" = 4,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot decode READY prefix" {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .@"decode-ready",
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
