//! End-to-end tests for the OSC 72 protocol state machine, validating
//! wire behavior against kitty's implementation (using kitty_tests/dnd.py as
//! an oracle for the expected bytes).
//!
//! It isn't normal for us to have dedicated test files but in this case
//! the dnd protocol is complicated enough that I wanted full e2e covering
//! the full machine.

const std = @import("std");
const testing = std.testing;

const osc = @import("../osc.zig");
const dnd = @import("dnd.zig");

/// A test harness holding the lazily allocated protocol state and an
/// output collector.
const Harness = struct {
    state: ?*dnd.State = null,
    output: std.Io.Writer.Allocating,

    fn init() Harness {
        return .{ .output = .init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        if (self.state) |state| state.destroy(testing.allocator);
        self.output.deinit();
    }

    /// The registered state; asserts a client has registered.
    fn registered(self: *Harness) *dnd.State {
        return self.state.?;
    }

    /// Feed one client command, as it would arrive from the OSC parser,
    /// returning the event the stream handler would pass to its effect.
    fn command(self: *Harness, metadata: []const u8, payload: ?[]const u8) !?dnd.Event {
        return try dnd.handleCommand(&self.state, testing.allocator, &self.output.writer, .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .st,
        });
    }

    /// Consume and return the collected output.
    fn consume(self: *Harness) []const u8 {
        const written = self.output.written();
        return written;
    }

    fn clear(self: *Harness) void {
        self.output.clearRetainingCapacity();
    }

    fn expectOutput(self: *Harness, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.output.written());
        self.clear();
    }
};

test "dnd: query response" {
    var h: Harness = .init();
    defer h.deinit();

    // Works without any registration, matching kitty, and allocates
    // nothing.
    _ = try h.command("t=q", null);
    try h.expectOutput("\x1b]72;t=q\x1b\\");
    try testing.expect(h.state == null);
}

test "dnd: query response echoes client id" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=q:i=31", null);
    try h.expectOutput("\x1b]72;t=q:i=31\x1b\\");
}

test "dnd: register and unregister" {
    var h: Harness = .init();
    defer h.deinit();

    try testing.expect(h.state == null);

    // Registration allocates the state and reports it, with the
    // declared MIME list readable from the state.
    try testing.expect((try h.command("t=a", "text/plain text/uri-list")).? == .registration);
    try h.expectOutput("");
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("text/plain", it.next().?);
        try testing.expectEqualStrings("text/uri-list", it.next().?);
        try testing.expect(it.next() == null);
    }

    // Machine ID declaration is accepted and ignored.
    try testing.expect((try h.command("t=a:x=1", "1:deadbeef")) == null);
    try h.expectOutput("");
    try testing.expect(h.state != null);

    // Re-registration replaces the list.
    try testing.expect((try h.command("t=a", "image/png")).? == .registration);
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("image/png", it.next().?);
        try testing.expect(it.next() == null);
    }

    // Registering without a list is the common case.
    try testing.expect((try h.command("t=a", null)).? == .registration);
    {
        var it = h.registered().registeredMimes();
        try testing.expect(it.next() == null);
    }

    // Unregistration frees it and reports the change.
    try testing.expect((try h.command("t=A", null)).? == .registration);
    try h.expectOutput("");
    try testing.expect(h.state == null);

    // Unregistering again changes nothing.
    try testing.expect((try h.command("t=A", null)) == null);
    try h.expectOutput("");
    try testing.expect(h.state == null);
}

test "dnd: no state before registration" {
    var h: Harness = .init();
    defer h.deinit();

    // State-dependent commands from an unregistered client allocate
    // nothing; a data request gets the error kitty sends from its
    // zeroed state.
    _ = try h.command("t=m:o=1", "text/plain");
    _ = try h.command("t=r", null);
    try h.expectOutput("");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
    try testing.expect(h.state == null);
}

test "dnd: move event carries position, operations, and mime list" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "text/plain");

    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 5,
        .cell_y = 3,
        .pixel_x = 100,
        .pixel_y = 60,
        .operations = .{ .copy = true },
    }, &.{ "text/plain", "text/uri-list" });

    // Note the trailing space after every MIME entry, matching kitty.
    try h.expectOutput(
        "\x1b]72;t=m:x=5:y=3:X=100:Y=60:o=1:m=0;text/plain text/uri-list \x1b\\",
    );
}

test "dnd: move event echoes registration client id" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a:i=7", "");
    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 1,
        .cell_y = 2,
        .pixel_x = 8,
        .pixel_y = 16,
        .operations = .{ .copy = true, .move = true },
    }, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=1:y=2:X=8:Y=16:o=3:i=7:m=0;text/plain \x1b\\");
}

test "dnd: re-registration updates client id in place" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a:i=7", "");
    const state = h.registered();
    _ = try h.command("t=a:i=9", "");
    // Same allocation, new client ID.
    try testing.expect(h.state.? == state);
    try testing.expectEqual(@as(u32, 9), state.drop.client_id);
}

test "dnd: mime list sent on every move" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    const ev: dnd.MoveEvent = .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    };
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    h.clear();

    // Kitty resends the list even when unchanged; clients depend on it.
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=0:y=0:X=0:Y=0:o=1:m=0;text/plain \x1b\\");
}

test "dnd: leave event" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try h.registered().dragMove(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{"text/plain"});
    h.clear();

    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("\x1b]72;t=m:x=-1:y=-1\x1b\\");
}

test "dnd: client acceptance recorded" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try testing.expect(h.registered().clientAccepted() == null);

    try testing.expect((try h.command("t=m:o=1", "text/plain")).? == .acceptance);
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.registered().clientAccepted().?);

    // Rejection.
    try testing.expect((try h.command("t=m:o=0", "")).? == .acceptance);
    try testing.expectEqual(dnd.Operation.none, h.registered().clientAccepted().?);
}

test "dnd: chunked client acceptance" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");

    // Chunked accept: continuation metadata is ignored, the acceptance
    // is pending until the final chunk.
    try testing.expect((try h.command("t=m:o=2:m=1", "text/pl")) == null);
    try testing.expect(h.registered().clientAccepted() == null);
    try testing.expect((try h.command("t=m:m=1", "ain text")) == null);
    try testing.expect((try h.command("t=m:m=0", "/html")).? == .acceptance);
    try testing.expectEqual(dnd.Operation.move, h.registered().clientAccepted().?);

    // The accumulated list was converted to NUL-separated entries.
    try testing.expectEqualSlices(
        u8,
        "text/plain\x00text/html\x00",
        h.registered().drop.accepted_mimes.items,
    );
}

test "dnd: drop and data serving round trip" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "text/plain text/uri-list");

    const ev: dnd.MoveEvent = .{
        .cell_x = 4,
        .cell_y = 2,
        .pixel_x = 40,
        .pixel_y = 20,
        .operations = .{ .copy = true },
    };
    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/uri-list", .data = "file:///tmp/a.txt\r\n" },
        .{ .mime = "text/plain", .data = "hello" },
    });
    try h.expectOutput(
        "\x1b]72;t=M:x=4:y=2:X=40:Y=20:o=1:m=0;text/uri-list text/plain \x1b\\",
    );

    // Request the second MIME's data: base64 chunk plus the empty
    // end-of-data message.
    _ = try h.command("t=r:x=2", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=2:m=0;aGVsbG8=\x1b\\" ++ "\x1b]72;t=r:x=2\x1b\\",
    );

    // Out-of-bounds request.
    _ = try h.command("t=r:x=3", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=3:m=0;ENOENT:drop data request index out of bounds\x1b\\",
    );

    // Conclude: the performed operation is reported, held data is
    // freed, and further requests fail.
    try testing.expectEqual(dnd.Event.concluded_copy, (try h.command("t=r:o=1", null)).?);
    try h.expectOutput("");
    try testing.expect((try h.command("t=r:o=1", null)) == null);
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}

test "dnd: empty item served as a single end-of-data message" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "" }});
    h.clear();

    // Kitty's oracle (test_empty_data) asserts exactly one message:
    // the empty response is itself the end-of-data signal, and a
    // duplicate would be a second completion to the client.
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput("\x1b]72;t=r:x=1\x1b\\");
}

test "dnd: leave without hover sends nothing" {
    var h: Harness = .init();
    defer h.deinit();

    // Client registered but no move was ever forwarded (e.g. it
    // registered mid-drag): kitty only notifies hovered windows.
    _ = try h.command("t=a", "");
    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("");
}

test "dnd: data request with no drop" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}

test "dnd: leave after drop is ignored" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "x" }});
    h.clear();

    // Some toolkits emit a leave for the drop itself; the held data
    // must survive so the client can still fetch it.
    try h.registered().dragLeave(testing.allocator, &h.output.writer);
    try h.expectOutput("");

    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;eA==\x1b\\" ++ "\x1b]72;t=r:x=1\x1b\\",
    );
}

test "dnd: new drag resets held drop data" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    const ev: dnd.MoveEvent = .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    };
    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/plain", .data = "old" },
    });
    h.clear();

    // A new drag entering resets the per-drag state including the held
    // items from the unconcluded previous drop.
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    h.clear();
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;ENOENT:no drop data available\x1b\\",
    );
}

test "dnd: remote transfer requests refused" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");

    // URI file content request.
    _ = try h.command("t=r:x=1:y=2", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:y=2:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );

    // Directory handle request.
    _ = try h.command("t=r:Y=2:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:Y=2:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );
}

test "dnd: drag out refused" {
    var h: Harness = .init();
    defer h.deinit();

    // Enabling and disabling offers is accepted silently and allocates
    // nothing.
    _ = try h.command("t=o:x=1", null);
    _ = try h.command("t=o:x=2", null);
    try h.expectOutput("");
    try testing.expect(h.state == null);

    // Offering a drag is refused.
    _ = try h.command("t=o:x=1", null);
    _ = try h.command("t=o:o=3", "text/plain");
    try h.expectOutput(
        "\x1b]72;t=E:m=0;EPERM:drag out is not supported by this terminal\x1b\\",
    );

    // Starting a drag is refused, echoing the command's client id.
    _ = try h.command("t=P:x=-1:i=9", null);
    try h.expectOutput(
        "\x1b]72;t=E:i=9:m=0;EPERM:drag out is not supported by this terminal\x1b\\",
    );
    try testing.expect(h.state == null);
}

test "dnd: unregister frees held drop data" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "text/plain", .data = "x" }});
    h.clear();

    // The testing allocator would report the held data as leaked if
    // unregistration didn't free the whole state.
    _ = try h.command("t=A", null);
    try testing.expect(h.state == null);
}

test "dnd: chunked registration reuses first chunk metadata" {
    var h: Harness = .init();
    defer h.deinit();

    // Registration split over two chunks: the first chunk allocates
    // the state and seeds chunk reassembly, so the continuation (which
    // carries a different type) is still treated as the registration.
    try testing.expect((try h.command("t=a:i=4:m=1", "text/pla")) == null);
    try testing.expect(h.state != null);
    try testing.expect((try h.command("t=q:m=0", "in")).? == .registration);
    try h.expectOutput("");
    try testing.expectEqual(@as(u32, 4), h.registered().drop.client_id);
    {
        var it = h.registered().registeredMimes();
        try testing.expectEqualStrings("text/plain", it.next().?);
    }

    // A query after the chunked command completes works again.
    _ = try h.command("t=q", null);
    try h.expectOutput("\x1b]72;t=q\x1b\\");
}

test "dnd: malformed metadata ignored" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a:zz=1", "");
    try h.expectOutput("");
    try testing.expect(h.state == null);

    // Command with no type is ignored, matching kitty (the spec's
    // default of t=a is not honored by the reference implementation).
    _ = try h.command("x=1", "");
    try h.expectOutput("");
    try testing.expect(h.state == null);
}

test "dnd: bel terminator echoed in responses" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try dnd.handleCommand(&h.state, testing.allocator, &h.output.writer, .{
        .metadata = "t=q",
        .payload = null,
        .terminator = .bel,
    });
    try h.expectOutput("\x1b]72;t=q\x07");
}

test "dnd: kitten 0.47 conversation replay" {
    // This replays a conversation recorded from the reference client
    // (`kitten dnd --drop-anywhere=copy --drop text/plain:out.txt`,
    // kitten 0.47.0) driven over a pty by a harness that sent exactly
    // the bytes this engine produces. The kitten accepted the events,
    // wrote the dropped payload to disk intact, and concluded; its
    // client bytes are frozen here as an interop regression test.
    var h: Harness = .init();
    defer h.deinit();

    // Startup: register with MIME list and machine ID, then the test
    // harness reset (unregister both directions, re-register).
    _ = try h.command("t=a:m=0", "text/uri-list text/plain");
    _ = try h.command(
        "t=a:x=1:m=0",
        "1:5cff8247c477900a8727e2281fe890252f8848f87c224dd8dd7fb6303e94ddbd",
    );
    _ = try h.command("t=A", null);
    try testing.expect(h.state == null);
    _ = try h.command("t=o:x=2", null);
    _ = try h.command("t=a:m=0", "text/uri-list text/plain");
    _ = try h.command(
        "t=a:x=1:m=0",
        "1:5cff8247c477900a8727e2281fe890252f8848f87c224dd8dd7fb6303e94ddbd",
    );
    try h.expectOutput("");
    try testing.expect(h.state != null);

    // Native drag moves over the terminal and drops.
    const ev: dnd.MoveEvent = .{
        .cell_x = 2,
        .cell_y = 1,
        .pixel_x = 20,
        .pixel_y = 18,
        .operations = .{ .copy = true },
    };
    try h.registered().dragMove(testing.allocator, &h.output.writer, ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");

    // The kitten accepts as a copy of text/plain.
    _ = try h.command("t=m:o=1:m=0", "text/plain");
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.registered().clientAccepted().?);

    try h.registered().dragDrop(testing.allocator, &h.output.writer, ev, &.{
        .{ .mime = "text/plain", .data = "hello from ghostty\n" },
    });
    try h.expectOutput("\x1b]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");

    // The kitten requests the data and concludes with a copy.
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8gZnJvbSBnaG9zdHR5Cg==\x1b\\" ++
            "\x1b]72;t=r:x=1\x1b\\",
    );
    _ = try h.command("t=r:o=1", null);
    try h.expectOutput("");
    try testing.expect(h.registered().drop.items == null);
}

test "dnd: large data served in chunks" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");

    // 3073 bytes: one full chunk plus one byte.
    const data = [_]u8{'Z'} ** 3073;
    try h.registered().dragDrop(testing.allocator, &h.output.writer, .{
        .cell_x = 0,
        .cell_y = 0,
        .pixel_x = 0,
        .pixel_y = 0,
        .operations = .{ .copy = true },
    }, &.{.{ .mime = "application/octet-stream", .data = &data }});
    h.clear();

    _ = try h.command("t=r:x=1", null);
    const out = h.consume();

    // First chunk is m=1 with 4096 base64 chars, second is m=0, and
    // the final message is the bare end-of-data marker.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]72;t=r:x=1:m=1;"));
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]72;t=r:x=1:m=0;") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\x1b]72;t=r:x=1\x1b\\"));
    h.clear();
}

test "dnd: over-cap registration list never completes" {
    var h: Harness = .init();
    defer h.deinit();

    // Matching kitty, a chunk that would exceed the cap is dropped and
    // the registration is not reported, though the client stays
    // registered (the state exists).
    const big = try testing.allocator.alloc(u8, dnd.max_mime_list_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect((try h.command("t=a", big)) == null);
    try testing.expect(h.state != null);
    {
        var it = h.registered().registeredMimes();
        try testing.expect(it.next() == null);
    }
}
