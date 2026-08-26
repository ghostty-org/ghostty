const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const UTF8Decoder = @import("UTF8Decoder.zig");

/// Errors possible while validating a snapshot continuation.
pub const ValidateError = error{
    /// Nonempty input left both the VT parser and UTF-8 decoder at ground.
    ///
    /// A continuation exists only to reconstruct state that was unfinished at
    /// the snapshot cut. Input that returns to ground is a complete PTY
    /// fragment, not a continuation. Replaying it would repeat work already
    /// represented by the Terminal snapshot. For example, `ESC [ 3 1 m`
    /// completes an SGR command and must not be stored as a continuation.
    NoPendingState,

    /// The input does not begin at its effective replay start.
    ///
    /// A later ESC supersedes earlier VT parser state, and a pending UTF-8
    /// codepoint begins at its lead byte. Any prefix before that effective
    /// start is unnecessary and would disappear when the restored Stream
    /// exports its continuation again. Rejecting the prefix preserves the
    /// byte-identical re-export invariant and prevents unrelated prior input
    /// from being replayed.
    NonCanonicalContinuation,

    /// Replaying the input would perform handler-visible work.
    ///
    /// The Terminal snapshot already contains every mutation committed before
    /// its capture cut. A continuation may rebuild unfinished parser or
    /// builder state, but it must not mutate the Terminal or repeat an external
    /// effect while doing so. For example, BEL inside an unfinished CSI would
    /// ring again even though the CSI itself remains pending.
    ReplayWouldCommit,
};

/// Validate continuation bytes.
///
/// Ensure that:
///
///   - replay ends with either VT or UTF-8 state unfinished
///   - byte zero is the effective start needed to reconstruct that state
///   - replay commits no Terminal mutation or external handler effect
pub fn validate(bytes: []const u8) ValidateError!void {
    // Empty explicitly requests ground state and needs no replay.
    if (bytes.len == 0) return;

    // We need the final parser and decoder states to classify the input, so a
    // committed byte cannot return early. Remember it while scanning the rest.
    var scanner: BoundaryScanner = .init();
    var committed_work = false;
    for (bytes) |byte| {
        if (scanner.next(byte) != .uncommitted) committed_work = true;
    }

    // Nonempty continuation bytes must leave state that future input needs.
    if (scanner.ground()) return error.NoPendingState;

    // The tracker exports the minimal suffix beginning at the effective replay
    // start. A different prefix would not survive byte-identical re-export.
    const replay_start = if (scanner.parser.state != .ground)
        findVTReplayStart(bytes)
    else
        findUtf8ReplayStart(bytes);
    if (replay_start != 0) return error.NonCanonicalContinuation;

    // At this point the input is unfinished and minimal, but replay must also
    // be inert with respect to the already-restored Terminal and its effects.
    if (committed_work) return error.ReplayWouldCommit;
}

/// Retains the input needed to reconstruct unfinished Stream parser state.
///
/// A feed is one chunk of bytes given to a Stream. It can end in the middle of
/// a VT sequence or a UTF-8 codepoint. To continue in another Stream, that
/// Stream starts from ground (with no sequence in progress) and reads the
/// saved bytes again. The first saved byte is called the replay start.
///
/// Stream updates this tracker once per feed based on where that replay start
/// is:
///
///   - Ground (parser and UTF-8 decoder): `reset`, no suffix is needed.
///   - Anything unfinished: `append`, which replaces the suffix with the
///     bytes from the replay start onward when that start is inside this
///     feed, and otherwise extends the suffix with this whole feed because
///     the unfinished state began in an earlier one.
///
/// This keeps the retained bytes minimal: they always begin at the replay
/// start, so the feed path never needs to parse or trim old input. The suffix
/// may still contain a byte whose visible terminal effect already happened,
/// such as BEL inside an unfinished CSI sequence. `write` leaves out those
/// bytes so replay does not perform the same effect twice.
///
/// If the suffix exceeds `max_bytes`, or retaining it fails, `broken`
/// is set until a later feed ends at ground (`reset`) or contains a new
/// replay start (`replace`), both of which need nothing that was lost.
///
/// Replay semantics are guaranteed for the standard TerminalStream handler.
/// Custom handlers, including handlers that intercept vtRaw, are unsupported.
pub const Tracker = struct {
    const initial_capacity = 4096;

    alloc: Allocator,
    max_bytes: usize,
    bytes: std.ArrayList(u8) = .empty,
    broken: bool = false,

    /// Initialize a tracker.
    pub fn init(alloc: Allocator, max_bytes: usize) Tracker {
        var result: Tracker = .{
            .alloc = alloc,
            .max_bytes = max_bytes,
        };
        result.bytes.ensureTotalCapacity(
            alloc,
            @min(max_bytes, initial_capacity),
        ) catch {
            // We ignore memory errors here. They'll mark the tracker
            // as broken in a future append.

        };
        return result;
    }

    pub fn deinit(self: *Tracker) void {
        self.bytes.deinit(self.alloc);
    }

    /// Clear the current continuation suffix and broken state while keeping
    /// its allocation. Stream calls this after reaching ground because no
    /// earlier input is needed to reconstruct the next unfinished state.
    pub fn reset(self: *Tracker) void {
        self.broken = false;
        self.bytes.clearRetainingCapacity();
    }

    /// Which state machine is unfinished at the end of a feed. When the VT
    /// parser is outside ground the unfinished state is an escape sequence.
    /// When it is grounded, only the UTF-8 decoder can be unfinished, with
    /// an incomplete codepoint ending the feed.
    pub const Pending = enum { vt, utf8 };

    /// Retain the part of `input` needed to replay a feed that ended with
    /// `pending` state unfinished.
    ///
    /// When the input contains the replay start for that state, it replaces
    /// the retained suffix outright because nothing earlier is needed. The
    /// new suffix is complete on its own, so this also repairs a broken
    /// tracker. Otherwise the unfinished state began in an earlier feed and
    /// this whole input extends the current suffix.
    pub fn append(self: *Tracker, pending: Pending, input: []const u8) void {
        const start = switch (pending) {
            .vt => findVTReplayStart(input),
            .utf8 => findUtf8ReplayStart(input),
        } orelse {
            self.extend(input);
            return;
        };
        self.replace(input[start..]);
    }

    /// Replace the continuation suffix with one that has a new replay start.
    fn replace(self: *Tracker, suffix: []const u8) void {
        self.bytes.clearRetainingCapacity();
        if (suffix.len > self.max_bytes) {
            self.markBroken();
            return;
        }
        self.bytes.appendSlice(self.alloc, suffix) catch {
            self.markBroken();
            return;
        };
        self.broken = false;
    }

    /// Extend the continuation suffix with a fragment that contains no replay
    /// start of its own. The stream stayed unfinished for the whole fragment,
    /// so the existing suffix plus this fragment reproduces the current state.
    fn extend(self: *Tracker, fragment: []const u8) void {
        if (self.broken) return;
        if (fragment.len > self.max_bytes -| self.bytes.items.len) {
            self.markBroken();
            return;
        }
        self.bytes.appendSlice(self.alloc, fragment) catch self.markBroken();
    }

    /// Write the replay-safe continuation suffix to `writer`. The retained
    /// bytes already begin at the replay start; this omits only bytes that
    /// would repeat committed terminal effects without contributing to the
    /// unfinished parser state (e.g. a BEL inside an unfinished CSI). The
    /// tracker must not be broken.
    pub fn write(
        self: *const Tracker,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var scanner: BoundaryScanner = .init();
        for (self.bytes.items) |c| {
            if (scanner.next(c) == .omittable) continue;
            try writer.writeByte(c);
        }
    }

    fn markBroken(self: *Tracker) void {
        self.broken = true;
        self.bytes.clearRetainingCapacity();
    }
};

/// Find where replay must begin when a feed ends inside a VT sequence.
///
/// VT parsers treat ESC specially: it abandons the previous parser state and
/// starts a fresh escape state no matter what was being parsed. Because of
/// that rule, feeding the bytes from the last ESC onward into a grounded
/// Stream recreates the unfinished state at the end of `input`.
///
/// The caller must only use this when the VT parser ended outside ground.
/// The returned value is the index of the last ESC in `input`. A null result
/// means the sequence began in an earlier feed, so this entire input must be
/// appended to the continuation bytes already retained.
fn findVTReplayStart(input: []const u8) ?usize {
    const esc: u8 = 0x1B;
    var rem: usize = input.len;

    // Escape sequences are short, so when the stream ends inside one the
    // replay start is usually within the last few bytes. Scan backward in
    // vector chunks; pure payload inputs (no ESC at all) still scan quickly.
    if (comptime std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Bits = std.meta.Int(.unsigned, lanes);
        const needle: V = @splat(esc);

        // Process several vectors per iteration so long inputs without ESC
        // (e.g. huge string payloads) stay memory-bound rather than
        // loop-bound. On a match, rescan the group precisely.
        const unroll = 4;
        while (rem >= lanes * unroll) {
            const start = rem - lanes * unroll;
            var match: @Vector(lanes, bool) = @splat(false);
            inline for (0..unroll) |block| {
                const v: V = input[start + block * lanes ..][0..lanes].*;
                match = match | (v == needle);
            }
            if (@reduce(.Or, match)) {
                inline for (0..unroll) |i| {
                    const block = unroll - 1 - i;
                    const v: V = input[start + block * lanes ..][0..lanes].*;
                    const bits: Bits = @bitCast(v == needle);
                    if (bits != 0) {
                        return start + block * lanes + (lanes - 1 - @clz(bits));
                    }
                }
                unreachable;
            }
            rem = start;
        }

        while (rem >= lanes) {
            const start = rem - lanes;
            const v: V = input[start..][0..lanes].*;
            const bits: Bits = @bitCast(v == needle);
            if (bits != 0) return start + (lanes - 1 - @clz(bits));
            rem = start;
        }
    }

    while (rem > 0) {
        rem -= 1;
        if (input[rem] == esc) return rem;
    }
    return null;
}

/// Find where replay must begin when a feed ends inside a UTF-8 codepoint.
///
/// A UTF-8 codepoint starts with a lead byte and may have up to three
/// continuation bytes. If the lead byte is in this input, replay must begin
/// there so the decoder sees the complete partial codepoint again. Since an
/// incomplete codepoint can contain at most three bytes, only the final three
/// input bytes need to be searched.
///
/// The caller must only use this when the VT parser is at ground and the
/// UTF-8 decoder ended mid-codepoint. The returned value is the lead byte's
/// index. A null result means the lead byte was in an earlier feed, so this
/// entire input must be appended to the continuation bytes already retained.
fn findUtf8ReplayStart(input: []const u8) ?usize {
    const max_pending = 3;
    var idx = input.len;
    while (idx > 0 and input.len - idx < max_pending) {
        idx -= 1;
        if (input[idx] >= 0xC0) return idx;
    }
    return null;
}

/// Classifies bytes of a continuation suffix for export.
///
/// The retained suffix reconstructs unfinished state exactly, but it can
/// contain bytes whose handler-visible work already committed the first
/// time (e.g. a C0 control executed inside an unfinished CSI sequence).
/// This implements a minimal VT stream processor (to avoid circular imports
/// with stream.zig) so `Tracker.write` can omit those bytes and replay
/// never repeats a terminal effect. It only runs at export time, never on
/// the feed path.
///
/// This is allocation-free.
const BoundaryScanner = struct {
    parser: Parser,
    utf8decoder: UTF8Decoder,

    /// Initialize both state machines at runtime. Parser initialization may
    /// inspect the runtime environment, so it cannot be a struct field default
    /// that Zig requires to be comptime-known.
    fn init() BoundaryScanner {
        return .{
            .parser = .init(),
            .utf8decoder = .{},
        };
    }

    /// How one byte affects committed work and the continuation suffix.
    const Effect = enum {
        /// The byte commits no handler-visible work. It must remain because it
        /// may still build the unfinished VT, UTF-8, APC, or DCS state.
        uncommitted,

        /// The byte commits handler-visible work but also changes a parser
        /// state tag or reaches ground. It cannot be omitted in isolation;
        /// boundary analysis decides whether the surrounding prefix is safe.
        committed,

        /// The byte commits handler-visible work without changing either
        /// state-machine tag or reaching ground. It can be omitted without
        /// changing the unfinished state, avoiding a duplicate effect.
        omittable,
    };

    /// True only when neither state machine needs prior bytes to continue.
    fn ground(self: *const BoundaryScanner) bool {
        return self.parser.state == .ground and self.utf8decoder.state == 0;
    }

    /// Consume one byte using the same scalar UTF-8 retry and VT transitions
    /// as Stream, then classify its effect on continuation construction.
    fn next(self: *BoundaryScanner, c: u8) Effect {
        // Preserve the state tags so we can recognize committed controls that
        // do not contribute to the unfinished sequence.
        const parser_state = self.parser.state;
        const utf8_state = self.utf8decoder.state;

        // A byte is committed when replaying it would repeat handler-visible
        // work already captured outside the continuation suffix. Actions that
        // only build unfinished APC or DCS state are not committed because
        // replay must reconstruct that state.
        const committed = committed: {
            if (self.parser.state == .ground) {
                // Match Stream's scalar UTF-8 path, including retrying a byte that
                // follows a malformed sequence.
                var committed = false;
                const res = self.utf8decoder.next(c);
                if (res[0]) |cp| committed = self.codepoint(cp) or committed;
                if (!res[1]) {
                    const retry = self.utf8decoder.next(c);
                    assert(retry[1]);
                    if (retry[0]) |cp| committed = self.codepoint(cp) or committed;
                }

                break :committed committed;
            }

            const actions = self.parser.next(c);
            for (actions) |action_opt| {
                const action = action_opt orelse continue;
                switch (action) {
                    // These actions only build standard handler state. Their
                    // matching end/unhook actions are committed work.
                    .dcs_hook,
                    .dcs_put,
                    .apc_start,
                    .apc_put,
                    => {},
                    else => break :committed true,
                }
            }

            break :committed false;
        };

        if (!committed) return .uncommitted;

        // A committed byte is independently omittable only while the stream
        // remains unfinished and neither state-machine tag changes.
        const state_changed = parser_state != self.parser.state or
            utf8_state != self.utf8decoder.state;
        return if (!state_changed and !self.ground())
            .omittable
        else
            .committed;
    }

    /// Apply the Stream.handleCodepoint behavior relevant to replay. Returns
    /// whether the accepted codepoint would commit handler-visible work.
    fn codepoint(self: *BoundaryScanner, cp: u21) bool {
        if (cp == 0x1B) {
            self.parser.state = .escape;
            self.parser.clear();
            return false;
        }

        // Match Stream.handleCodepoint: all other accepted codepoints have
        // already caused a handler-visible action (including supported C0s).
        return true;
    }
};

test "boundary scanner classifies effects and ground" {
    const testing = std.testing;
    var scanner: BoundaryScanner = .init();

    try testing.expect(scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.committed, scanner.next('A'));
    try testing.expect(scanner.ground());

    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next(0x1B));
    try testing.expect(!scanner.ground());
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next('['));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, scanner.next('1'));

    // BEL commits an execute action without changing the unfinished CSI.
    try testing.expectEqual(BoundaryScanner.Effect.omittable, scanner.next(0x07));
    try testing.expect(!scanner.ground());

    try testing.expectEqual(BoundaryScanner.Effect.committed, scanner.next('m'));
    try testing.expect(scanner.ground());
}

test "boundary scanner preserves unfinished builder actions" {
    const testing = std.testing;

    var apc: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next(0x1B));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next('_'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, apc.next('G'));
    try testing.expectEqual(BoundaryScanner.Effect.committed, apc.next(0x1B));

    var dcs: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next(0x1B));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('P'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('q'));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, dcs.next('x'));
    try testing.expectEqual(BoundaryScanner.Effect.committed, dcs.next(0x1B));
}

test "boundary scanner handles UTF-8 and malformed retries" {
    const testing = std.testing;

    var valid: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0xF0));
    try testing.expect(!valid.ground());
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0x9F));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, valid.next(0x98));
    try testing.expectEqual(BoundaryScanner.Effect.committed, valid.next(0x84));
    try testing.expect(valid.ground());

    var malformed: BoundaryScanner = .init();
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, malformed.next(0xE0));
    try testing.expectEqual(BoundaryScanner.Effect.uncommitted, malformed.next(0xA0));
    try testing.expect(malformed.next(0xF0) != .uncommitted);
    try testing.expect(!malformed.ground());
}

test "findVTReplayStart finds the latest ESC across vector boundaries" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, null), findVTReplayStart(""));
    try testing.expectEqual(@as(?usize, null), findVTReplayStart("no escapes here"));
    try testing.expectEqual(@as(?usize, 0), findVTReplayStart("\x1b"));
    try testing.expectEqual(@as(?usize, 5), findVTReplayStart("\x1b[1m\x20\x1b[2"));

    // Exercise both the vector loop and the scalar remainder with replay
    // starts at every position of a buffer larger than any vector width.
    var buf: [193]u8 = undefined;
    @memset(&buf, 'a');
    try testing.expectEqual(@as(?usize, null), findVTReplayStart(&buf));
    for (0..buf.len) |idx| {
        @memset(&buf, 'a');
        buf[idx] = 0x1B;
        try testing.expectEqual(@as(?usize, idx), findVTReplayStart(&buf));

        // The latest ESC wins.
        if (idx > 0) {
            buf[idx - 1] = 0x1B;
            try testing.expectEqual(@as(?usize, idx), findVTReplayStart(&buf));
        }
    }
}

test "findUtf8ReplayStart finds the pending lead byte" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart(""));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0"));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0\x9F"));
    try testing.expectEqual(@as(?usize, 4), findUtf8ReplayStart("text\xF0\x9F\x98"));
    try testing.expectEqual(@as(?usize, 0), findUtf8ReplayStart("\xE0\xA0"));

    // A malformed prefix rejected earlier doesn't hide the pending lead.
    try testing.expectEqual(@as(?usize, 2), findUtf8ReplayStart("\xE0\xA0\xF0"));

    // Continuation bytes of a sequence that started in an earlier input have
    // no replay start of their own.
    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart("\x9F"));
    try testing.expectEqual(@as(?usize, null), findUtf8ReplayStart("\x9F\x98"));
}

test "tracker retains and normalizes replay-safe bytes" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 64);
    defer tracker.deinit();

    tracker.append(.vt, "committed\x1b[1\x07");
    tracker.append(.vt, ";2");
    try testing.expect(!tracker.broken);

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try tracker.write(&writer);
    try testing.expectEqualStrings("\x1b[1;2", writer.buffered());

    // A feed with a later replay start drops the previous suffix entirely.
    tracker.append(.vt, "committed\x1b]0;t");
    var replaced_buf: [64]u8 = undefined;
    var replaced_writer: std.Io.Writer = .fixed(&replaced_buf);
    try tracker.write(&replaced_writer);
    try testing.expectEqualStrings("\x1b]0;t", replaced_writer.buffered());

    // An incomplete UTF-8 codepoint seeds at its lead byte and grows with
    // continuation bytes from later feeds.
    tracker.append(.utf8, "committed\xF0");
    tracker.append(.utf8, "\x9F");
    var utf8_buf: [4]u8 = undefined;
    var utf8_writer: std.Io.Writer = .fixed(&utf8_buf);
    try tracker.write(&utf8_writer);
    try testing.expectEqualSlices(u8, "\xF0\x9F", utf8_writer.buffered());
}

test "tracker cap, reset, and broken recovery" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 4);
    defer tracker.deinit();

    tracker.append(.vt, "\x1b[123");
    try testing.expect(tracker.broken);

    // Feeds without a replay start are dropped while broken.
    tracker.append(.vt, "4");
    try testing.expect(tracker.broken);
    try testing.expectEqual(@as(usize, 0), tracker.bytes.items.len);

    // Suffixes that grow past the cap break tracking.
    tracker.reset();
    tracker.append(.vt, "\x1b[1");
    tracker.append(.vt, "23");
    try testing.expect(tracker.broken);

    // A new replay start that fits recovers without a reset.
    tracker.append(.vt, "\x1b[");
    try testing.expect(!tracker.broken);
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try tracker.write(&writer);
    try testing.expectEqualStrings("\x1b[", writer.buffered());

    tracker.append(.vt, "\x1b[123");
    try testing.expect(tracker.broken);
    tracker.reset();
    try testing.expect(!tracker.broken);
    var empty_buf: [1]u8 = undefined;
    var empty_writer: std.Io.Writer = .fixed(&empty_buf);
    try tracker.write(&empty_writer);
    try testing.expectEqual(@as(usize, 0), empty_writer.end);
}

test "tracker reports writer failure and defers allocation failure" {
    const testing = std.testing;
    var tracker = Tracker.init(testing.allocator, 64);
    defer tracker.deinit();
    tracker.append(.vt, "\x1b[");

    var buf: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, tracker.write(&writer));

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var failing_tracker = Tracker.init(failing.allocator(), 64);
    defer failing_tracker.deinit();
    try testing.expect(!failing_tracker.broken);

    // The best-effort initial reservation failed, so the first required
    // retention retries allocation and marks the tracker broken.
    failing_tracker.append(.vt, "\x1b[");
    try testing.expect(failing_tracker.broken);
}
