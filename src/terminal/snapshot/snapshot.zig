//! Complete terminal snapshot encoding and restoration.

const std = @import("std");
const build_options = @import("terminal_options");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const checkpoint = @import("checkpoint.zig");
const continuation = @import("continuation.zig");
const envelope = @import("envelope.zig");
const test_fixture = @import("fixture.zig");
const history = @import("history.zig");
const kitty = @import("kitty.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const size = @import("../size.zig");
const terminal = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const terminal_kitty = @import("../kitty.zig");
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;

/// Re-export continuation to make it a bit more ergonomic to reference.
pub const Continuation = continuation.Value;

/// Errors possible while encoding one complete terminal snapshot.
pub const EncodeError = terminal.EncodeError ||
    screen.EncodeError ||
    history.EncodeError ||
    kitty.EncodeError ||
    checkpoint.EncodeError ||
    continuation.EncodeError;

pub const EncodeOptions = struct {
    continuation: Continuation,
};

/// Encode one complete terminal snapshot.
///
/// Encoding starts at the destination's current position. Only one record
/// payload is buffered at a time; completed records stream immediately. On
/// failure, the destination may contain a snapshot prefix without its required
/// FINISH marker, and an output failure may have written part of a record.
pub fn encode(
    alloc: Allocator,
    destination: *std.Io.Writer,
    t: *const Terminal,
    options: EncodeOptions,
) EncodeError!void {
    // Continuation errors must not emit even the snapshot envelope.
    try continuation.validate(options.continuation);

    // A measured 512-byte buffer handles our smallest records on the stack
    // before larger records fall back to the heap.
    var stack_alloc_buf: [512]u8 = undefined;
    var stack_alloc: std.heap.BufferFirstAllocator = .init(&stack_alloc_buf, alloc);
    var stream: record.Writer = .init(stack_alloc.allocator(), destination);
    defer stream.deinit();

    // Plan each screen's Kitty graphics records up front. A screen without
    // images has no plan and gets no Kitty graphics records at all.
    var kitty_plans: std.EnumArray(TerminalScreenKey, ?kitty.Plan) = .initFill(null);
    defer if (comptime build_options.kitty_graphics) {
        for (&kitty_plans.values) |*plan| {
            if (plan.*) |*p| p.deinit();
        }
    };
    if (comptime build_options.kitty_graphics) {
        for (std.enums.values(TerminalScreenKey)) |key| {
            const s = t.screens.get(key) orelse continue;
            kitty_plans.set(key, try kitty.ScreenPlan.init(
                alloc,
                s,
                key,
            ));
        }
    }

    // 1. Envelope
    try envelope.encode(stream.writer());

    // 2. Terminal
    try terminal.encode(t, &stream);

    // 3. Each screen, followed by its Kitty graphics images and
    // placements. Screens may appear in any key order, so this visits
    // every key and skips screens that don't exist.
    for (std.enums.values(TerminalScreenKey)) |key| {
        const s = t.screens.get(key) orelse continue;
        try screen.encode(s, key, &stream);
        if (comptime build_options.kitty_graphics) {
            if (kitty_plans.getPtr(key).*) |*plan| {
                try plan.encodeStorage(&stream);
            }
        }
    }

    // 4. Standard Stream continuation.
    try continuation.encode(options.continuation, &stream);

    // 5. Ready marker.
    try checkpoint.encode(.ready, &stream);

    // Kitty graphics pixels are written in the order the reader needs
    // them, and the screen that is shown comes first in that order, so
    // what the reader can see arrives before what it cannot.
    const active_key = t.screens.active_key;
    const other_keys: []const TerminalScreenKey = switch (active_key) {
        inline else => |active| comptime other: {
            var keys: []const TerminalScreenKey = &.{};
            for (std.enums.values(TerminalScreenKey)) |key| {
                if (key != active) keys = keys ++ .{key};
            }
            break :other keys;
        },
    };

    // 6. The pixels of the Kitty graphics images in the shown screen's
    // viewport. They come after READY so the decoder can show the terminal
    // without waiting for them, and before history so the reader can draw
    // what is on screen as soon as possible.
    if (comptime build_options.kitty_graphics) {
        if (kitty_plans.getPtr(active_key).*) |*plan| {
            try plan.encodeViewportPayloads(&stream);
        }
    }

    // 7. Each screen's history, with the Kitty graphics placements pinned
    // to each page and the pixels of the images first placed there.
    for (std.enums.values(TerminalScreenKey)) |key| {
        const s = t.screens.get(key) orelse continue;
        const plan: ?*kitty.Plan = if (kitty_plans.getPtr(key).*) |*p| p else null;
        try history.encode(
            s,
            key,
            &stream,
            plan,
        );
    }

    // 8. The pixels nothing is waiting on: images in the viewport of a
    // screen that is not shown, then every image that is not placed where
    // the reader can see it.
    if (comptime build_options.kitty_graphics) {
        for (other_keys) |key| {
            if (kitty_plans.getPtr(key).*) |*plan| {
                try plan.encodeViewportPayloads(&stream);
            }
        }
        if (kitty_plans.getPtr(active_key).*) |*plan| {
            try plan.encodeRemainingPayloads(&stream);
        }
        for (other_keys) |key| {
            if (kitty_plans.getPtr(key).*) |*plan| {
                try plan.encodeRemainingPayloads(&stream);
            }
        }
    }

    // 9. Finish
    try checkpoint.encode(.finish, &stream);
}

/// Errors possible while restoring one complete terminal snapshot.
pub const DecodeError = Decoder.ReadyError || Decoder.NextError;

pub const DecodeOptions = struct {
    /// Largest non-ground continuation the decoder may allocate and return.
    /// Set this to zero when only ground-state snapshots are acceptable.
    max_continuation_bytes: usize,

    /// Compress each history page as soon as it is restored.
    ///
    /// Without this, restored history stays uncompressed until the caller
    /// runs `Terminal.compress`. With it, the decode holds at most one
    /// uncompressed history page at a time and the restored terminal starts
    /// out compressed.
    ///
    /// A page that is on screen when it is restored stays uncompressed.
    /// This only happens with `Decoder` if the caller scrolls the viewport
    /// to the top of the scrollback between `next` calls.
    ///
    /// The snapshot format is unchanged, so this works with any snapshot.
    /// It has no effect on platforms that do not support compression.
    compress_history: bool = false,

    /// The Kitty graphics image storage limit, in bytes, for each restored
    /// screen, or null for the default limit of a new screen.
    ///
    /// The limit of the terminal that wrote the snapshot is not part of the
    /// snapshot, so the decoder always applies this one. Images are restored
    /// oldest first, and an image that does not fit evicts older images,
    /// exactly as a live transmission would. The newest images are kept.
    /// Zero disables Kitty graphics on the restored terminal.
    kitty_image_storage_limit: ?usize = null,
};

/// One decoded Terminal and the bytes needed to resume its Stream.
///
/// `decode` returns this with all history present; `Decoder.ready` returns
/// it at READY, when the terminal is complete for interactive use but its
/// scrollback is still arriving through `Decoder.next`.
///
/// A successful decode owns both values. Keep this result alive until the
/// Terminal's Stream has been restored, and always finish by calling `deinit`.
/// The usual restoration sequence is:
///
///   1. Inspect `continuation` and use its length to size continuation tracking.
///   2. Call `toOwned` once and store the returned Terminal at its final address.
///   3. Create the persistent, read-only standard TerminalStream for that
///      address. If `continuation` contains bytes, feed them exactly once and
///      verify that re-exporting the continuation returns the same bytes.
///   4. Call `deinit` to release the decoded continuation. The transferred
///      Terminal and its Stream remain owned by the caller.
///   5. Process PTY bytes that came after the snapshot cut.
///
/// Do not create a Stream against the address of `terminal` in this struct.
/// `toOwned` moves the Terminal, which would leave such a Stream pointing at
/// its old address.
pub const Decoded = struct {
    /// Present until `toOwned` transfers the Terminal to the caller. Callers
    /// may inspect it, but must transfer it before attaching a persistent
    /// TerminalStream.
    terminal: ?Terminal,

    /// For decoded results, nonempty bytes are allocator-owned and remain
    /// valid until `deinit`. Ground needs no replay. Bytes must be replayed
    /// exactly once after the Terminal has reached its final address.
    continuation: Continuation,

    /// Advisory complete logical history extent declared by each restored
    /// screen, including the resident overlap already carried by that
    /// screen's own pages. A client may size scrollback UI from this at
    /// READY, before HISTORY pages arrive; native row totals always remain
    /// derived from the pages actually applied.
    history_rows: std.EnumMap(TerminalScreenKey, u64),

    /// For each screen, how many Kitty graphics images were restored and
    /// how many bytes of their pixels are still to come through
    /// `Decoder.next`. Screens without images, and every screen in a build
    /// without Kitty graphics, report zeros.
    ///
    /// This is meant for showing progress while the pixels arrive:
    ///
    /// ```zig
    /// const total = decoded.kitty.get(.primary).pending_bytes;
    /// var received: u64 = 0;
    /// while (try decoder.next(alloc, &terminal)) |progress| switch (progress) {
    ///     .image => |image| if (image.key == .primary) {
    ///         received += image.bytes;
    ///     },
    ///     .page => {},
    /// };
    /// ```
    ///
    /// Pixels that the decoder drops report zero bytes, so `received` can
    /// end up below `total`. Pixels may arrive between history pages, so
    /// they are only known to be done once `next` returns null.
    kitty: std.EnumArray(TerminalScreenKey, kitty.Counts) = .initFill(.{}),

    /// Destroy an untransferred Terminal and always free continuation bytes.
    /// After `toOwned`, this leaves the caller-owned Terminal untouched.
    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        if (self.terminal) |*value| value.deinit(alloc);
        switch (self.continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        }
        self.* = undefined;
    }

    /// Transfer the Terminal while retaining the continuation for replay.
    ///
    /// This may be called exactly once. Store the returned value directly at
    /// its final address before creating the TerminalStream that will replay
    /// `continuation`.
    pub fn toOwned(self: *Decoded) Terminal {
        const result = self.terminal.?;
        self.terminal = null;
        return result;
    }
};

/// Incrementally restore one snapshot: renderable state first, then history.
///
/// The snapshot record order makes a terminal renderable at the READY
/// marker, after only a small prefix of the stream. `Decoder` exposes
/// that boundary: `ready` returns a complete, integrity-checked `Decoded` while
/// scrollback is still in flight, and each `next` call then applies one
/// history PAGE record off the critical path. `snapshot.decode` is the
/// one-shot form and is implemented over this type.
///
/// ```zig
/// var decoder: snapshot.Decoder = .init(&reader);
/// var decoded = try decoder.ready(alloc, io, .{
///     .max_continuation_bytes = 1024 * 1024,
/// });
/// defer decoded.deinit(alloc);
///
/// var terminal = decoded.toOwned();
/// defer terminal.deinit(alloc);
/// // The terminal is usable now: restore its Stream from the decoded
/// // continuation and size scrollback UI from `decoded.history_rows`.
///
/// while (try decoder.next(alloc, &terminal)) |progress| {
///     _ = progress; // Scrollback grew; e.g. refresh the scrollbar.
/// }
/// // FINISH validated: the complete snapshot has been decoded.
/// ```
///
/// The terminal is live between `next` calls: the caller may render it and
/// even feed it PTY bytes that arrived after the snapshot cut. `next`
/// re-validates its destination on every call and degrades to discarding,
/// consuming and validating wire bytes without applying them, when live
/// changes have made a page inapplicable. See `next` for the drop rules.
///
/// The decoder owns no allocations and needs no deinit. It retains the
/// source pointer given to `init`; the source must stay valid, and must not
/// be read elsewhere, until decoding ends. The decoder itself is movable
/// between calls. After any returned error both the decoder and the stream
/// position are invalid: abandon the decoder, and destroy an already
/// transferred Terminal or keep it with partial history, but do not resume.
pub const Decoder = struct {
    source: *std.Io.Reader,
    state: State,

    const State = union(enum) {
        /// `ready` has not been called.
        start,

        /// READY validated; HISTORY sequences remain before FINISH.
        history: History,

        /// FINISH validated. `next` returns null.
        finished,

        /// A call returned an error; the stream position is unknown.
        failed,
    };

    const History = struct {
        /// The generation observed at READY for every screen the snapshot
        /// declared. Presence is the declaration check for HISTORY routing;
        /// the value detects screens removed or replaced by live terminal
        /// use between calls.
        generations: std.EnumMap(TerminalScreenKey, usize),

        /// Keys whose HISTORY sequence was already consumed.
        routed: std.EnumSet(TerminalScreenKey),

        /// HISTORY sequences that have not begun streaming yet.
        pending: usize,

        /// The sequence currently streaming PAGE records.
        current: ?Sequence,

        /// Terminal width at READY. Encoded pages assume this width and are
        /// dropped rather than mixed into a screen reflowed to another.
        cols: size.CellCountInt,

        /// Options for each history page, taken from `ready`.
        page_options: history.DecodeOptions,

        /// The Kitty graphics image storage generation of each screen at
        /// READY. History placements only attach to images that were
        /// restored at READY. See `kitty.PageTarget.ready_generation`.
        kitty_generations: std.EnumMap(TerminalScreenKey, u64),

        /// A record header already read from the source but not decoded yet.
        /// After each history PAGE, the decoder reads the next header to see
        /// whether that page's KITTY_IMAGE_PAGE_PLACEMENTS follows. If it is
        /// some other record, its header waits here for the next call.
        pending_header: ?record.Header = null,

        /// An error from reading that next header. The page before it was
        /// already applied, so the call that applied it still reports the
        /// page, and the error is returned by the following call instead.
        pending_error: ?record.NextHeaderError = null,
    };

    const Sequence = struct {
        key: TerminalScreenKey,

        /// PAGE records not yet consumed from this sequence.
        remaining: u32,

        /// False once any page in this sequence was dropped. Later pages
        /// are older, and applying one above a gap would corrupt scrollback
        /// order, so a single drop discards the remainder of the sequence.
        apply: bool,
    };

    /// The decoder begins reading only when `ready` is called.
    pub fn init(source: *std.Io.Reader) Decoder {
        return .{
            .source = source,
            .state = .start,
        };
    }

    /// Errors possible while decoding the renderable prefix through READY.
    pub const ReadyError = kitty.DecodeError ||
        envelope.DecodeError ||
        terminal.DecodeError ||
        screen.DecodeError ||
        continuation.DecodeError ||
        checkpoint.DecodeError ||
        error{
            /// A SCREEN names a key not declared by TERMINAL.
            UnexpectedScreenKey,

            /// More than one SCREEN names the same key.
            DuplicateScreen,
        };

    /// Decode through the READY marker and return the renderable state.
    ///
    /// The result is transactional and complete for interactive use: the
    /// Terminal, its continuation, and the advisory history extents are all
    /// validated through READY. Scrollback history is not present yet and
    /// arrives through `next`. Asserts this is the first call.
    ///
    /// The Terminal also has every Kitty graphics image from the snapshot,
    /// and the placements on its screens. The pixels arrive later through
    /// `next`, and the images are pending until then. Placements on history
    /// pages also arrive through `next`, together with their pages.
    /// `Decoded.kitty` says how many pixels are still to come.
    pub fn ready(
        self: *Decoder,
        alloc: Allocator,
        io_: std.Io,
        options: DecodeOptions,
    ) ReadyError!Decoded {
        assert(self.state == .start);
        errdefer self.state = .failed;
        const reader = self.source;

        // Read the envelope, which is currently just a verification step.
        try envelope.decode(reader);

        // TERMINAL establishes terminal-wide state and allocates empty
        // screen slots with their final routing. SCREEN values replace those
        // slots in place so ScreenSet pointers, including the active
        // pointer, stay valid.
        var result = try terminal.decode(
            reader,
            try record.nextHeader(reader),
            io_,
            alloc,
        );
        errdefer result.deinit(alloc);

        // TERMINAL initializes exactly the number of screen slots it
        // declared. Decode that many SCREEN sequences and route each one by
        // its encoded key.
        const screen_count = result.screens.all.count();
        var screen_options: TerminalScreen.Options = options: {
            const primary = result.screens.get(.primary).?;
            const explicit_bytes = primary.pages.limits.bytes.explicit;
            const explicit_lines = primary.pages.limits.lines.explicit;
            break :options .{
                .cols = result.cols,
                .rows = result.rows,
                .max_scrollback_bytes = if (explicit_bytes == std.math.maxInt(usize))
                    null
                else
                    explicit_bytes,
                .max_scrollback_lines = if (explicit_lines == std.math.maxInt(usize))
                    null
                else
                    explicit_lines,
            };
        };
        if (options.kitty_image_storage_limit) |limit| {
            screen_options.kitty_image_storage_limit = limit;
        }

        // Each SCREEN sequence may be followed by that screen's optional
        // KITTY_IMAGE_STORAGE record. The header after it is read ahead to find
        // out, so each loop starts with the next record's header in hand.
        // The header left over at the end belongs to CONTINUATION.
        var routed: std.EnumSet(TerminalScreenKey) = .empty;
        var history_rows: std.EnumMap(TerminalScreenKey, u64) = .init(.{});
        var header = try record.nextHeader(reader);
        for (0..screen_count) |_| {
            // Decode the screen and move it into the slot for its key.
            const key = key: {
                var decoded = try screen.decode(
                    reader,
                    header,
                    io_,
                    alloc,
                    screen_options,
                );
                errdefer decoded.deinit();

                const slot = result.screens.get(decoded.key) orelse
                    return error.UnexpectedScreenKey;
                if (routed.contains(decoded.key)) return error.DuplicateScreen;
                routed.insert(decoded.key);
                history_rows.put(decoded.key, decoded.history_rows);

                slot.deinit();
                slot.* = decoded.screen;
                decoded.screen = undefined;
                break :key decoded.key;
            };

            // A KITTY_IMAGE_STORAGE record right after the screen holds its
            // images and placements.
            header = try record.nextHeader(reader);
            if (comptime build_options.kitty_graphics) {
                if (header.tag == .kitty_image_storage) {
                    try kitty.decodeStorage(
                        reader,
                        header,
                        io_,
                        alloc,
                        key,
                        result.screens.get(key).?,
                    );
                    header = try record.nextHeader(reader);
                }
            }
        }

        // CONTINUATION is required after every active screen. Nonempty bytes
        // are owned locally until the READY prefix validates.
        const decoded_continuation = try continuation.decode(
            alloc,
            reader,
            header,
            options.max_continuation_bytes,
        );
        errdefer switch (decoded_continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        };

        // READY marks the exact envelope-through-CONTINUATION boundary.
        try checkpoint.decode(.ready, reader, try record.nextHeader(reader));

        // Record where history may be applied. The declared keys route the
        // HISTORY sequences, and the generations detect declared screens
        // that live terminal use destroys or replaces before their history
        // arrives.
        var generations: std.EnumMap(TerminalScreenKey, usize) = .init(.{});
        var kitty_generations: std.EnumMap(TerminalScreenKey, u64) = .init(.{});
        var kitty_counts: std.EnumArray(TerminalScreenKey, kitty.Counts) = .initFill(.{});
        var it = result.screens.all.iterator();
        while (it.next()) |entry| {
            generations.put(
                entry.key,
                result.screens.generation(entry.key),
            );
            if (comptime build_options.kitty_graphics) {
                const storage = &entry.value.*.kitty_images;
                kitty_generations.put(entry.key, storage.generation);
                kitty_counts.set(entry.key, .init(storage));
            }
        }

        self.state = .{ .history = .{
            .generations = generations,
            .routed = .empty,
            .pending = screen_count,
            .current = null,
            .cols = result.cols,
            .page_options = .{ .compress = options.compress_history },
            .kitty_generations = kitty_generations,
        } };
        return .{
            .terminal = result,
            .continuation = decoded_continuation,
            .history_rows = history_rows,
            .kitty = kitty_counts,
        };
    }

    /// One record consumed by `next`.
    ///
    /// ```zig
    /// while (try decoder.next(alloc, &terminal)) |progress| switch (progress) {
    ///     .image => |image| log.debug("image {} arrived", .{image.image_id}),
    ///     .page => |page| log.debug("{} rows of scrollback", .{page.rows}),
    /// };
    /// ```
    pub const Progress = union(enum) {
        /// A history PAGE, together with its Kitty graphics placements.
        page: Page,

        /// The pixels of a Kitty graphics image or animation frame.
        image: Image,

        pub const Page = struct {
            /// The screen whose HISTORY contained the page.
            key: TerminalScreenKey,

            /// Rows prepended above that screen's existing content, or zero
            /// when the page was consumed and validated but dropped.
            rows: usize,

            /// PAGE records still to come in the same HISTORY.
            remaining: u32,
        };

        pub const Image = struct {
            /// The screen the image is on.
            key: TerminalScreenKey,

            /// The ID of the image the pixels are for.
            image_id: u32,

            /// The frame the pixels are for, as the Kitty graphics protocol
            /// counts frames. 1 is the image itself and 2 and up are its
            /// animation frames.
            frame: u32,

            /// The number of pixel bytes attached to the image, or zero
            /// when the pixels were consumed and validated but dropped.
            bytes: usize,
        };
    };

    /// Errors possible while decoding history records through FINISH.
    pub const NextError = record.NextHeaderError ||
        kitty.DecodeError ||
        checkpoint.DecodeError ||
        history.Decoder.InitError ||
        page.DiscardError ||
        page.DecodeError ||
        Allocator.Error ||
        error{
            /// `next` was called before `ready` completed successfully.
            DecoderNotReady,

            /// A prior `next` call failed and invalidated the stream position.
            DecoderFailed,

            /// A HISTORY names a key not declared by TERMINAL.
            UnexpectedHistoryKey,

            /// More than one HISTORY names the same key.
            DuplicateHistory,

            /// A history PAGE cannot join a native PageList.
            /// These propagate from `nextPage`'s non-limit finalize errors;
            /// only limit failures are deliberately converted into drops.
            InvalidPageDimensions,
            RowCountOverflow,
            PageSizeOverflow,
        };

    /// Decode one history PAGE record and prepend it to its screen in `t`,
    /// or decode the pixels of one Kitty graphics image or animation frame.
    ///
    /// `t` must be the Terminal restored by this decoder's `ready` call,
    /// wherever the caller now stores it. Returns null once FINISH has
    /// validated, which completes the snapshot; the source is
    /// left positioned exactly after it. Further calls return null.
    ///
    /// Wire validation stays strict: framing, CRCs, record order, routing,
    /// and both marker records are always enforced. Application is
    /// forgiving, because the terminal is live and may have changed since
    /// READY. A page is consumed but dropped, reported as zero rows, when:
    ///
    ///   * its screen was removed, or removed and recreated, since READY
    ///     (detected through ScreenSet generations);
    ///   * the terminal was resized since READY, since encoded pages assume
    ///     the encoded width;
    ///   * prepending it would exceed the screen's scrollback limits, e.g.
    ///     because post-cut output already consumed that budget, making
    ///     immediate eviction the only alternative.
    ///
    /// Once a page in a sequence is dropped, the rest of that sequence is
    /// discarded too: later pages are older, and applying one above a gap
    /// would corrupt scrollback ordering. History for other screens is
    /// unaffected.
    ///
    /// The Kitty graphics placements pinned to a page are restored by the
    /// same call as the page. When a page is dropped, its placements are
    /// dropped too.
    ///
    /// Kitty graphics pixels may come at any point, even between history
    /// pages, one image or frame per call. `next` reports them as
    /// `Progress.image`. Like pages, they are never applied where they no
    /// longer belong. The pixels are consumed but dropped, reported as zero
    /// bytes, when:
    ///
    ///   * their screen was removed, or removed and recreated, since READY;
    ///   * live input deleted the image, or sent a new image with the same
    ///     ID, since READY.
    pub fn next(
        self: *Decoder,
        alloc: Allocator,
        t: *Terminal,
    ) NextError!?Progress {
        switch (self.state) {
            // `ready` must succeed before history exists to decode, and a
            // failed decoder no longer knows its stream position.
            .start => return error.DecoderNotReady,
            .failed => return error.DecoderFailed,
            .finished => return null,
            .history => {},
        }
        errdefer self.state = .failed;
        const state = &self.state.history;

        while (true) {
            // Read the next header before deciding how to decode the
            // record. Unknown records before it were skipped.
            const header = try self.takeHeader();

            // Kitty graphics pixels may come anywhere after READY, even
            // between the pages of a HISTORY sequence, in any screen order.
            if (comptime build_options.kitty_graphics) {
                if (header.tag == .kitty_image_payload) {
                    return try self.nextPayload(alloc, t, header);
                }
            }

            // Stream the current sequence's next PAGE if one remains.
            if (state.current) |*sequence| {
                if (sequence.remaining > 0) {
                    return try self.nextPage(alloc, t, sequence, header);
                }
                state.current = null;
            }

            // All sequences are consumed: FINISH ends the snapshot, leaving
            // trailing transport bytes unread.
            if (state.pending == 0) {
                try checkpoint.decode(.finish, self.source, header);
                if (comptime build_options.slow_runtime_safety) {
                    var it = state.generations.iterator();
                    while (it.next()) |entry| {
                        const restored = t.screens.get(entry.key) orelse
                            continue;
                        restored.pages.assertIntegrity();
                        restored.assertIntegrity();
                    }
                }
                self.state = .finished;
                return null;
            }

            // Begin the next HISTORY sequence. Keys route the sequences
            // order-independently, but each must name a declared screen and
            // may not repeat.
            state.pending -= 1;
            var manifest: history.Decoder = undefined;
            try manifest.init(self.source, header);
            const key = manifest.header.key;
            if (state.generations.get(key) == null) {
                return error.UnexpectedHistoryKey;
            }
            if (state.routed.contains(key)) return error.DuplicateHistory;
            state.routed.insert(key);
            state.current = .{
                .key = key,
                .remaining = manifest.header.page_count,
                .apply = true,
            };
        }
    }

    /// Return the next record header: the one a previous call read ahead,
    /// or else the next one from the source. A failure from reading ahead
    /// is returned here.
    fn takeHeader(self: *Decoder) NextError!record.Header {
        const state = &self.state.history;
        if (state.pending_error) |err| return err;
        if (state.pending_header) |header| {
            state.pending_header = null;
            return header;
        }
        return try record.nextHeader(self.source);
    }

    /// The screen for `key` in `t`, if it is still the screen restored at
    /// READY. Returns null if live input removed it, or removed it and
    /// created a new one, since then.
    fn restoredScreen(
        self: *const Decoder,
        t: *Terminal,
        key: TerminalScreenKey,
    ) ?*TerminalScreen {
        const state = &self.state.history;
        const restored = t.screens.get(key) orelse return null;
        if (t.screens.generation(key) != state.generations.get(key).?) {
            return null;
        }
        return restored;
    }

    /// Consume one KITTY_IMAGE_PAYLOAD record, attaching its pixels to their
    /// image when it is still the one restored at READY and dropping them
    /// otherwise.
    fn nextPayload(
        self: *Decoder,
        alloc: Allocator,
        t: *Terminal,
        header: record.Header,
    ) NextError!Progress {
        if (comptime !build_options.kitty_graphics) unreachable;
        const state = &self.state.history;

        // Pixels may go to any screen restored at READY that live input
        // hasn't removed or replaced since.
        var targets: kitty.PayloadTargets = .init(.{});
        var it = state.generations.iterator();
        while (it.next()) |entry| {
            const restored = self.restoredScreen(t, entry.key) orelse continue;
            targets.put(entry.key, .{
                .screen = restored,
                .ready_generation = state.kitty_generations.get(entry.key).?,
            });
        }

        const payload = try kitty.decodePayload(
            self.source,
            header,
            t.screens.active.io,
            alloc,
            targets,
        );
        if (state.generations.get(payload.key) == null) {
            return error.UnexpectedKittyKey;
        }
        return .{ .image = .{
            .key = payload.key,
            .image_id = payload.image_id,
            .frame = payload.frame,
            .bytes = payload.bytes,
        } };
    }

    /// Consume one PAGE record from the current sequence, whose header
    /// `next` already read, applying it to the live terminal when it is
    /// still applicable and discarding it otherwise. The page's Kitty
    /// graphics placements are restored with it, or dropped with it.
    fn nextPage(
        self: *Decoder,
        alloc: Allocator,
        t: *Terminal,
        sequence: *Sequence,
        header: record.Header,
    ) NextError!Progress {
        const state = &self.state.history;

        // Application is re-decided on every page so live terminal changes
        // between calls degrade to discarding instead of failing decoding.
        const destination: ?*TerminalScreen = destination: {
            if (!sequence.apply) break :destination null;
            if (t.cols != state.cols) break :destination null;
            break :destination self.restoredScreen(t, sequence.key);
        };

        sequence.remaining -= 1;
        const applied: ?*TerminalScreen, const rows: usize = rows: {
            const restored = destination orelse {
                // The record must still be consumed so decoding remains
                // aligned with the following records and FINISH marker.
                sequence.apply = false;
                try page.discard(self.source, header);
                break :rows .{ null, 0 };
            };
            // The one-shot history decoder rejects a Screen which already has
            // complete history. This incremental path intentionally bypasses
            // that guard: the terminal has been live since READY and may have
            // accumulated new history. Generation and width checks above keep
            // the destination compatible, while per-page finalization enforces
            // its current scrollback limits.
            const rows = history.decodePage(
                self.source,
                header,
                alloc,
                restored,
                state.page_options,
            ) catch |err| switch (err) {
                // The page no longer fits the screen's scrollback limits,
                // e.g. because post-cut output consumed the budget, so it
                // would be evicted immediately anyway. Its record was fully
                // consumed, leaving the stream aligned on the next record.
                error.MaxSizeExceeded,
                error.MaxLinesExceeded,
                => {
                    sequence.apply = false;
                    break :rows .{ null, 0 };
                },
                else => |other| return other,
            };
            break :rows .{ restored, rows };
        };

        const progress: Progress = .{ .page = .{
            .key = sequence.key,
            .rows = rows,
            .remaining = sequence.remaining,
        } };

        // The page's Kitty graphics placements, if any, follow it. Read the
        // next header to find out. Anything else waits for the next call,
        // and so does a failure to read it, because this page is already
        // applied and its progress should not be lost.
        const following = record.nextHeader(self.source) catch |err| {
            state.pending_error = err;
            return progress;
        };
        if (comptime build_options.kitty_graphics) {
            if (following.tag == .kitty_image_page_placements) {
                // The page was just added at the top of the screen, which
                // makes it the first page of the screen's page list.
                try kitty.decodePagePlacements(
                    self.source,
                    following,
                    t.screens.active.io,
                    alloc,
                    sequence.key,
                    if (applied) |s| .{
                        .screen = s,
                        .page = s.pages.pages.first.?,
                        .ready_generation = state.kitty_generations.get(sequence.key).?,
                    } else null,
                );
                return progress;
            }
        }

        state.pending_header = following;
        return progress;
    }
};

/// Restore one complete snapshot into a native Terminal and continuation.
///
/// This consumes one snapshot through FINISH and leaves any following bytes
/// in the reader for the containing transport. Restoration is transactional:
/// the returned result is either complete and ready or not (error return).
/// Individual record codecs normalize optional semantic state, and history
/// beyond the declared scrollback limits is dropped rather than rejected,
/// while framing, markers, declared sequence counts, and unique
/// cross-record screen routing remain strict.
///
/// This is the one-shot form of `Decoder`, which can additionally hand the
/// renderable terminal to the caller at READY, before history arrives.
pub fn decode(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeError!Decoded {
    var decoder: Decoder = .init(source);
    var result = try decoder.ready(alloc, io_, options);
    errdefer result.deinit(alloc);

    // The Terminal has not been transferred, so history applies in place.
    const t = &result.terminal.?;
    while (try decoder.next(alloc, t)) |_| {}
    return result;
}

/// Errors possible while restoring a snapshot that must end at end-of-file.
pub const DecodeExactError = DecodeError || std.Io.Reader.Error || error{
    /// FINISH was followed by additional bytes.
    TrailingData,
};

/// Restore one snapshot and require FINISH to be followed by end-of-file.
///
/// This is intended for bounded snapshot files and buffers. On a live stream,
/// checking for end-of-file may block; use `decode` to stop at FINISH instead.
pub fn decodeExact(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeExactError!Decoded {
    var result = try decode(alloc, io_, source, options);
    errdefer result.deinit(alloc);

    _ = source.peekByte() catch |err| switch (err) {
        error.EndOfStream => return result,
        else => return err,
    };
    return error.TrailingData;
}

const test_encode_options: EncodeOptions = .{ .continuation = .ground };
const test_decode_options: DecodeOptions = .{ .max_continuation_bytes = 1024 };
const test_complete_fixture = test_fixture.parse(@embedFile("testdata/complete-v1.hex"));

/// Build a 2x3 test terminal whose primary screen carries `history_pages`
/// complete two-row pages above a three-row active page. The top-left cell
/// of each page is marked 'A', 'B', ... from oldest history to active.
fn testHistoryTerminal(history_pages: u8) !Terminal {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    errdefer t.deinit(testing.allocator);

    const primary = t.screens.get(.primary).?;
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();

        for (0..history_pages) |index| {
            const built = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
            built.size.rows = 2;
            built.getRowAndCell(0, 0).cell.* = .init(
                @intCast('A' + index),
            );
        }
        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init(
            @intCast('A' + @as(usize, history_pages)),
        );

        var pages = try builder.finish();
        errdefer pages.deinit();
        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;
    return t;
}

/// The top-left screen cell, which lands in the oldest applied history page.
fn testTopLeftCodepoint(terminal_screen: *const TerminalScreen) u21 {
    return terminal_screen.pages.getTopLeft(.screen).node
        .page().getRowAndCell(0, 0).cell.codepoint();
}

test "complete snapshot round trip with history and alternate screen" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);

    // Exercise terminal-wide state.
    t.width_px = 800;
    t.height_px = 600;
    t.colors.palette.set(7, .{ .r = 1, .g = 2, .b = 3 });
    t.modes.values.bracketed_paste = true;
    try t.setPwd("file:///tmp/snapshot");
    try t.setTitle("complete snapshot");

    const primary = t.screens.get(.primary).?;

    // Use small exact capacities so this compound golden remains practical to
    // review while still containing two complete history pages and one active
    // page. Replacing the Screen in place preserves ScreenSet routing.
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();

        const oldest = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        oldest.size.rows = 2;
        oldest.getRowAndCell(0, 0).cell.* = .init('A');

        const recent = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        recent.size.rows = 2;
        recent.getRowAndCell(0, 0).cell.* = .init('B');

        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init('C');
        active.getRowAndCell(0, 1).cell.* = .init('D');
        active.getRowAndCell(0, 2).cell.* = .init('E');

        var pages = try builder.finish();
        errdefer pages.deinit();

        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;

    try testing.expect(primary.pages.scrollbar().total > t.rows);

    // Compression is an internal source representation and must remain
    // unchanged while the complete history is inspected for encoding.
    _ = primary.pages.compress(.full);
    const source_memory = primary.pages.memoryStats();

    // The optional alternate screen participates in both phases and remains
    // the active screen after restoration.
    _ = try t.switchScreen(.alternate);
    try t.printString("alternate");

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try testing.expectEqualDeep(source_memory, primary.pages.memoryStats());
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v1.hex",
        "snapshot_fixture-complete-v1.hex",
        &test_complete_fixture,
        encoded.written(),
    );

    // A complete snapshot can stream through a non-allocating destination.
    // Independently hash that output so both its length and complete byte
    // sequence are checked without retaining a second snapshot copy.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var hashing = discard.writer.hashed(record.Crc32c.init(), &.{});
    try encode(testing.allocator, &hashing.writer, &t, test_encode_options);
    try testing.expectEqual(
        @as(u64, test_complete_fixture.len),
        discard.fullCount(),
    );
    try testing.expectEqual(
        record.Crc32c.hash(&test_complete_fixture),
        hashing.hasher.final(),
    );

    // Restore the checked-in reference rather than the just-generated bytes.
    var encoded_source: std.Io.Reader = .fixed(&test_complete_fixture);
    var source_buffer: [1]u8 = undefined;
    var limited = encoded_source.limited(.unlimited, &source_buffer);
    var restored = try decode(
        testing.allocator,
        testing.io,
        &limited.interface,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    const restored_terminal = &restored.terminal.?;

    try testing.expectEqual(
        TerminalScreenKey.alternate,
        restored_terminal.screens.active_key,
    );
    try testing.expectEqual(
        restored_terminal.screens.get(.alternate).?,
        restored_terminal.screens.active,
    );
    try testing.expectEqualStrings(
        "file:///tmp/snapshot",
        restored_terminal.getPwd().?,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored_terminal.getTitle().?,
    );
    try testing.expectEqual(
        primary.pages.scrollbar().total,
        restored_terminal.screens.get(.primary).?.pages.scrollbar().total,
    );

    // Re-encoding is a compact semantic equality check over all TERMINAL,
    // SCREEN, PAGE, and HISTORY fields and both marker boundaries.
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        restored_terminal,
        test_encode_options,
    );
    try testing.expectEqualStrings(
        &test_complete_fixture,
        reencoded.written(),
    );

    // SCREEN and HISTORY keys make both sequence groups order independent.
    var reversed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reversed.deinit();
    var reversed_stream: record.Writer = .init(
        testing.allocator,
        &reversed.writer,
    );
    defer reversed_stream.deinit();
    try envelope.encode(reversed_stream.writer());
    try terminal.encode(&t, &reversed_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try screen.encode(primary, .primary, &reversed_stream);
    try continuation.encode(.ground, &reversed_stream);
    try checkpoint.encode(.ready, &reversed_stream);
    try history.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
        null,
    );
    try history.encode(primary, .primary, &reversed_stream, null);
    try checkpoint.encode(.finish, &reversed_stream);

    var reversed_source: std.Io.Reader = .fixed(reversed.written());
    var reversed_restored = try decode(
        testing.allocator,
        testing.io,
        &reversed_source,
        test_decode_options,
    );
    defer reversed_restored.deinit(testing.allocator);
    const reversed_terminal = &reversed_restored.terminal.?;
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        reversed_terminal.screens.active_key,
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.primary),
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.alternate),
    );
}

test "complete snapshot restores a canonical Stream continuation" {
    const testing = std.testing;

    var source_terminal = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 8, .rows = 2 },
    );
    defer source_terminal.deinit(testing.allocator);
    var source_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&source_terminal),
        .continuation_max_bytes = 1024,
    });
    defer source_stream.deinit();

    source_stream.nextSlice("A\x1b[31");
    var exported_bytes: [1024]u8 = undefined;
    var exported: std.Io.Writer = .fixed(&exported_bytes);
    try source_stream.writeContinuation(&exported);
    try testing.expectEqualStrings("\x1b[31", exported.buffered());

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &source_terminal, .{
        .continuation = .{ .bytes = exported.buffered() },
    });

    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        .{ .max_continuation_bytes = 1024 },
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings(
        exported.buffered(),
        decoded.continuation.bytes,
    );

    var restored_terminal = decoded.toOwned();
    defer restored_terminal.deinit(testing.allocator);
    try testing.expect(decoded.terminal == null);
    var restored_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&restored_terminal),
        .continuation_max_bytes = 1024,
    });
    defer restored_stream.deinit();

    restored_stream.nextSlice(decoded.continuation.bytes);
    var reexported_bytes: [1024]u8 = undefined;
    var reexported: std.Io.Writer = .fixed(&reexported_bytes);
    try restored_stream.writeContinuation(&reexported);
    try testing.expectEqualStrings(exported.buffered(), reexported.buffered());

    // The identical post-cut bytes may use different feed chunking without
    // changing terminal semantics.
    source_stream.nextSlice("mB");
    restored_stream.next('m');
    restored_stream.next('B');
    const source_text = try source_terminal.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    try testing.expectEqual(
        source_terminal.screens.active.cursor.style_id,
        restored_terminal.screens.active.cursor.style_id,
    );
}

test "complete snapshot restores semantic prompt state for an input cursor" {
    const testing = std.testing;

    var source_terminal = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 10, .rows = 15 },
    );
    defer source_terminal.deinit(testing.allocator);
    for (0..10) |_| {
        try source_terminal.printString("x");
        source_terminal.carriageReturn();
        try source_terminal.linefeed();
    }

    // The shell started input (OSC 133;B) but no row is marked as a
    // prompt yet, so only the cursor carries the semantic content.
    try source_terminal.semanticPrompt(.init(.end_prompt_start_input));
    try source_terminal.printString("echo hi");

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(
        testing.allocator,
        &encoded.writer,
        &source_terminal,
        test_encode_options,
    );

    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var t = decoded.toOwned();
    defer t.deinit(testing.allocator);
    try testing.expect(t.screens.active.semantic_prompt.seen);

    // The linefeed marks the next row as a prompt continuation, so a
    // full erase must scroll before clearing.
    t.carriageReturn();
    try t.linefeed();
    try t.printString("more");
    t.setCursorPos(1, 1);
    t.eraseDisplay(.complete, false);
    try testing.expect(
        t.screens.active.pages.total_rows > t.screens.active.pages.rows,
    );
}

test "complete snapshot validates continuation before writing" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);

    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.NoPendingState,
        encode(testing.allocator, &destination.writer, &t, .{
            .continuation = .{ .bytes = "\x1b[31m" },
        }),
    );
    try testing.expectEqualStrings("prefix", destination.written());

    var tail = [_]u8{ 0x1b, '[', '3', '1' };
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = &tail },
    });
    tail[2] = '4';

    var source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("\x1b[31", decoded.continuation.bytes);
}

test "complete snapshot waits for continuation tracking recovery" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&t),
        .continuation_max_bytes = 4,
    });
    defer stream.deinit();

    stream.nextSlice("\x1b[123");
    var unavailable_bytes: [4]u8 = undefined;
    var unavailable: std.Io.Writer = .fixed(&unavailable_bytes);
    try testing.expectError(
        error.ContinuationUnavailable,
        stream.writeContinuation(&unavailable),
    );

    // A new replay start replaces the lost suffix and makes a later cut
    // publishable without affecting normal terminal parsing.
    stream.nextSlice("\x1b[");
    var recovered_bytes: [4]u8 = undefined;
    var recovered: std.Io.Writer = .fixed(&recovered_bytes);
    try stream.writeContinuation(&recovered);
    try testing.expectEqualStrings("\x1b[", recovered.buffered());

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = recovered.buffered() },
    });
}

test "complete snapshot preserves every supported continuation cut" {
    const testing = std.testing;
    const corpora = [_][]const u8{
        "plain \xF0\x9F\x98\x84 utf8",
        "bad \xE0\xA0\xF0\x9F\x98\x84 utf8",
        "\x1b[1\x07;2mstyled\x1b[0m",
        "\x1b]2;window title\x1b\\text",
        "\x1bP$qm\x1b\\text",
        "\x1b_Ga=q;payload\x1b\\text",
        "\x1b_25a1;s\x1b\\text",
        "\x1b]2;first\x1b\\\x1b_Gsecond",
        "\x1b[12\x9D2;title\x1b\\text",
        "\x1b_hello\x9b31mtext",
        "\x1b_Ga=q\x90$qm\x1b\\text",
        "\x1b_hello\x9d2;title\x07text",
        "\x1b[12\x18text\x1b[1\x1Atext",
    };

    for (corpora) |corpus| for (0..corpus.len + 1) |cut| {
        var source_terminal = try Terminal.init(
            testing.io,
            testing.allocator,
            .{ .cols = 20, .rows = 4 },
        );
        defer source_terminal.deinit(testing.allocator);
        var source_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&source_terminal),
            .continuation_max_bytes = 4096,
        });
        defer source_stream.deinit();
        source_stream.nextSlice(corpus[0..cut]);

        var cut_bytes: [4096]u8 = undefined;
        var cut_writer: std.Io.Writer = .fixed(&cut_bytes);
        try source_stream.writeContinuation(&cut_writer);
        const cut_continuation: Continuation = if (cut_writer.end == 0)
            .ground
        else
            .{ .bytes = cut_writer.buffered() };

        var snapshot_bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer snapshot_bytes.deinit();
        try encode(
            testing.allocator,
            &snapshot_bytes.writer,
            &source_terminal,
            .{ .continuation = cut_continuation },
        );

        var snapshot_source: std.Io.Reader = .fixed(snapshot_bytes.written());
        var decoded = try decode(
            testing.allocator,
            testing.io,
            &snapshot_source,
            .{ .max_continuation_bytes = 4096 },
        );
        defer decoded.deinit(testing.allocator);
        var restored_terminal = decoded.toOwned();
        defer restored_terminal.deinit(testing.allocator);
        var restored_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&restored_terminal),
            .continuation_max_bytes = 4096,
        });
        defer restored_stream.deinit();
        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| restored_stream.nextSlice(bytes),
        }

        var reexport_bytes: [4096]u8 = undefined;
        var reexport_writer: std.Io.Writer = .fixed(&reexport_bytes);
        try restored_stream.writeContinuation(&reexport_writer);
        try testing.expectEqualStrings(
            cut_writer.buffered(),
            reexport_writer.buffered(),
        );

        source_stream.nextSlice(corpus[cut..]);
        var offset = cut;
        var partition = cut +% corpus.len +% 1;
        while (offset < corpus.len) {
            partition = partition *% 1664525 +% 1013904223;
            const len = @min(1 + partition % 7, corpus.len - offset);
            restored_stream.nextSlice(corpus[offset..][0..len]);
            offset += len;
        }

        var source_final_bytes: [4096]u8 = undefined;
        var source_final_writer: std.Io.Writer = .fixed(&source_final_bytes);
        try source_stream.writeContinuation(&source_final_writer);
        var restored_final_bytes: [4096]u8 = undefined;
        var restored_final_writer: std.Io.Writer = .fixed(&restored_final_bytes);
        try restored_stream.writeContinuation(&restored_final_writer);
        try testing.expectEqualStrings(
            source_final_writer.buffered(),
            restored_final_writer.buffered(),
        );

        const final_continuation: Continuation = if (source_final_writer.end == 0)
            .ground
        else
            .{ .bytes = source_final_writer.buffered() };
        var source_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer source_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &source_final_snapshot.writer,
            &source_terminal,
            .{ .continuation = final_continuation },
        );
        var restored_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer restored_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &restored_final_snapshot.writer,
            &restored_terminal,
            .{ .continuation = final_continuation },
        );
        try testing.expectEqualStrings(
            source_final_snapshot.written(),
            restored_final_snapshot.written(),
        );
    };
}

test "complete snapshot preserves Kitty virtual placeholders" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    // Register a real virtual placement, then write its grid representation:
    // U+10EEEE followed by row and column diacritics. The image and placement
    // registry is intentionally omitted, but the grid content must remain
    // decodable.
    try t.screens.active.kitty_images.addImage(
        testing.io,
        testing.allocator,
        t.screens.active,
        .{ .id = 1 },
    );
    try t.screens.active.kitty_images.addPlacement(
        testing.io,
        testing.allocator,
        t.screens.active,
        1,
        0,
        .{
            .location = .{ .virtual = {} },
            .columns = 1,
            .rows = 1,
        },
    );
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const source_cell = t.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        source_cell.cell.codepoint(),
    );
    try testing.expect(source_cell.row.kitty_virtual_placeholder);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    const restored_terminal = &restored.terminal.?;

    const restored_cell = restored_terminal.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        restored_cell.cell.codepoint(),
    );
    try testing.expect(restored_cell.cell.hasGrapheme());
    try testing.expect(restored_cell.row.kitty_virtual_placeholder);
    try testing.expectEqual(
        @as(usize, 0),
        restored_terminal.screens.active.kitty_images.images.count(),
    );
    try testing.expectEqual(
        @as(usize, 0),
        restored_terminal.screens.active.kitty_images.placements.count(),
    );
}

test "complete snapshot encoding streams from the current writer position" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    // Encoding begins with this call's envelope, independent of bytes that
    // were already present in the destination.
    var nonempty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer nonempty.deinit();
    try nonempty.writer.writeAll("prefix");
    const snapshot_offset = nonempty.written().len;
    try encode(testing.allocator, &nonempty.writer, &t, test_encode_options);
    try testing.expectEqualStrings(
        "prefix",
        nonempty.written()[0..snapshot_offset],
    );
    var appended_source: std.Io.Reader = .fixed(
        nonempty.written()[snapshot_offset..],
    );
    var appended = try decode(
        testing.allocator,
        testing.io,
        &appended_source,
        test_decode_options,
    );
    appended.deinit(testing.allocator);

    // Payload validation happens in the record-local scratch allocation. The
    // already-streamed envelope remains, but no partial TERMINAL is emitted.
    t.colors.palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.InvalidPalette,
        encode(
            testing.allocator,
            &destination.writer,
            &t,
            test_encode_options,
        ),
    );
    var expected_envelope: [envelope.encoded_len]u8 = undefined;
    var envelope_writer: std.Io.Writer = .fixed(&expected_envelope);
    try envelope.encode(&envelope_writer);
    try testing.expectEqualStrings(
        &expected_envelope,
        destination.written()["prefix".len..],
    );
}

test "complete snapshot rejects ordering and invalid markers" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;

    // Old version-1 snapshots proceeded directly from SCREEN to READY. READY
    // is individually valid here, but CONTINUATION is now required first.
    var old_order: std.Io.Writer.Allocating = .init(testing.allocator);
    defer old_order.deinit();
    var old_order_stream: record.Writer = .init(
        testing.allocator,
        &old_order.writer,
    );
    defer old_order_stream.deinit();
    try envelope.encode(old_order_stream.writer());
    try terminal.encode(&t, &old_order_stream);
    try screen.encode(primary, .primary, &old_order_stream);
    try checkpoint.encode(.ready, &old_order_stream);
    var old_order_source: std.Io.Reader = .fixed(old_order.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &old_order_source,
            test_decode_options,
        ),
    );

    // A second CONTINUATION is rejected where READY is required.
    var duplicate_continuation: std.Io.Writer.Allocating = .init(
        testing.allocator,
    );
    defer duplicate_continuation.deinit();
    var duplicate_continuation_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_continuation.writer,
    );
    defer duplicate_continuation_stream.deinit();
    try envelope.encode(duplicate_continuation_stream.writer());
    try terminal.encode(&t, &duplicate_continuation_stream);
    try screen.encode(primary, .primary, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    var duplicate_continuation_source: std.Io.Reader = .fixed(
        duplicate_continuation.written(),
    );
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_continuation_source,
            test_decode_options,
        ),
    );

    // HISTORY is individually valid here, but the full decoder requires the
    // primary SCREEN before READY.
    var reordered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reordered.deinit();
    var reordered_stream: record.Writer = .init(
        testing.allocator,
        &reordered.writer,
    );
    defer reordered_stream.deinit();
    try envelope.encode(reordered_stream.writer());
    try terminal.encode(&t, &reordered_stream);
    try history.encode(primary, .primary, &reordered_stream, null);
    var reordered_source: std.Io.Reader = .fixed(reordered.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &reordered_source,
            test_decode_options,
        ),
    );

    // Construct a correctly framed READY with a nonempty payload so the full
    // driver rejects a marker that does not match the required empty shape.
    var invalid_ready: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_ready.deinit();
    var invalid_ready_stream: record.Writer = .init(
        testing.allocator,
        &invalid_ready.writer,
    );
    defer invalid_ready_stream.deinit();
    try envelope.encode(invalid_ready_stream.writer());
    try terminal.encode(&t, &invalid_ready_stream);
    try screen.encode(primary, .primary, &invalid_ready_stream);
    try continuation.encode(.ground, &invalid_ready_stream);
    const ready_payload = invalid_ready_stream.begin(.ready);
    errdefer invalid_ready_stream.cancel();
    try ready_payload.writeByte(0);
    try invalid_ready_stream.finish();
    var invalid_ready_source: std.Io.Reader = .fixed(
        invalid_ready.written(),
    );
    try testing.expectError(
        error.PayloadNotExhausted,
        decode(
            testing.allocator,
            testing.io,
            &invalid_ready_source,
            test_decode_options,
        ),
    );

    // A SCREEN key must name one of the slots declared by TERMINAL.
    var undeclared: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared.deinit();
    var undeclared_stream: record.Writer = .init(
        testing.allocator,
        &undeclared.writer,
    );
    defer undeclared_stream.deinit();
    try envelope.encode(undeclared_stream.writer());
    try terminal.encode(&t, &undeclared_stream);
    try screen.encode(primary, .alternate, &undeclared_stream);
    var undeclared_source: std.Io.Reader = .fixed(undeclared.written());
    try testing.expectError(
        error.UnexpectedScreenKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_source,
            test_decode_options,
        ),
    );

    // HISTORY sequences are also routed by key, which must name a declared
    // screen even when the sequence contains no PAGE records.
    var undeclared_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared_history.deinit();
    var undeclared_history_stream: record.Writer = .init(
        testing.allocator,
        &undeclared_history.writer,
    );
    defer undeclared_history_stream.deinit();
    try envelope.encode(undeclared_history_stream.writer());
    try terminal.encode(&t, &undeclared_history_stream);
    try screen.encode(primary, .primary, &undeclared_history_stream);
    try continuation.encode(.ground, &undeclared_history_stream);
    try checkpoint.encode(.ready, &undeclared_history_stream);
    try history.encode(primary, .alternate, &undeclared_history_stream, null);
    var undeclared_history_source: std.Io.Reader = .fixed(
        undeclared_history.written(),
    );
    try testing.expectError(
        error.UnexpectedHistoryKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_history_source,
            test_decode_options,
        ),
    );

    // The declared count cannot be satisfied by repeating the same key.
    _ = try t.switchScreen(.alternate);
    var duplicate: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate.deinit();
    var duplicate_stream: record.Writer = .init(
        testing.allocator,
        &duplicate.writer,
    );
    defer duplicate_stream.deinit();
    try envelope.encode(duplicate_stream.writer());
    try terminal.encode(&t, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    var duplicate_source: std.Io.Reader = .fixed(duplicate.written());
    try testing.expectError(
        error.DuplicateScreen,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_source,
            test_decode_options,
        ),
    );

    // The declared count cannot be satisfied by repeating one HISTORY key.
    var duplicate_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate_history.deinit();
    var duplicate_history_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_history.writer,
    );
    defer duplicate_history_stream.deinit();
    try envelope.encode(duplicate_history_stream.writer());
    try terminal.encode(&t, &duplicate_history_stream);
    try screen.encode(primary, .primary, &duplicate_history_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &duplicate_history_stream,
    );
    try continuation.encode(.ground, &duplicate_history_stream);
    try checkpoint.encode(.ready, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream, null);
    try history.encode(primary, .primary, &duplicate_history_stream, null);
    var duplicate_history_source: std.Io.Reader = .fixed(
        duplicate_history.written(),
    );
    try testing.expectError(
        error.DuplicateHistory,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_history_source,
            test_decode_options,
        ),
    );
}

test "complete snapshot skips unknown records in every position" {
    const testing = std.testing;

    // Put an unknown record before every record of the complete golden,
    // including before FINISH, so one sits between every pair of records.
    // The tags vary, and so do the payload lengths, including empty.
    var with_unknown: std.Io.Writer.Allocating = .init(testing.allocator);
    defer with_unknown.deinit();
    var unknown_offsets: std.ArrayList(usize) = .empty;
    defer unknown_offsets.deinit(testing.allocator);
    {
        const bytes: []const u8 = &test_complete_fixture;
        try with_unknown.writer.writeAll(bytes[0..envelope.encoded_len]);
        var offset: usize = envelope.encoded_len;
        var i: usize = 0;
        while (offset < bytes.len) : (i += 1) {
            const len = std.mem.readInt(u32, bytes[offset + 2 ..][0..4], .little);
            const end = offset + record.Header.len + len;
            try unknown_offsets.append(testing.allocator, with_unknown.written().len);
            const payload: [8]u8 = @splat(@intCast(i));
            try record.testWriteRaw(
                &with_unknown.writer,
                @intCast(0x4000 + i),
                payload[0 .. i % payload.len],
            );
            try with_unknown.writer.writeAll(bytes[offset..end]);
            offset = end;
        }
    }

    // Both decoders restore exactly the terminal of the golden.
    {
        var source: std.Io.Reader = .fixed(with_unknown.written());
        var decoded = try decodeExact(
            testing.allocator,
            testing.io,
            &source,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
        defer reencoded.deinit();
        try encode(testing.allocator, &reencoded.writer, &decoded.terminal.?, test_encode_options);
        try testing.expectEqualSlices(u8, &test_complete_fixture, reencoded.written());
    }
    {
        var source: std.Io.Reader = .fixed(with_unknown.written());
        var buf: [1]u8 = undefined;
        var limited = source.limited(.unlimited, &buf);
        var decoder: Decoder = .init(&limited.interface);
        var decoded = try decoder.ready(testing.allocator, testing.io, test_decode_options);
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        while (try decoder.next(testing.allocator, restored)) |_| {}
        var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
        defer reencoded.deinit();
        try encode(testing.allocator, &reencoded.writer, restored, test_encode_options);
        try testing.expectEqualSlices(u8, &test_complete_fixture, reencoded.written());
    }

    // A corrupted unknown record still fails its CRC, wherever it is. The
    // first payload byte is corrupted, or the tag when the payload is empty.
    for (unknown_offsets.items) |offset| {
        const corrupted = try testing.allocator.dupe(u8, with_unknown.written());
        defer testing.allocator.free(corrupted);
        const len = std.mem.readInt(u32, corrupted[offset + 2 ..][0..4], .little);
        corrupted[if (len > 0) offset + record.Header.len else offset] ^= 0x01;
        var source: std.Io.Reader = .fixed(corrupted);
        try testing.expectError(
            error.InvalidChecksum,
            decode(testing.allocator, testing.io, &source, test_decode_options),
        );
    }
}

test "complete snapshot leaves continuation bytes unread" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    const snapshot_len = encoded.written().len;
    try encoded.writer.writeAll("pty");

    var source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);

    var trailing: [3]u8 = undefined;
    try source.readSliceAll(&trailing);
    try testing.expectEqualStrings("pty", &trailing);

    var exact_source: std.Io.Reader = .fixed(encoded.written());
    try testing.expectError(
        error.TrailingData,
        decodeExact(
            testing.allocator,
            testing.io,
            &exact_source,
            test_decode_options,
        ),
    );

    var bounded_source: std.Io.Reader = .fixed(
        encoded.written()[0..snapshot_len],
    );
    var bounded = try decodeExact(
        testing.allocator,
        testing.io,
        &bounded_source,
        test_decode_options,
    );
    defer bounded.deinit(testing.allocator);
}

test "complete snapshots decode sequentially from one reader" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    var source: std.Io.Reader = .fixed(encoded.written());
    var first = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer first.deinit(testing.allocator);
    var second = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer second.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, source.takeByte());
}

test "complete snapshot decode allocation failures are transactional" {
    const testing = std.testing;
    const S = struct {
        fn exercise(bytes: []const u8) !void {
            var baseline = testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = std.math.maxInt(usize),
            });
            var baseline_source: std.Io.Reader = .fixed(bytes);
            var baseline_decoded = try decode(
                baseline.allocator(),
                testing.io,
                &baseline_source,
                test_decode_options,
            );
            baseline_decoded.deinit(baseline.allocator());
            const allocation_count = baseline.alloc_index;
            try testing.expect(allocation_count > 0);

            var saw_out_of_memory = false;
            for (0..allocation_count) |fail_index| {
                var failing = testing.FailingAllocator.init(
                    testing.allocator,
                    .{ .fail_index = fail_index },
                );
                var source: std.Io.Reader = .fixed(bytes);
                var decoded = decode(
                    failing.allocator(),
                    testing.io,
                    &source,
                    test_decode_options,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        saw_out_of_memory = true;
                        continue;
                    },
                    else => return err,
                };
                decoded.deinit(failing.allocator());
            }
            try testing.expect(saw_out_of_memory);
        }
    };

    // The complete golden exercises Terminal, both screens, and history.
    try S.exercise(&test_complete_fixture);

    // A non-ground component additionally exercises owned continuation bytes.
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = "\x1b[31" },
    });
    try S.exercise(encoded.written());
}

test "incremental decode restores a renderable terminal at READY" {
    const testing = std.testing;

    // Trailing transport bytes must remain unread after FINISH.
    var transport: std.Io.Writer.Allocating = .init(testing.allocator);
    defer transport.deinit();
    try transport.writer.writeAll(&test_complete_fixture);
    try transport.writer.writeAll("pty");

    var source: std.Io.Reader = .fixed(transport.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);

    // READY restored the complete interactive state, so the Terminal can
    // move to its final address before any history has been decoded.
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        restored.screens.active_key,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored.getTitle().?,
    );

    // The advisory extents size scrollback UI immediately even though only
    // the resident SCREEN pages exist. The alternate screen's extent is
    // entirely resident overlap, so it must match its live row count.
    const primary = restored.screens.get(.primary).?;
    const alternate = restored.screens.get(.alternate).?;
    try testing.expectEqual(3, primary.pages.scrollbar().total);
    try testing.expectEqual(4, decoded.history_rows.get(.primary).?);
    try testing.expectEqual(
        alternate.pages.scrollbar().total - restored.rows,
        decoded.history_rows.get(.alternate).?,
    );

    // Each call prepends exactly one history page, newest first.
    const first = (try decoder.next(testing.allocator, &restored)).?;
    try testing.expectEqualDeep(Decoder.Progress{ .page = .{
        .key = .primary,
        .rows = 2,
        .remaining = 1,
    } }, first);
    try testing.expectEqual(5, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'B'), testTopLeftCodepoint(primary));

    const second = (try decoder.next(testing.allocator, &restored)).?;
    try testing.expectEqualDeep(Decoder.Progress{ .page = .{
        .key = .primary,
        .rows = 2,
        .remaining = 0,
    } }, second);
    try testing.expectEqual(7, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));

    // The alternate screen's empty sequence produces no event: the next
    // call validates FINISH, and further calls remain null.
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);
    try testing.expect(try decoder.next(testing.allocator, &restored) == null);
    try testing.expectEqualStrings("pty", try source.take(3));

    // The incremental path restores the same complete terminal as the
    // one-shot decoder, byte for byte.
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        &restored,
        test_encode_options,
    );
    try testing.expectEqualStrings(&test_complete_fixture, reencoded.written());
}

test "incremental next reports invalid decoder states" {
    const testing = std.testing;
    var source: std.Io.Reader = .fixed("");
    var decoder: Decoder = .init(&source);
    var terminal_value = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 1, .rows = 1 },
    );
    defer terminal_value.deinit(testing.allocator);

    try testing.expectError(
        error.DecoderNotReady,
        decoder.next(testing.allocator, &terminal_value),
    );
}

test "incremental decode applies history below live PTY output" {
    const testing = std.testing;

    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    var source: std.Io.Reader = .fixed(encoded.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    // The terminal is interactive at READY: post-cut PTY bytes append to
    // the bottom while snapshot history is still pending.
    var live = restored.vtStream();
    defer live.deinit();
    live.nextSlice("1\r\n2\r\n3\r\n4\r\n5\r\n");
    const primary = restored.screens.get(.primary).?;
    const live_total = primary.pages.scrollbar().total;
    try testing.expect(live_total > 3);

    // History still lands above both the snapshot content and the live
    // output, preserving complete scrollback ordering.
    while (try decoder.next(testing.allocator, &restored)) |progress| {
        try testing.expectEqual(TerminalScreenKey.primary, progress.page.key);
        try testing.expectEqual(2, progress.page.rows);
    }
    try testing.expectEqual(live_total + 4, primary.pages.scrollbar().total);
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));
    const newest_history = primary.pages.getTopLeft(.screen).node.next.?;
    try testing.expectEqual(
        @as(u21, 'B'),
        newest_history.page().getRowAndCell(0, 0).cell.codepoint(),
    );

    // The page below the applied history is the snapshot's active page,
    // whose top-left cell the live output already overwrote.
    try testing.expectEqual(
        @as(u21, '1'),
        newest_history.next.?.page().getRowAndCell(0, 0).cell.codepoint(),
    );
}

test "incremental decode discards history for screens changed since READY" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
    });
    defer t.deinit(testing.allocator);
    _ = try t.switchScreen(.alternate);
    try t.printString("alt");
    _ = try t.switchScreen(.primary);

    // The encoder never produces alternate-screen history, but the format
    // permits it, so the decoder must stay stream-aligned even when the
    // pages can no longer be applied. Order independence lets the discarded
    // sequence come first.
    var crafted: std.Io.Writer.Allocating = .init(testing.allocator);
    defer crafted.deinit();
    var stream: record.Writer = .init(testing.allocator, &crafted.writer);
    defer stream.deinit();
    try envelope.encode(stream.writer());
    try terminal.encode(&t, &stream);
    try screen.encode(t.screens.get(.primary).?, .primary, &stream);
    try screen.encode(t.screens.get(.alternate).?, .alternate, &stream);
    try continuation.encode(.ground, &stream);
    try checkpoint.encode(.ready, &stream);
    {
        const payload = stream.begin(.history);
        errdefer stream.cancel();
        try (history.Header{ .key = .alternate, .page_count = 1 }).encode(
            payload,
        );
        try stream.finish();
    }
    try page.encode(
        t.screens.get(.alternate).?.pages
            .getTopLeft(.screen).node.pageAssumeResident(),
        &stream,
    );
    try history.encode(t.screens.get(.primary).?, .primary, &stream, null);
    try checkpoint.encode(.finish, &stream);

    // An unchanged declared screen accepts crafted history, establishing
    // the baseline that the following runs degrade from.
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;

        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqual(TerminalScreenKey.alternate, progress.page.key);
        try testing.expect(progress.page.rows > 0);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
        try testing.expectEqual(
            @as(usize, 2),
            restored.screens.get(.alternate).?.pages.totalPages(),
        );
    }

    // A screen removed since READY discards its history. FINISH still
    // validates, proving discarded records leave the stream aligned.
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        restored.screens.remove(testing.allocator, .alternate);

        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqualDeep(Decoder.Progress{ .page = .{
            .key = .alternate,
            .rows = 0,
            .remaining = 0,
        } }, progress);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
    }

    // A screen removed and recreated since READY has a new generation, so
    // stale history never mixes into its replacement's content.
    {
        var source: std.Io.Reader = .fixed(crafted.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;
        restored.screens.remove(testing.allocator, .alternate);
        _ = try restored.switchScreen(.alternate);

        const progress = (try decoder.next(testing.allocator, restored)).?;
        try testing.expectEqual(TerminalScreenKey.alternate, progress.page.key);
        try testing.expectEqual(0, progress.page.rows);
        try testing.expect(try decoder.next(testing.allocator, restored) == null);
        try testing.expectEqual(
            @as(usize, 1),
            restored.screens.get(.alternate).?.pages.totalPages(),
        );
    }
}

test "incremental decode discards history after a resize" {
    const testing = std.testing;

    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    var source: std.Io.Reader = .fixed(encoded.written());
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    // Encoded pages assume the READY width. After a live resize reflows the
    // restored screen, pending history is consumed but never applied.
    try restored.resize(testing.allocator, .{ .cols = 3, .rows = 3 });
    const primary = restored.screens.get(.primary).?;
    const resized_total = primary.pages.scrollbar().total;

    var pages: usize = 0;
    while (try decoder.next(testing.allocator, &restored)) |progress| {
        try testing.expectEqual(TerminalScreenKey.primary, progress.page.key);
        try testing.expectEqual(0, progress.page.rows);
        pages += 1;
    }
    try testing.expectEqual(2, pages);
    try testing.expectEqual(resized_total, primary.pages.scrollbar().total);
}

test "decode drops history beyond the declared scrollback limits" {
    const testing = std.testing;

    // Declare a byte limit the complete history cannot satisfy. The limit
    // is validated at page granularity on decode, so the snapshot itself
    // remains well formed and fully validated.
    var t = try testHistoryTerminal(3);
    defer t.deinit(testing.allocator);
    t.screens.get(.primary).?.pages.limits.set(.bytes, 1);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    // Incremental: the newest page fits the effective floor, the next page
    // exceeds it, and one drop discards the remainder of the sequence so no
    // ordering gap can form.
    {
        var source: std.Io.Reader = .fixed(encoded.written());
        var decoder: Decoder = .init(&source);
        var decoded = try decoder.ready(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const restored = &decoded.terminal.?;

        var rows: [3]usize = undefined;
        var pages: usize = 0;
        while (try decoder.next(testing.allocator, restored)) |progress| {
            rows[pages] = progress.page.rows;
            pages += 1;
        }
        try testing.expectEqual(3, pages);
        try testing.expectEqualSlices(usize, &.{ 2, 0, 0 }, &rows);

        const primary = restored.screens.get(.primary).?;
        try testing.expectEqual(@as(usize, 2), primary.pages.totalPages());
        try testing.expectEqual(@as(u21, 'C'), testTopLeftCodepoint(primary));
    }

    // The one-shot decoder degrades identically instead of rejecting the
    // snapshot.
    {
        var source: std.Io.Reader = .fixed(encoded.written());
        var decoded = try decode(
            testing.allocator,
            testing.io,
            &source,
            test_decode_options,
        );
        defer decoded.deinit(testing.allocator);
        const primary = decoded.terminal.?.screens.get(.primary).?;
        try testing.expectEqual(@as(usize, 2), primary.pages.totalPages());
        try testing.expectEqual(@as(u21, 'C'), testTopLeftCodepoint(primary));
    }
}

test "incremental decode failure leaves applied history usable" {
    const testing = std.testing;

    var t = try testHistoryTerminal(2);
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    // Truncate FINISH. READY and both history pages decode, then the
    // failure surfaces on the call that would have completed the snapshot.
    var source: std.Io.Reader = .fixed(
        encoded.written()[0 .. encoded.written().len - 1],
    );
    var decoder: Decoder = .init(&source);
    var decoded = try decoder.ready(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    var restored = decoded.toOwned();
    defer restored.deinit(testing.allocator);

    for (0..2) |_| {
        const progress = (try decoder.next(testing.allocator, &restored)).?;
        try testing.expectEqual(2, progress.page.rows);
    }
    try testing.expectError(
        error.EndOfStream,
        decoder.next(testing.allocator, &restored),
    );
    try testing.expectError(
        error.DecoderFailed,
        decoder.next(testing.allocator, &restored),
    );

    // The transferred terminal was never owned by the decoder: it remains
    // valid with the contiguous history prefix that did apply; only the
    // incomplete snapshot stream is lost.
    const primary = restored.screens.get(.primary).?;
    try testing.expectEqual(@as(usize, 3), primary.pages.totalPages());
    try testing.expectEqual(@as(u21, 'A'), testTopLeftCodepoint(primary));
    primary.pages.assertIntegrity();
    primary.assertIntegrity();
}
