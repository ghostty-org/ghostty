//! OSC 72 (Kitty drag-and-drop) chunked payload reassembler.
//!
//! Several OSC 72 events deliver a payload that may be split across multiple
//! sequences. The `m` metadata key flags chunking: `m=1` means more chunks
//! follow, while `m=0` (or an absent `m`) marks the final or only chunk. This
//! accumulates those chunks into a single contiguous payload, modeled on the
//! kitty graphics `LoadingImage` accumulation in
//! `terminal/kitty/graphics_exec.zig`.
//!
//! This is intentionally specific to OSC 72 and is not a shared abstraction.
//! OSC 5522 (kitty clipboard) has the same chunking shape but is handled
//! separately if/when it is implemented.

const std = @import("std");
const Allocator = std.mem.Allocator;

const terminal = @import("../terminal/main.zig");

const EventType = terminal.osc.Command.KittyDndEventType;
const OSC = terminal.osc.Command.KittyDndProtocol;

const log = std.log.scoped(.kitty_dnd);

pub const Reassembler = struct {
    /// The in-progress transfer, if any. Null when idle.
    pending: ?Pending = null,

    /// Maximum total payload size we will accumulate before aborting a
    /// transfer. This guards against unbounded memory growth from a buggy or
    /// malicious sender that never sends a terminating (`m=0`) chunk.
    pub const max_payload = 64 * 1024 * 1024; // 64 MiB

    const Pending = struct {
        /// The event type this transfer belongs to. A chunk for a different
        /// event type aborts the current transfer.
        event: EventType,

        /// The multiplexer session ID (`i` key), or null if unset. A chunk
        /// with a mismatched session ID aborts the current transfer.
        session: ?i32,

        /// Accumulated payload bytes.
        buf: std.ArrayListUnmanaged(u8) = .{},
    };

    pub const Result = union(enum) {
        /// More chunks are expected; there is nothing to dispatch yet.
        incomplete,

        /// The payload is complete. The slice is owned by the caller, who
        /// must free it with the same allocator passed to `feed`.
        complete: []u8,

        /// The chunk was malformed or violated a limit. The transfer has been
        /// reset; the caller should treat this as an error for the transfer.
        invalid,
    };

    pub fn deinit(self: *Reassembler, alloc: Allocator) void {
        self.reset(alloc);
    }

    /// Abort any in-progress transfer and free its buffer. Safe to call when
    /// idle. Useful when a new drag begins or an error response arrives.
    pub fn reset(self: *Reassembler, alloc: Allocator) void {
        if (self.pending) |*p| {
            p.buf.deinit(alloc);
            self.pending = null;
        }
    }

    /// Feed an OSC 72 command carrying a (possibly chunked) payload. The
    /// `event` is the already-decoded `t` key; `cmd` is the raw command whose
    /// `payload` is appended and whose `m`/`i` keys drive chunking.
    pub fn feed(
        self: *Reassembler,
        alloc: Allocator,
        event: EventType,
        cmd: OSC,
    ) Result {
        const session = cmd.readOption(.i);
        const payload = cmd.payload orelse "";

        // If a transfer is in progress for a different event type or session,
        // the stream was interleaved or interrupted. Drop the stale partial
        // and start fresh from this chunk.
        if (self.pending) |*p| {
            if (p.event != event or !sessionEql(p.session, session)) {
                log.warn("dnd chunk context mismatch; resetting partial transfer", .{});
                self.reset(alloc);
            }
        }

        if (self.pending == null) {
            self.pending = .{ .event = event, .session = session };
        }
        const p = &self.pending.?;

        // Enforce the size bound before appending so we never allocate beyond
        // the cap even momentarily.
        if (p.buf.items.len +| payload.len > max_payload) {
            log.warn("dnd payload exceeded {d} bytes; aborting transfer", .{max_payload});
            self.reset(alloc);
            return .invalid;
        }

        p.buf.appendSlice(alloc, payload) catch {
            self.reset(alloc);
            return .invalid;
        };

        // `m=1` means more chunks follow. `m=0` or an absent `m` is the final
        // (or only) chunk.
        const more = (cmd.readOption(.m) orelse 0) == 1;
        if (more) return .incomplete;

        // Complete: hand ownership of the accumulated buffer to the caller and
        // return to the idle state.
        const owned = p.buf.toOwnedSlice(alloc) catch {
            self.reset(alloc);
            return .invalid;
        };
        self.pending = null;
        return .{ .complete = owned };
    }

    fn sessionEql(a: ?i32, b: ?i32) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.? == b.?;
    }
};

test "single unchunked payload completes immediately" {
    const testing = std.testing;
    var r: Reassembler = .{};
    defer r.deinit(testing.allocator);

    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=p:i=1;hello";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.kitty_dnd_protocol;

    const result = r.feed(testing.allocator, .present_data, cmd);
    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete);
    try testing.expectEqualStrings("hello", result.complete);
    try testing.expect(r.pending == null);
}

test "multi-chunk payload concatenates in order" {
    const testing = std.testing;
    var r: Reassembler = .{};
    defer r.deinit(testing.allocator);

    const chunks = [_][]const u8{
        "72;t=p:i=7:m=1;foo",
        "72;t=p:i=7:m=1;bar",
        "72;t=p:i=7:m=0;baz",
    };

    var result: Reassembler.Result = .incomplete;
    for (chunks) |input| {
        var p: terminal.osc.Parser = .init(testing.allocator);
        defer p.deinit();
        for (input) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.kitty_dnd_protocol;
        result = r.feed(testing.allocator, .present_data, cmd);
    }

    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete);
    try testing.expectEqualStrings("foobarbaz", result.complete);
    try testing.expect(r.pending == null);
}

test "mismatched session resets the partial transfer" {
    const testing = std.testing;
    var r: Reassembler = .{};
    defer r.deinit(testing.allocator);

    const inputs = [_][]const u8{
        "72;t=p:i=1:m=1;aaa", // start session 1
        "72;t=p:i=2:m=0;bbb", // different session: resets, completes alone
    };

    var result: Reassembler.Result = .incomplete;
    for (inputs) |input| {
        var p: terminal.osc.Parser = .init(testing.allocator);
        defer p.deinit();
        for (input) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.kitty_dnd_protocol;
        result = r.feed(testing.allocator, .present_data, cmd);
    }

    try testing.expect(result == .complete);
    defer testing.allocator.free(result.complete);
    try testing.expectEqualStrings("bbb", result.complete);
}

test "mismatched event type resets the partial transfer" {
    const testing = std.testing;
    var r: Reassembler = .{};
    defer r.deinit(testing.allocator);

    {
        var p: terminal.osc.Parser = .init(testing.allocator);
        defer p.deinit();
        const input = "72;t=p:i=1:m=1;aaa";
        for (input) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.kitty_dnd_protocol;
        try testing.expect(r.feed(testing.allocator, .present_data, cmd) == .incomplete);
    }

    {
        var p: terminal.osc.Parser = .init(testing.allocator);
        defer p.deinit();
        const input = "72;t=P:i=1:m=0;img";
        for (input) |ch| p.next(ch);
        const cmd = p.end('\x1b').?.kitty_dnd_protocol;
        const result = r.feed(testing.allocator, .change_drag_image, cmd);
        try testing.expect(result == .complete);
        defer testing.allocator.free(result.complete);
        try testing.expectEqualStrings("img", result.complete);
    }
}

test "reset frees an in-progress transfer" {
    const testing = std.testing;
    var r: Reassembler = .{};
    defer r.deinit(testing.allocator);

    var p: terminal.osc.Parser = .init(testing.allocator);
    defer p.deinit();
    const input = "72;t=p:i=1:m=1;partial";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.kitty_dnd_protocol;

    try testing.expect(r.feed(testing.allocator, .present_data, cmd) == .incomplete);
    try testing.expect(r.pending != null);
    r.reset(testing.allocator);
    try testing.expect(r.pending == null);
}
