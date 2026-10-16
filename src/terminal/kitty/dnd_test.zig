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

    /// The drop target; asserts the state exists.
    fn drop(self: *Harness) *dnd.DropTarget {
        return &self.state.?.drop;
    }

    fn writer(self: *Harness) *std.Io.Writer {
        return &self.output.writer;
    }

    /// Feed one client command, as it would arrive from the OSC parser,
    /// returning the events the stream handler would pass to its effect.
    fn command(self: *Harness, metadata: []const u8, payload: ?[]const u8) !dnd.Events {
        return try dnd.handleCommand(&self.state, testing.allocator, &self.output.writer, .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .st,
        });
    }

    /// Feed one client command and check the events it produced.
    fn expectEvents(
        self: *Harness,
        metadata: []const u8,
        payload: ?[]const u8,
        expected: []const dnd.Event,
    ) !void {
        const events = try self.command(metadata, payload);
        try testing.expectEqualSlices(dnd.Event, expected, events.slice());
    }

    fn clear(self: *Harness) void {
        self.output.clearRetainingCapacity();
    }

    fn expectOutput(self: *Harness, expected: []const u8) !void {
        try testing.expectEqualStrings(expected, self.output.written());
        self.clear();
    }

    /// Register for drops and drop the given MIME types, discarding the
    /// output.
    fn setupDrop(self: *Harness, mimes: []const []const u8) !void {
        _ = try self.command("t=a", "");
        _ = try self.drop().dragDrop(testing.allocator, self.writer(), origin, mimes);
        self.clear();
    }
};

const origin: dnd.MoveEvent = .{
    .cell_x = 0,
    .cell_y = 0,
    .pixel_x = 0,
    .pixel_y = 0,
    .operations = .{ .copy = true },
};

test "dnd: query response" {
    var h: Harness = .init();
    defer h.deinit();

    // Works without any registration, matching kitty, and allocates
    // nothing.
    try h.expectEvents("t=q", null, &.{});
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
    try h.expectEvents("t=a", "text/plain text/uri-list", &.{.registration});
    try h.expectOutput("");
    {
        var it = h.drop().registeredMimes().iterator();
        try testing.expectEqualStrings("text/plain", it.next().?);
        try testing.expectEqualStrings("text/uri-list", it.next().?);
        try testing.expect(it.next() == null);
    }

    // Machine ID declaration is accepted and ignored.
    try h.expectEvents("t=a:x=1", "1:deadbeef", &.{});
    try h.expectOutput("");
    try testing.expect(h.state != null);

    // Re-registration replaces the list.
    try h.expectEvents("t=a", "image/png", &.{.registration});
    {
        var it = h.drop().registeredMimes().iterator();
        try testing.expectEqualStrings("image/png", it.next().?);
        try testing.expect(it.next() == null);
    }

    // Registering without a list is the common case.
    try h.expectEvents("t=a", null, &.{.registration});
    {
        var it = h.drop().registeredMimes().iterator();
        try testing.expect(it.next() == null);
    }

    // Unregistration frees it and reports the change.
    try h.expectEvents("t=A", null, &.{.registration});
    try h.expectOutput("");
    try testing.expect(h.state == null);

    // Unregistering again changes nothing.
    try h.expectEvents("t=A", null, &.{});
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
        "\x1b]72;t=R:x=1:m=0;EPERM:drop data can only be requested after a drop\x1b\\",
    );
    try testing.expect(h.state == null);
}

test "dnd: move event carries position, operations, and mime list" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "text/plain");

    try testing.expect(!try h.drop().dragMove(testing.allocator, h.writer(), .{
        .cell_x = 5,
        .cell_y = 3,
        .pixel_x = 100,
        .pixel_y = 60,
        .operations = .{ .copy = true },
    }, &.{ "text/plain", "text/uri-list" }));

    // Note the trailing space after every MIME entry, matching kitty.
    try h.expectOutput(
        "\x1b]72;t=m:x=5:y=3:X=100:Y=60:o=1:m=0;text/plain text/uri-list \x1b\\",
    );
}

test "dnd: move event echoes registration client id" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a:i=7", "");
    _ = try h.drop().dragMove(testing.allocator, h.writer(), .{
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
    const state = h.state.?;
    _ = try h.command("t=a:i=9", "");
    // Same allocation, new client ID.
    try testing.expect(h.state.? == state);
    try testing.expectEqual(@as(u32, 9), state.drop.client_id);
}

test "dnd: mime list sent on every move" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    _ = try h.drop().dragMove(testing.allocator, h.writer(), origin, &.{"text/plain"});
    h.clear();

    // Kitty resends the list even when unchanged; clients depend on it.
    _ = try h.drop().dragMove(testing.allocator, h.writer(), origin, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=0:y=0:X=0:Y=0:o=1:m=0;text/plain \x1b\\");
}

test "dnd: leave event" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    _ = try h.drop().dragMove(testing.allocator, h.writer(), origin, &.{"text/plain"});
    h.clear();

    try h.drop().dragLeave(testing.allocator, h.writer());
    try h.expectOutput("\x1b]72;t=m:x=-1:y=-1\x1b\\");
}

test "dnd: client acceptance recorded" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");
    try testing.expect(h.drop().clientAccepted() == null);

    try h.expectEvents("t=m:o=1", "text/plain", &.{.acceptance});
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.drop().clientAccepted().?);

    // Rejection.
    try h.expectEvents("t=m:o=0", "", &.{.acceptance});
    try testing.expectEqual(dnd.Operation.none, h.drop().clientAccepted().?);
}

test "dnd: chunked client acceptance" {
    var h: Harness = .init();
    defer h.deinit();

    _ = try h.command("t=a", "");

    // Chunked accept: continuation metadata is ignored, the acceptance
    // is pending until the final chunk.
    try h.expectEvents("t=m:o=2:m=1", "text/pl", &.{});
    try testing.expect(h.drop().clientAccepted() == null);
    try h.expectEvents("t=m:m=1", "ain text", &.{});
    try h.expectEvents("t=m:m=0", "/html", &.{.acceptance});
    try testing.expectEqual(dnd.Operation.move, h.drop().clientAccepted().?);

    // The accumulated list was converted to NUL-separated entries.
    try testing.expectEqualSlices(
        u8,
        "text/plain\x00text/html\x00",
        h.drop().accepted_mimes.items,
    );
    var it = h.drop().acceptedMimes().iterator();
    try testing.expectEqualStrings("text/plain", it.next().?);
    try testing.expectEqualStrings("text/html", it.next().?);
    try testing.expect(it.next() == null);
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
    try testing.expect(!try h.drop().dragDrop(
        testing.allocator,
        h.writer(),
        ev,
        &.{ "text/uri-list", "text/plain" },
    ));
    try h.expectOutput(
        "\x1b]72;t=M:x=4:y=2:X=40:Y=20:o=1:m=0;text/uri-list text/plain \x1b\\",
    );

    // Request the second MIME's data: the embedder is asked to read
    // it from the native drop.
    try h.expectEvents("t=r:x=2", null, &.{.data_request});
    try h.expectOutput("");
    const req = h.drop().request().?;
    try testing.expectEqual(@as(u32, 1), req.mime_index);
    try testing.expectEqualStrings("text/plain", req.mime);

    // Its data is a base64 chunk plus the empty end-of-data message.
    try h.drop().respondData(h.writer(), req.id, "hello");
    try testing.expect(try h.drop().respondEnd(h.writer(), req.id) == null);
    try h.expectOutput(
        "\x1b]72;t=r:x=2:m=0;aGVsbG8=\x1b\\" ++ "\x1b]72;t=r:x=2\x1b\\",
    );

    // Out-of-bounds request.
    try h.expectEvents("t=r:x=3", null, &.{});
    try h.expectOutput(
        "\x1b]72;t=R:x=3:m=0;ENOENT:drop data request index out of bounds\x1b\\",
    );

    // Conclude: the performed operation is reported, and further
    // requests fail.
    try h.expectEvents("t=r:o=1", null, &.{.concluded_copy});
    try h.expectOutput("");
    try h.expectEvents("t=r:o=1", null, &.{});
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;EPERM:drop data can only be requested after a drop\x1b\\",
    );
}

test "dnd: empty item served as a single end-of-data message" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});

    // Kitty's oracle (test_empty_data) asserts exactly one message:
    // the empty response is itself the end-of-data signal, and a
    // duplicate would be a second completion to the client.
    try h.expectEvents("t=r:x=1", null, &.{.data_request});
    const req = h.drop().request().?;
    try h.drop().respondData(h.writer(), req.id, "");
    _ = try h.drop().respondEnd(h.writer(), req.id);
    try h.expectOutput("\x1b]72;t=r:x=1\x1b\\");
}

test "dnd: data is sent as the embedder provides it" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;

    // Each piece is sent as soon as it is given, as kitty sends data
    // as the OS delivers it.
    try h.drop().respondData(h.writer(), req.id, "ab");
    try h.expectOutput("\x1b]72;t=r:x=1:m=0;YWI=\x1b\\");
    try h.drop().respondData(h.writer(), req.id, "c");
    try h.expectOutput("\x1b]72;t=r:x=1:m=0;Yw==\x1b\\");
    _ = try h.drop().respondEnd(h.writer(), req.id);
    try h.expectOutput("\x1b]72;t=r:x=1\x1b\\");
}

test "dnd: read errors carry the request keys" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;
    try testing.expect(try h.drop().respondError(h.writer(), req.id, .EIO) == null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;EIO:drop data request failed to read data\x1b\\",
    );
}

test "dnd: requests are served in order" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{ "text/plain", "text/html" });

    // Only the first request is handed to the embedder; the second
    // waits for it.
    try h.expectEvents("t=r:x=1", null, &.{.data_request});
    try h.expectEvents("t=r:x=2", null, &.{});
    const first = h.drop().request().?;
    try testing.expectEqualStrings("text/plain", first.mime);

    try h.drop().respondData(h.writer(), first.id, "plain");
    const second = (try h.drop().respondEnd(h.writer(), first.id)).?;
    try testing.expectEqualStrings("text/html", second.mime);
    try testing.expect(second.id != first.id);
    try h.drop().respondData(h.writer(), second.id, "html");
    try testing.expect(try h.drop().respondEnd(h.writer(), second.id) == null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;cGxhaW4=\x1b\\" ++ "\x1b]72;t=r:x=1\x1b\\" ++
            "\x1b]72;t=r:x=2:m=0;aHRtbA==\x1b\\" ++ "\x1b]72;t=r:x=2\x1b\\",
    );
}

test "dnd: errors are answered in queue order" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});

    // Requests that fail without data are answered immediately when
    // nothing is ahead of them (kitty's
    // test_multiple_sync_errors_processed_immediately) ...
    _ = try h.command("t=r:x=10", null);
    _ = try h.command("t=r:x=20", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=10:m=0;ENOENT:drop data request index out of bounds\x1b\\" ++
            "\x1b]72;t=R:x=20:m=0;ENOENT:drop data request index out of bounds\x1b\\",
    );

    // ... and after the request ahead of them otherwise.
    try h.expectEvents("t=r:x=1", null, &.{.data_request});
    try h.expectEvents("t=r:x=30", null, &.{});
    try h.expectOutput("");
    const req = h.drop().request().?;
    try testing.expect(try h.drop().respondEnd(h.writer(), req.id) == null);
    try h.expectOutput(
        "\x1b]72;t=r:x=1\x1b\\" ++
            "\x1b]72;t=R:x=30:m=0;ENOENT:drop data request index out of bounds\x1b\\",
    );
}

test "dnd: queue overflow returns EMFILE and ends the drop" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});
    _ = try h.command("t=m:o=1", "text/plain");

    // The first request is being served and 127 more wait: the queue
    // is full but nothing is refused yet.
    for (0..dnd.max_requests) |_| _ = try h.command("t=r:x=1", null);
    try h.expectOutput("");
    const req = h.drop().request().?;

    // One more is refused and ends the drop with the accepted
    // operation.
    try h.expectEvents("t=r:x=1", null, &.{.concluded_copy});
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;EMFILE:too many drop data requests\x1b\\",
    );
    try testing.expect(h.drop().request() == null);
    try testing.expectError(error.Stale, h.drop().respondEnd(h.writer(), req.id));
}

test "dnd: replies to abandoned requests are stale" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;

    // The client concludes while the embedder is reading.
    try h.expectEvents("t=r:o=0", null, &.{.concluded_none});
    try testing.expectError(error.Stale, h.drop().respondData(h.writer(), req.id, "x"));
    try testing.expectError(error.Stale, h.drop().respondEnd(h.writer(), req.id));
    try testing.expectError(error.Stale, h.drop().respondError(h.writer(), req.id, .EIO));
    try h.expectOutput("");
}

test "dnd: leave without hover sends nothing" {
    var h: Harness = .init();
    defer h.deinit();

    // Client registered but no move was ever forwarded (e.g. it
    // registered mid-drag): kitty only notifies hovered windows.
    _ = try h.command("t=a", "");
    try h.drop().dragLeave(testing.allocator, h.writer());
    try h.expectOutput("");
}

test "dnd: data request with no drop" {
    var h: Harness = .init();
    defer h.deinit();

    // Moves are informational only; consent to transfer data is the
    // drop (kitty's test_data_request_before_drop_denied).
    _ = try h.command("t=a", "");
    _ = try h.drop().dragMove(testing.allocator, h.writer(), origin, &.{"text/plain"});
    h.clear();
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;EPERM:drop data can only be requested after a drop\x1b\\",
    );
}

test "dnd: leave after drop is ignored" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});

    // Some toolkits emit a leave for the drop itself; the drop must
    // survive so the client can still fetch its data.
    try h.drop().dragLeave(testing.allocator, h.writer());
    try h.expectOutput("");
    try h.expectEvents("t=r:x=1", null, &.{.data_request});
}

test "dnd: new drag discards an unconcluded drop" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;

    // A new drag entering resets the per-drag state, discarding the
    // unconcluded previous drop, which the embedder must finish.
    try testing.expect(try h.drop().dragMove(testing.allocator, h.writer(), origin, &.{"text/plain"}));
    h.clear();
    try testing.expectError(error.Stale, h.drop().respondEnd(h.writer(), req.id));
    _ = try h.command("t=r:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:m=0;EPERM:drop data can only be requested after a drop\x1b\\",
    );
}

test "dnd: remote transfer requests refused" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{ "text/plain", "text/uri-list" });

    // URI file content request.
    _ = try h.command("t=r:x=2:y=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=2:y=1:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );

    // Directory handle request.
    _ = try h.command("t=r:Y=2:x=1", null);
    try h.expectOutput(
        "\x1b]72;t=R:x=1:Y=2:m=0;EINVAL:remote drop data is not supported\x1b\\",
    );
}

test "dnd: unregister ends a held drop" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"text/plain"});

    // The unconcluded drop ends with no operation, then the client is
    // gone. The testing allocator would report anything leaked.
    try h.expectEvents("t=A", null, &.{ .concluded_none, .registration });
    try testing.expect(h.state == null);
}

test "dnd: chunked registration reuses first chunk metadata" {
    var h: Harness = .init();
    defer h.deinit();

    // Registration split over two chunks: the first chunk allocates
    // the state and seeds chunk reassembly, so the continuation (which
    // carries a different type) is still treated as the registration.
    try h.expectEvents("t=a:i=4:m=1", "text/pla", &.{});
    try testing.expect(h.state != null);
    try h.expectEvents("t=q:m=0", "in", &.{.registration});
    try h.expectOutput("");
    try testing.expectEqual(@as(u32, 4), h.drop().client_id);
    {
        var it = h.drop().registeredMimes().iterator();
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

    _ = try dnd.handleCommand(&h.state, testing.allocator, h.writer(), .{
        .metadata = "t=q",
        .payload = null,
        .terminator = .bel,
    });
    try h.expectOutput("\x1b]72;t=q\x07");

    // Including replies served after the command was processed.
    try h.setupDrop(&.{"text/plain"});
    _ = try dnd.handleCommand(&h.state, testing.allocator, h.writer(), .{
        .metadata = "t=r:x=1",
        .payload = null,
        .terminator = .bel,
    });
    const req = h.drop().request().?;
    _ = try h.drop().respondEnd(h.writer(), req.id);
    try h.expectOutput("\x1b]72;t=r:x=1\x07");
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
    _ = try h.drop().dragMove(testing.allocator, h.writer(), ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=m:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");

    // The kitten accepts as a copy of text/plain.
    _ = try h.command("t=m:o=1:m=0", "text/plain");
    try h.expectOutput("");
    try testing.expectEqual(dnd.Operation.copy, h.drop().clientAccepted().?);

    _ = try h.drop().dragDrop(testing.allocator, h.writer(), ev, &.{"text/plain"});
    try h.expectOutput("\x1b]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\");

    // The kitten requests the data and concludes with a copy.
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;
    try h.drop().respondData(h.writer(), req.id, "hello from ghostty\n");
    _ = try h.drop().respondEnd(h.writer(), req.id);
    try h.expectOutput(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8gZnJvbSBnaG9zdHR5Cg==\x1b\\" ++
            "\x1b]72;t=r:x=1\x1b\\",
    );
    try h.expectEvents("t=r:o=1", null, &.{.concluded_copy});
    try h.expectOutput("");
    try testing.expect(!h.drop().dropped);
}

test "dnd: large data served in chunks" {
    var h: Harness = .init();
    defer h.deinit();

    try h.setupDrop(&.{"application/octet-stream"});
    _ = try h.command("t=r:x=1", null);
    const req = h.drop().request().?;

    // 3073 bytes: one full chunk plus one byte.
    const data = [_]u8{'Z'} ** 3073;
    try h.drop().respondData(h.writer(), req.id, &data);
    _ = try h.drop().respondEnd(h.writer(), req.id);
    const out = h.output.written();

    // First chunk is m=1 with 4096 base64 chars, second is m=0, and
    // the final message is the bare end-of-data marker.
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]72;t=r:x=1:m=1;"));
    try testing.expect(std.mem.indexOf(u8, out, "\x1b]72;t=r:x=1:m=0;") != null);
    try testing.expect(std.mem.endsWith(u8, out, "\x1b]72;t=r:x=1\x1b\\"));
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
    try h.expectEvents("t=a", big, &.{});
    try testing.expect(h.state != null);
    {
        var it = h.drop().registeredMimes().iterator();
        try testing.expect(it.next() == null);
    }
}

test "dnd: drag out refused" {
    var h: Harness = .init();
    defer h.deinit();

    // Enabling and disabling offers is accepted silently and allocates
    // nothing.
    try h.expectEvents("t=o:x=1", null, &.{});
    try h.expectEvents("t=o:x=2", null, &.{});
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

test "dnd embed: drop input and follow-up events" {
    var h: Harness = .init();
    defer h.deinit();

    const motion: @import("../dnd.zig").DropInput.Motion = .{
        .position = .{ .cell_x = 1, .cell_y = 2, .pixel_x = 10, .pixel_y = 20 },
        .operations = .{ .copy = true },
        .mimes = &.{"text/plain"},
    };

    // Nothing to report to before registration.
    _ = try h.command("t=q", null);
    h.clear();
    try h.expectEvents("t=a", null, &.{.registration});
    try testing.expect(dnd.dropEvent(h.state, .registration).?.registration.accepting);

    try testing.expect(try dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .drop = motion }) == null);
    try h.expectOutput("\x1b]72;t=M:x=1:y=2:X=10:Y=20:o=1:m=0;text/plain \x1b\\");

    // Two requests: answering the first hands out the second.
    try h.expectEvents("t=r:x=1", null, &.{.data_request});
    try h.expectEvents("t=r:x=1", null, &.{});
    const first = dnd.dropEvent(h.state, .data_request).?.data_request;
    _ = try dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .data = .{ .id = first.id, .bytes = "hi" } });
    const next = (try dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .end = first.id })).?;
    try testing.expect(next.data_request.id != first.id);
    try testing.expectError(error.Rejected, dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .end = first.id }));
    try testing.expect(try dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .fail = .{
        .id = next.data_request.id,
        .reason = .not_found,
    } }) == null);
    try h.expectOutput("\x1b]72;t=r:x=1:m=0;aGk=\x1b\\" ++
        "\x1b]72;t=r:x=1\x1b\\" ++
        "\x1b]72;t=R:x=1:m=0;ENOENT:drop data request failed to read data\x1b\\");

    // A new drag replacing the unconcluded drop concludes it.
    const ev = (try dnd.dropInput(h.state.?, testing.allocator, h.writer(), .{ .move = motion })).?;
    try testing.expectEqual(@import("../dnd.zig").Operation.none, ev.concluded);
}
