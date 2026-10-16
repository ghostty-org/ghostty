//! Unix domain socket server for the agent IPC surface, plus a matching client.
//!
//! Shape (see `protocol.md` section 2 and 7):
//!
//!   * one listening Unix socket, one accept thread;
//!   * one thread per connection, so a slow or idle agent never blocks another;
//!   * line-delimited JSON frames, one response per request, correlated by `id`;
//!   * per-connection state (event subscription, read buffer) lives in `Conn`;
//!   * subscribed connections get asynchronous event frames from a per-connection
//!     pusher thread.
//!
//! Known limits, stated rather than implied:
//!
//!   * `stop`/`deinit` unblock `accept`, but in-flight connections end when the
//!     client disconnects; they are not force-closed, because a half-written
//!     frame is worse than a slow shutdown.
//!   * The event pusher polls (`Config.event_poll_ms`) instead of blocking on a
//!     condition variable: `std.Io.net` reads take no timeout, and a per
//!     connection poll at 25 ms costs nothing measurable while making a stuck
//!     pusher impossible to miss.
//!   * Each connection allocates `max_frame_bytes` for its read buffer, so
//!     memory is bounded per connection and by nothing else.
//!
//!     zig test src/apprt/ipc/server.zig

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const pane = @import("pane.zig");
const events = @import("events.zig");
const authpkg = @import("auth.zig");
const handlerpkg = @import("handler.zig");

const log = std.log.scoped(.ipc);

/// Server configuration.
pub const Config = struct {
    /// Filesystem path of the socket.
    socket_path: []const u8,
    /// Remove an existing socket file before binding. Stale sockets left by a
    /// crashed instance are the common case, so this defaults to on.
    replace_existing: bool = true,
    /// Kernel accept backlog.
    kernel_backlog: u31 = std.Io.net.default_kernel_backlog,
    /// Largest accepted request frame. Larger frames get `bad_request` and the
    /// connection is closed.
    max_frame_bytes: usize = protocol.max_frame_bytes,
    /// Run the per-connection event pusher. Disabled by deterministic tests,
    /// which drive `pushPendingEvents` by hand.
    event_pusher: bool = true,
    /// Pusher poll interval.
    event_poll_ms: u64 = 25,
    /// Events written per push.
    push_batch: usize = 32,
};

/// Everything the server needs from the rest of the IPC layer.
pub const Deps = struct {
    manager: *pane.Manager,
    broker: *events.Broker,
    authenticator: *const authpkg.Auth,
    /// Advertised by `ping`; null when unknown.
    server_pid: ?u32 = null,
};

/// One client connection.
pub const Conn = struct {
    server: *Server,
    stream: std.Io.net.Stream,
    /// Persistent reader state. Must outlive every frame read so bytes read
    /// ahead of a frame boundary are not dropped.
    reader: std.Io.net.Stream.Reader,
    /// Backing storage for `reader`.
    read_buf: []u8,
    handler: handlerpkg.Handler,
    /// Serializes frames from the response path and the event pusher so two
    /// writers can never interleave inside one frame.
    write_mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = .init(false),
    pusher: ?std.Thread = null,
    /// Events written to this connection (observability + tests).
    events_sent: usize = 0,

    fn writeLine(self: *Conn, bytes: []const u8) !void {
        const io = self.server.io;
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);

        var buf: [1024]u8 = undefined;
        var w = self.stream.writer(io, &buf);
        try w.interface.writeAll(bytes);
        try w.interface.writeByte('\n');
        try w.interface.flush();
    }

    fn respond(self: *Conn, resp: protocol.Response) !void {
        var out: std.Io.Writer.Allocating = .init(self.server.gpa);
        defer out.deinit();
        try resp.write(&out.writer);
        try self.writeLine(out.written());
    }

    fn respondFailure(
        self: *Conn,
        id: ?u64,
        code: protocol.ErrorCode,
        message: []const u8,
    ) !void {
        try self.respond(protocol.Response.failure(id, code, message));
    }

    fn startPusher(self: *Conn) void {
        self.pusher = std.Thread.spawn(.{}, pusherMain, .{self}) catch |err| {
            log.warn("event pusher thread failed to start, events will be " ++
                "delivered with the next request instead: {}", .{err});
            return;
        };
    }

    fn pusherMain(self: *Conn) void {
        const server = self.server;
        const interval = std.Io.Duration.fromMilliseconds(
            @intCast(server.config.event_poll_ms),
        );

        while (self.running.load(.acquire) and server.running.load(.acquire)) {
            _ = server.pushPendingEvents(self);
            std.Io.sleep(server.io, interval, .awake) catch return;
        }
    }
};

/// The server.
pub const Server = struct {
    gpa: Allocator,
    io: std.Io,
    config: Config,
    deps: Deps,
    listener: std.Io.net.Server,
    running: std.atomic.Value(bool) = .init(false),
    /// Whether `listener` still owns a live socket.
    listener_open: bool = true,
    accept_thread: ?std.Thread = null,
    /// Connections accepted (observability + tests).
    connections_accepted: std.atomic.Value(usize) = .init(0),
    /// Connections currently being served.
    live_connections: std.atomic.Value(usize) = .init(0),
    /// Frames parsed and answered (observability + tests).
    frames_handled: std.atomic.Value(usize) = .init(0),

    /// Bind the socket and prepare to accept. Does not accept yet.
    pub fn bind(gpa: Allocator, io: std.Io, config: Config, deps: Deps) !Server {
        if (config.replace_existing) {
            std.Io.Dir.cwd().deleteFile(io, config.socket_path) catch {};
        }

        const address = try std.Io.net.UnixAddress.init(config.socket_path);
        const listener = try address.listen(io, .{ .kernel_backlog = config.kernel_backlog });

        return .{
            .gpa = gpa,
            .io = io,
            .config = config,
            .deps = deps,
            .listener = listener,
        };
    }

    /// Start accepting connections on a background thread.
    pub fn start(self: *Server) !void {
        self.running.store(true, .release);
        self.accept_thread = try std.Thread.spawn(.{}, acceptMain, .{self});
    }

    /// Stop accepting. Blocks until the accept thread has left `accept`.
    pub fn stop(self: *Server) void {
        if (!self.running.swap(false, .acq_rel)) return;

        // Wake a blocked `accept` by connecting to ourselves: the accept loop
        // sees `running == false`, drops the connection, and returns. The
        // listener stays open until `deinit`, so no thread ever accepts on a
        // handle that was already released.
        const address = std.Io.net.UnixAddress.init(self.config.socket_path) catch return;
        if (address.connect(self.io)) |stream| {
            stream.close(self.io);
        } else |_| {}
    }

    /// Release the socket and join the accept thread.
    pub fn deinit(self: *Server) void {
        self.stop();
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        // Connection threads own a slice of the manager/broker, so they must be
        // gone before those are torn down. Clients that already disconnected
        // drain immediately; a client that is still connected only ends the
        // wait after the timeout, and that case is logged rather than hidden.
        if (!self.drainConnections(5_000)) {
            log.warn(
                "shutting down with {d} connection(s) still live; their frames " ++
                    "will not be answered",
                .{self.live_connections.load(.acquire)},
            );
        }
        if (self.listener_open) {
            self.listener.deinit(self.io);
            self.listener_open = false;
        }
        std.Io.Dir.cwd().deleteFile(self.io, self.config.socket_path) catch {};
    }

    /// Wait until no connection is being served. Returns false on timeout.
    pub fn drainConnections(self: *Server, timeout_ms: u64) bool {
        const step_ms: u64 = 5;
        var waited: u64 = 0;
        while (self.live_connections.load(.acquire) > 0) {
            if (waited >= timeout_ms) return false;
            std.Io.sleep(
                self.io,
                std.Io.Duration.fromMilliseconds(@intCast(step_ms)),
                .awake,
            ) catch return false;
            waited += step_ms;
        }
        return true;
    }

    fn acceptMain(self: *Server) void {
        while (self.running.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.ConnectionAborted => continue,
                else => {
                    if (!self.running.load(.acquire)) return;
                    log.warn("accept failed: {}", .{err});
                    continue;
                },
            };

            if (!self.running.load(.acquire)) {
                stream.close(self.io);
                return;
            }

            _ = self.connections_accepted.fetchAdd(1, .monotonic);
            _ = self.live_connections.fetchAdd(1, .monotonic);

            // One thread per connection: an agent that is slow, idle, or stuck
            // must not hold up another agent.
            const thread = std.Thread.spawn(.{}, connMain, .{ self, stream }) catch |err| {
                log.warn("connection thread failed to start: {}", .{err});
                _ = self.live_connections.fetchSub(1, .monotonic);
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }

    fn connMain(self: *Server, stream: std.Io.net.Stream) void {
        defer _ = self.live_connections.fetchSub(1, .monotonic);
        self.serveConnection(stream);
    }

    /// Serve one connection to completion. Public so tests can drive a
    /// connection without threads.
    pub fn serveConnection(self: *Server, stream: std.Io.net.Stream) void {
        const read_buf = self.gpa.alloc(u8, self.config.max_frame_bytes + 2) catch {
            stream.close(self.io);
            return;
        };

        var conn: Conn = .{
            .server = self,
            .stream = stream,
            .read_buf = read_buf,
            .reader = undefined,
            .handler = handlerpkg.Handler.init(
                self.gpa,
                self.deps.manager,
                self.deps.broker,
                self.deps.authenticator,
            ),
        };
        conn.handler.server_pid = self.deps.server_pid;
        conn.reader = std.Io.net.Stream.Reader.init(stream, self.io, read_buf);
        conn.running.store(true, .release);

        defer {
            conn.running.store(false, .release);
            if (conn.pusher) |thread| thread.join();
            conn.handler.deinit(self.io);
            self.gpa.free(read_buf);
            stream.close(self.io);
        }

        if (self.config.event_pusher) conn.startPusher();
        self.serveFrames(&conn);
    }

    fn serveFrames(self: *Server, conn: *Conn) void {
        while (conn.running.load(.acquire) and self.running.load(.acquire)) {
            // `takeDelimiter` (not `takeDelimiterExclusive`) is the framing
            // primitive: it consumes the delimiter, and returns null at a
            // clean end of stream. Exclusive leaves the delimiter in the
            // buffer, which turns the next read into a zero-length frame.
            const frame = conn.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // Protocol rule: an oversized frame is rejected and the
                    // connection is closed, because the reader can no longer
                    // resynchronize on a frame boundary.
                    conn.respondFailure(
                        null,
                        .bad_request,
                        "frame exceeds the maximum accepted size",
                    ) catch {};
                    return;
                },
                error.ReadFailed => return,
            } orelse return;

            // An empty line is not "skip": it is an empty frame, which is
            // malformed JSON and gets a bad_request like any other invalid
            // frame.
            self.handleFrame(conn, frame);
        }
    }

    /// Parse and answer one frame, then deliver any events that are pending.
    pub fn handleFrame(self: *Server, conn: *Conn, frame: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        var parsed = protocol.parse(self.gpa, frame) catch {
            conn.respondFailure(null, .internal, "out of memory") catch {};
            return;
        };
        defer parsed.deinit();

        if (parsed.failure()) |failure| {
            // No correlation id is available: the frame did not parse far
            // enough to carry one.
            conn.respondFailure(null, failure.code, failure.message) catch {};
            return;
        }

        // `request` borrows the parse arena, which outlives this call.
        const request = parsed.request().?.*;
        const response = conn.handler.dispatch(arena.allocator(), self.io, request);
        conn.respond(response) catch return;
        _ = self.frames_handled.fetchAdd(1, .monotonic);

        // Events published by this command (pane_created, pane_closed) are
        // delivered with the response rather than after a poll interval.
        _ = self.pushPendingEvents(conn);
    }

    /// Write any pending events for a connection. Returns the number written.
    pub fn pushPendingEvents(self: *Server, conn: *Conn) usize {
        const limit = @min(self.config.push_batch, 64);
        var batch: [64]events.Event = undefined;
        const count = conn.handler.pollEvents(self.io, batch[0..limit]);
        if (count == 0) return 0;

        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        var written: usize = 0;
        for (batch[0..count]) |event| {
            out.clearRetainingCapacity();
            event.writeJson(&out.writer) catch return written;
            conn.writeLine(out.written()) catch return written;
            written += 1;
            conn.events_sent += 1;
        }
        return written;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Client
// ─────────────────────────────────────────────────────────────────────────

/// A minimal blocking client: enough for agents, tooling, and tests.
pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    read_buf: []u8,
    write_buf: [1024]u8 = undefined,

    /// Default read buffer, sized for the default frame cap.
    pub const default_read_buffer: usize = protocol.max_frame_bytes + 2;

    pub fn connect(gpa: Allocator, io: std.Io, socket_path: []const u8) !Client {
        const address = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try address.connect(io);
        errdefer stream.close(io);

        const read_buf = try gpa.alloc(u8, default_read_buffer);
        return .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader = std.Io.net.Stream.Reader.init(stream, io, read_buf),
            .read_buf = read_buf,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.gpa.free(self.read_buf);
        self.* = undefined;
    }

    /// Frame one request and send it.
    pub fn send(self: *Client, request: protocol.Request) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try request.write(&out.writer);
        try self.sendRaw(out.written());
    }

    /// Send raw bytes as one frame. Used by tests that need malformed input.
    pub fn sendRaw(self: *Client, bytes: []const u8) !void {
        var w = self.stream.writer(self.io, &self.write_buf);
        try w.interface.writeAll(bytes);
        try w.interface.writeByte('\n');
        try w.interface.flush();
    }

    /// Read one frame, consuming its delimiter. Returns null at a clean end of
    /// stream, which is how a server closing the connection appears. The slice
    /// borrows the client's read buffer and stays valid until the next read.
    pub fn readFrame(self: *Client) !?[]const u8 {
        return self.reader.interface.takeDelimiter('\n');
    }

    /// Read one frame and parse it as JSON.
    pub fn readMessage(self: *Client, alloc: Allocator) !std.json.Parsed(std.json.Value) {
        const frame = (try self.readFrame()) orelse return error.EndOfStream;
        return std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    }

    /// Read frames until a response arrives, skipping events. Caller deinits.
    pub fn readResponse(self: *Client, alloc: Allocator) !std.json.Parsed(std.json.Value) {
        while (true) {
            const message = try self.readMessage(alloc);
            if (message.value.object.get("event") != null) {
                message.deinit();
                continue;
            }
            return message;
        }
    }

    /// Read frames until an event arrives, skipping responses. Caller deinits.
    pub fn readEvent(self: *Client, alloc: Allocator) !std.json.Parsed(std.json.Value) {
        while (true) {
            const message = try self.readMessage(alloc);
            if (message.value.object.get("event") != null) return message;
            message.deinit();
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const FakeHost = @import("fake_host.zig").FakeHost;

const test_token = "integration-token";

/// A bound, started server plus the pieces it depends on. Torn down in reverse
/// order: clients first (the tests own those), then the accept thread, then the
/// connection threads, then the state they borrow.
const Harness = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    io: std.Io,
    path: []u8,
    fake: FakeHost,
    broker: events.Broker,
    authenticator: authpkg.Auth,
    manager: pane.Manager,
    server: Server,

    const Options = struct {
        /// Run the per-connection event pusher. Off by default so tests that do
        /// not exercise events stay deterministic in frame order.
        event_pusher: bool = false,
        event_poll_ms: u64 = 5,
        max_frame_bytes: usize = protocol.max_frame_bytes,
    };

    fn init(gpa: Allocator, options: Options) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        // A real multi-threaded Io: the accept thread and per-connection
        // threads all use it.
        self.threaded = .init(gpa, .{});
        self.io = self.threaded.io();

        var suffix: [8]u8 = undefined;
        self.io.random(&suffix);
        self.path = try std.fmt.allocPrint(
            gpa,
            "/tmp/khostty-ipc-test-{x}.sock",
            .{suffix},
        );
        errdefer gpa.free(self.path);

        self.fake = FakeHost.init(gpa);
        self.broker = events.Broker.init(gpa);
        self.authenticator = try authpkg.Auth.init(gpa, test_token);
        self.manager = pane.Manager.init(gpa, self.fake.host());
        self.manager.setEventBroker(&self.broker);

        self.server = try Server.bind(gpa, self.io, .{
            .socket_path = self.path,
            .event_pusher = options.event_pusher,
            .event_poll_ms = options.event_poll_ms,
            .max_frame_bytes = options.max_frame_bytes,
        }, .{
            .manager = &self.manager,
            .broker = &self.broker,
            .authenticator = &self.authenticator,
            .server_pid = 4242,
        });
        try self.server.start();
        return self;
    }

    fn deinit(self: *Harness) void {
        self.server.deinit();
        self.manager.deinit(self.io);
        self.broker.deinit(self.io);
        self.authenticator.deinit();
        self.fake.deinit();
        self.gpa.free(self.path);
        self.threaded.deinit();
        self.gpa.destroy(self);
    }

    fn connect(self: *Harness) !Client {
        return Client.connect(self.gpa, self.io, self.path);
    }

    /// Build a token-carrying request frame by plain concatenation, so JSON
    /// braces in `extra` are never mistaken for format placeholders.
    fn authed(self: *Harness, extra: []const u8) ![]u8 {
        _ = self;
        return std.mem.concat(testing.allocator, u8, &.{
            "{\"id\":1,\"auth\":\"", test_token, "\"", extra, "}",
        });
    }

    /// One request/response pair over a fresh connection.
    fn roundTrip(self: *Harness, frame: []const u8) !std.json.Parsed(std.json.Value) {
        var client = try self.connect();
        defer client.deinit();
        try client.sendRaw(frame);
        return client.readResponse(self.gpa);
    }

    /// Build a token-carrying frame (caller frees).
    fn authedFrame(self: *Harness, extra: []const u8) ![]u8 {
        return self.authed(extra);
    }

    /// Send a token-carrying frame on an existing connection and read the
    /// response.
    fn request(
        self: *Harness,
        client: *Client,
        extra: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const request_text = try self.authed(extra);
        defer testing.allocator.free(request_text);
        try client.sendRaw(request_text);
        return client.readResponse(testing.allocator);
    }

    /// Fail the test (with the server's message) unless the response is ok.
    /// Takes ownership of `response` in every case.
    fn expectOk(
        self: *Harness,
        response: std.json.Parsed(std.json.Value),
    ) !std.json.Parsed(std.json.Value) {
        _ = self;
        if (response.value.object.get("ok").?.bool) return response;
        std.debug.print(
            "unexpected error response: {s}: {s}\n",
            .{
                response.value.object.get("error").?.object.get("code").?.string,
                response.value.object.get("error").?.object.get("message").?.string,
            },
        );
        response.deinit();
        return error.TestUnexpectedResult;
    }

    /// The `data` payload of a response.
    fn dataOf(payload: std.json.Parsed(std.json.Value)) std.json.Value {
        return payload.value.object.get("data").?;
    }

    /// `pane.create`; caller frees the returned pane id.
    fn createPane(self: *Harness, client: *Client, title: []const u8) ![]u8 {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"cmd\":\"pane.create\",\"opts\":{{\"title\":\"{s}\"}}",
            .{title},
        );
        defer testing.allocator.free(extra);

        var payload = try self.expectOk(try self.request(client, extra));
        defer payload.deinit();
        return testing.allocator.dupe(
            u8,
            payload.value.object.get("data").?.object.get("pane_id").?.string,
        );
    }

    /// `pane.write` with a raw VT payload (already JSON-escaped).
    fn write(self: *Harness, client: *Client, pane_id: []const u8, data: []const u8) !void {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"cmd\":\"pane.write\",\"pane_id\":\"{s}\",\"data\":\"{s}\"",
            .{ pane_id, data },
        );
        defer testing.allocator.free(extra);
        var payload = try self.expectOk(try self.request(client, extra));
        payload.deinit();
    }

    fn state(
        self: *Harness,
        client: *Client,
        pane_id: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"cmd\":\"pane.state\",\"pane_id\":\"{s}\"",
            .{pane_id},
        );
        defer testing.allocator.free(extra);
        return self.expectOk(try self.request(client, extra));
    }

    fn search(
        self: *Harness,
        client: *Client,
        pane_id: []const u8,
        query: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"cmd\":\"pane.search\",\"pane_id\":\"{s}\",\"query\":\"{s}\"",
            .{ pane_id, query },
        );
        defer testing.allocator.free(extra);
        return self.expectOk(try self.request(client, extra));
    }

    fn listPanes(self: *Harness, client: *Client) !std.json.Parsed(std.json.Value) {
        return self.expectOk(try self.request(client, ",\"cmd\":\"pane.list\""));
    }

    fn closePane(self: *Harness, client: *Client, pane_id: []const u8) !void {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"cmd\":\"pane.close\",\"pane_id\":\"{s}\"",
            .{pane_id},
        );
        defer testing.allocator.free(extra);
        var payload = try self.expectOk(try self.request(client, extra));
        payload.deinit();
    }
};

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "bind: replaces a stale socket file and removes it on deinit" {
    const gpa = testing.allocator;
    // No accept thread here, so the single-threaded Io is enough.
    const io = testIo();

    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const path = try std.fmt.allocPrint(gpa, "/tmp/khostty-ipc-bind-{x}.sock", .{suffix});
    defer gpa.free(path);

    // A crashed instance leaves a plain file where the socket used to be.
    {
        const stale = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer stale.close(io);
    }
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});

    var fake = FakeHost.init(gpa);
    defer fake.deinit();
    var broker = events.Broker.init(gpa);
    defer broker.deinit(io);
    var authenticator = try authpkg.Auth.init(gpa, test_token);
    defer authenticator.deinit();
    var manager = pane.Manager.init(gpa, fake.host());
    defer manager.deinit(io);

    var server = try Server.bind(gpa, io, .{ .socket_path = path }, .{
        .manager = &manager,
        .broker = &broker,
        .authenticator = &authenticator,
    });

    // Bound: the stale file was replaced by a live socket.
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});
    // And a client can connect to it, which a leftover regular file could not.
    const stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
    stream.close(io);

    server.deinit();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path, .{}));
}

test "socket: ping round trip" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    try client.send(.{ .id = 1, .cmd = .ping });
    const message = try client.readResponse(testing.allocator);
    defer message.deinit();

    try testing.expectEqual(true, message.value.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 1), message.value.object.get("id").?.integer);
    try testing.expectEqual(@as(i64, 1), message.value.object.get("v").?.integer);
    const data = message.value.object.get("data").?.object;
    try testing.expectEqualStrings("khostty", data.get("server").?.string);
    try testing.expectEqual(@as(i64, 4242), data.get("pid").?.integer);
}

test "socket: a malformed frame is rejected and the connection survives" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    try client.sendRaw("{\"cmd\":");
    const failure = try client.readResponse(testing.allocator);
    defer failure.deinit();
    try testing.expectEqual(false, failure.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        "bad_request",
        failure.value.object.get("error").?.object.get("code").?.string,
    );

    // The connection is still usable afterwards.
    try client.send(.{ .id = 9, .cmd = .ping });
    const ok = try client.readResponse(testing.allocator);
    defer ok.deinit();
    try testing.expectEqual(true, ok.value.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 9), ok.value.object.get("id").?.integer);
}

test "socket: an oversized frame is rejected and the connection closes" {
    var h = try Harness.init(testing.allocator, .{ .max_frame_bytes = 256 });
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    var big: [1024]u8 = @splat('x');
    big[0] = '{';
    big[1] = '"';
    try client.sendRaw(&big);

    const failure = try client.readResponse(testing.allocator);
    defer failure.deinit();
    try testing.expectEqual(false, failure.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        "bad_request",
        failure.value.object.get("error").?.object.get("code").?.string,
    );

    // The server closed its side. macOS surfaces a clean FIN as a null
    // (EOF) frame. Linux sends a TCP RST instead when the server process
    // closes a socket with pending unread data in the receive buffer. The
    // RST can surface here as either `error.ConnectionResetByPeer` (when
    // the underlying net error reaches the API directly) or as a wrapped
    // `error.ReadFailed` (when std.Io.net.readVec flattens the underlying
    // error into a generic ReadFailed at std/Io/net.zig:1307). In both
    // cases the *wrapped cause* is `error.ConnectionResetByPeer`, exposed
    // by `std.Io.net.Stream.Reader.err` (zig 0.16).
    //
    // `Client.readFrame` is `!?[]const u8` and delegates to
    // `std.Io.Reader.takeDelimiter`, whose inferred error set is exactly
    // `error{ReadFailed, StreamTooLong}` (see std/Io/Reader.zig:895).
    // `EndOfStream` is converted to null inside `takeDelimiter`, so it
    // never reaches the test. We exhaustively switch on the two real
    // members and never `else`-swallow.
    //
    // We accept:
    //   1. a null (EOF) frame -- macOS clean FIN,
    //   2. `error.ConnectionResetByPeer` -- Linux direct RST,
    //   3. `error.ReadFailed` only when `client.reader.err` is
    //      `error.ConnectionResetByPeer` -- Linux wrapped RST.
    //
    // `error.StreamTooLong` is propagated explicitly. After
    // `readResponse` consumed the bad_request response, the client reader
    // is empty, so this branch should not fire; if it ever does, the
    // test fails with the actual error rather than a silent pass.
    //
    // Anything else (UnexpectedEof, BrokenPipe, a non-null frame, a
    // ReadFailed whose wrapped cause is anything other than reset) fails
    // the test, so normal-close and valid-frame exchange regressions stay
    // covered.
    const frame = client.readFrame();
    if (frame) |maybe_frame| {
        try testing.expectEqual(@as(?[]const u8, null), maybe_frame);
    } else |err| switch (err) {
        error.ReadFailed => {
            // zig 0.16's std.Io.net.readVec flattens the underlying net
            // error into generic ReadFailed; only accept when the wrapped
            // cause exposed at client.reader.err is the documented reset.
            const underlying = client.reader.err orelse return error.ReadFailed;
            try testing.expectEqual(error.ConnectionResetByPeer, underlying);
        },
        error.StreamTooLong => {
            // Not reachable in this scenario: the client buffer is empty
            // after readResponse consumed the bad_request response, so
            // takeDelimiter cannot find a full buffer without a delimiter.
            // Propagate explicitly to keep the switch exhaustive (the
            // IPC test root enforces this) and to surface a real bug
            // rather than a swallowed result.
            return error.StreamTooLong;
        },
    }
}

test "socket: an empty line is an empty frame, not a skip" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    // A framing bug here would spin the connection thread forever, so this is
    // also a regression test for the read primitive itself.
    try client.sendRaw("");
    const failure = try client.readResponse(testing.allocator);
    defer failure.deinit();
    try testing.expectEqual(false, failure.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        "bad_request",
        failure.value.object.get("error").?.object.get("code").?.string,
    );

    try client.send(.{ .id = 5, .cmd = .ping });
    const ok = try client.readResponse(testing.allocator);
    defer ok.deinit();
    try testing.expectEqual(@as(i64, 5), ok.value.object.get("id").?.integer);
}

test "socket: unknown command and missing auth are reported per frame" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    const unknown = try h.roundTrip("{\"cmd\":\"pane.explode\"}");
    defer unknown.deinit();
    try testing.expectEqualStrings(
        "unknown_command",
        unknown.value.object.get("error").?.object.get("code").?.string,
    );

    const unauthorized = try h.roundTrip("{\"cmd\":\"pane.list\"}");
    defer unauthorized.deinit();
    try testing.expectEqualStrings(
        "unauthorized",
        unauthorized.value.object.get("error").?.object.get("code").?.string,
    );
}

test "socket: authenticated pane workflow end to end" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    const create = try h.authed(",\"cmd\":\"pane.create\",\"opts\":{\"title\":\"build\"}");
    defer testing.allocator.free(create);
    try client.sendRaw(create);

    const created = try client.readResponse(testing.allocator);
    defer created.deinit();
    try testing.expectEqual(true, created.value.object.get("ok").?.bool);
    try testing.expectEqualStrings(
        "p-1",
        created.value.object.get("data").?.object.get("pane_id").?.string,
    );

    const write = try h.authed(
        ",\"cmd\":\"pane.write\",\"pane_id\":\"p-1\",\"data\":\"hello\\r\\n\"",
    );
    defer testing.allocator.free(write);
    try client.sendRaw(write);
    const written = try client.readResponse(testing.allocator);
    defer written.deinit();
    try testing.expectEqual(@as(i64, 7), written.value.object.get("data").?.object.get("written").?.integer);

    const state = try h.authed(",\"cmd\":\"pane.state\",\"pane_id\":\"p-1\"");
    defer testing.allocator.free(state);
    try client.sendRaw(state);
    const snapshot = try client.readResponse(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqualStrings(
        "build",
        snapshot.value.object.get("data").?.object.get("title").?.string,
    );

    // The connection stayed on one thread and answered three frames.
    try testing.expect(h.server.frames_handled.load(.monotonic) >= 3);
    try testing.expectEqual(@as(usize, 1), h.server.connections_accepted.load(.monotonic));
}

test "socket: subscribed events are pushed without a request" {
    var h = try Harness.init(testing.allocator, .{ .event_pusher = true, .event_poll_ms = 2 });
    defer h.deinit();

    var subscriber = try h.connect();
    defer subscriber.deinit();

    const subscribe = try h.authed(
        ",\"cmd\":\"events.subscribe\",\"opts\":{\"events\":[\"pane_created\"]}",
    );
    defer testing.allocator.free(subscribe);
    try subscriber.sendRaw(subscribe);
    const subbed = try subscriber.readResponse(testing.allocator);
    defer subbed.deinit();
    try testing.expectEqual(true, subbed.value.object.get("ok").?.bool);

    // Another agent creates a pane; this connection must receive the event
    // without asking for it.
    var other = try h.connect();
    defer other.deinit();
    const create = try h.authed(",\"cmd\":\"pane.create\",\"opts\":{\"title\":\"pushed\"}");
    defer testing.allocator.free(create);
    try other.sendRaw(create);
    const created = try other.readResponse(testing.allocator);
    defer created.deinit();
    try testing.expectEqual(true, created.value.object.get("ok").?.bool);

    const event = try subscriber.readEvent(testing.allocator);
    defer event.deinit();
    try testing.expectEqualStrings("pane_created", event.value.object.get("event").?.string);
    try testing.expectEqualStrings(
        "pushed",
        event.value.object.get("data").?.object.get("title").?.string,
    );
    try testing.expectEqual(@as(i64, 1), event.value.object.get("seq").?.integer);
}

test "client: readResponse skips event frames" {
    var h = try Harness.init(testing.allocator, .{ .event_pusher = true, .event_poll_ms = 2 });
    defer h.deinit();

    var subscriber = try h.connect();
    defer subscriber.deinit();

    const subscribe = try h.authed(",\"cmd\":\"events.subscribe\"");
    defer testing.allocator.free(subscribe);
    try subscriber.sendRaw(subscribe);
    const subbed = try subscriber.readResponse(testing.allocator);
    defer subbed.deinit();
    try testing.expectEqual(true, subbed.value.object.get("ok").?.bool);

    // Cause an event for this subscriber, then ask for something whose response
    // will arrive after the event frame.
    var other = try h.connect();
    defer other.deinit();
    const create = try h.authed(",\"cmd\":\"pane.create\"");
    defer testing.allocator.free(create);
    try other.sendRaw(create);
    const created = try other.readResponse(testing.allocator);
    defer created.deinit();

    try subscriber.send(.{ .id = 77, .cmd = .ping });
    const response = try subscriber.readResponse(testing.allocator);
    defer response.deinit();
    try testing.expectEqual(true, response.value.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 77), response.value.object.get("id").?.integer);
}

test "socket: two connections are served independently" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var first = try h.connect();
    defer first.deinit();
    var second = try h.connect();
    defer second.deinit();

    // Interleave requests: each response must land on its own connection with
    // its own id.
    try first.send(.{ .id = 1, .cmd = .ping });
    try second.send(.{ .id = 2, .cmd = .ping });

    const first_message = try first.readResponse(testing.allocator);
    defer first_message.deinit();
    const second_message = try second.readResponse(testing.allocator);
    defer second_message.deinit();

    try testing.expectEqual(@as(i64, 1), first_message.value.object.get("id").?.integer);
    try testing.expectEqual(@as(i64, 2), second_message.value.object.get("id").?.integer);
    try testing.expectEqual(@as(usize, 2), h.server.connections_accepted.load(.monotonic));
}

test "socket: a full agent workflow over one connection" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var client = try h.connect();
    defer client.deinit();

    // 1. Two panes.
    const first = try h.createPane(&client, "build");
    defer testing.allocator.free(first);
    const second = try h.createPane(&client, "logs");
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("p-1", first);
    try testing.expectEqualStrings("p-2", second);

    // 2. Drive both with VT, including a title change and a cursor move.
    try h.write(&client, first, "\\u001b[1;1Hbuilding\\r\\n\\u001b]0;make\\u0007");
    try h.write(&client, second, "log line one\\r\\nERROR: nope\\r\\n");

    // 3. Read machine state back.
    {
        const payload = try h.state(&client, first);
        defer payload.deinit();
        const snapshot = Harness.dataOf(payload).object;
        try testing.expectEqualStrings("make", snapshot.get("title").?.string);
        try testing.expectEqual(@as(i64, 1), snapshot.get("cursor").?.object.get("row").?.integer);
    }
    {
        const payload = try h.state(&client, second);
        defer payload.deinit();
        try testing.expectEqualStrings(
            "logs",
            Harness.dataOf(payload).object.get("title").?.string,
        );
    }

    // 4. Find text in the second pane's scrollback.
    {
        const payload = try h.search(&client, second, "ERROR");
        defer payload.deinit();
        const matches = Harness.dataOf(payload).object.get("matches").?.array.items;
        try testing.expectEqual(@as(usize, 1), matches.len);
        try testing.expectEqual(@as(i64, 1), matches[0].object.get("row").?.integer);
        try testing.expectEqualStrings("ERROR", matches[0].object.get("text").?.string);
    }

    // 5. List sees both, close one, and it is gone.
    {
        const payload = try h.listPanes(&client);
        defer payload.deinit();
        try testing.expectEqual(@as(usize, 2), Harness.dataOf(payload).array.items.len);
    }
    try h.closePane(&client, second);
    {
        const payload = try h.listPanes(&client);
        defer payload.deinit();
        const panes = Harness.dataOf(payload).array.items;
        try testing.expectEqual(@as(usize, 1), panes.len);
        try testing.expectEqualStrings("p-1", panes[0].object.get("pane_id").?.string);
    }

    // 6. Operating on the closed pane is an error, not a crash.
    {
        const state_request = try h.authedFrame(",\"cmd\":\"pane.state\",\"pane_id\":\"p-2\"");
        defer testing.allocator.free(state_request);
        try client.sendRaw(state_request);
        const payload = try client.readResponse(testing.allocator);
        defer payload.deinit();
        try testing.expectEqual(false, payload.value.object.get("ok").?.bool);
        try testing.expectEqualStrings(
            "pane_not_found",
            payload.value.object.get("error").?.object.get("code").?.string,
        );
    }
}

test "lifecycle: stop is idempotent and deinit drains connections" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    {
        var client = try h.connect();
        defer client.deinit();
        try client.send(.{ .cmd = .ping });
        const message = try client.readResponse(testing.allocator);
        defer message.deinit();
        try testing.expect(message.value.object.get("ok").?.bool);
        try testing.expect(h.server.live_connections.load(.acquire) >= 1);
    }

    // Once the client is gone, the connection thread finishes on its own.
    try testing.expect(h.server.drainConnections(5_000));
    try testing.expectEqual(@as(usize, 0), h.server.live_connections.load(.acquire));

    h.server.stop();
    h.server.stop();
    try testing.expectEqual(false, h.server.running.load(.acquire));
}

/// One agent's request sequence, used by the concurrency test. Returns the
/// number of completed steps so a silent early exit cannot look like success.
fn agentSequence(h: *Harness, index: usize) !usize {
    var client = try h.connect();
    defer client.deinit();

    var steps: usize = 0;

    const title = try std.fmt.allocPrint(testing.allocator, "agent-{d}", .{index});
    defer testing.allocator.free(title);
    const pane_id = try h.createPane(&client, title);
    defer testing.allocator.free(pane_id);
    steps += 1;

    // Each agent writes a needle that only it uses, so a search hit proves the
    // write landed in this agent's own pane.
    const needle = try std.fmt.allocPrint(testing.allocator, "needle-{d}", .{index});
    defer testing.allocator.free(needle);
    const data = try std.fmt.allocPrint(testing.allocator, "{s}\\r\\n", .{needle});
    defer testing.allocator.free(data);
    try h.write(&client, pane_id, data);
    steps += 1;

    {
        const payload = try h.state(&client, pane_id);
        defer payload.deinit();
        try testing.expectEqualStrings(
            title,
            Harness.dataOf(payload).object.get("title").?.string,
        );
    }
    steps += 1;

    {
        const payload = try h.search(&client, pane_id, needle);
        defer payload.deinit();
        try testing.expect(
            Harness.dataOf(payload).object.get("matches").?.array.items.len >= 1,
        );
    }
    steps += 1;

    {
        const payload = try h.listPanes(&client);
        defer payload.deinit();
        try testing.expect(Harness.dataOf(payload).array.items.len >= 1);
    }
    steps += 1;

    try h.closePane(&client, pane_id);
    steps += 1;

    return steps;
}

fn agentMain(h: *Harness, index: usize, out: *std.atomic.Value(usize)) void {
    const steps = agentSequence(h, index) catch |err| {
        std.debug.print("agent {d} failed: {}\n", .{ index, err });
        return;
    };
    out.store(steps, .release);
}

/// Steps every agent is expected to complete (create, write, state, search,
/// list, close).
const agent_steps = 6;

test "socket: concurrent agents do not deadlock and do not cross panes" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    const agent_count = 6;
    var results: [agent_count]std.atomic.Value(usize) = undefined;
    for (&results) |*result| result.* = .init(0);

    var threads: [agent_count]std.Thread = undefined;
    for (0..agent_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, agentMain, .{ h, i, &results[i] });
    }
    // Joining is the deadlock check: a lock cycle would hang here rather than
    // produce a wrong answer.
    for (threads) |thread| thread.join();

    for (results, 0..) |result, i| {
        const steps = result.load(.acquire);
        if (steps != agent_steps) {
            std.debug.print("agent {d} completed {d}/{d} steps\n", .{ i, steps, agent_steps });
            return error.TestUnexpectedResult;
        }
    }

    // Every agent opened its own connection and had every frame answered.
    try testing.expectEqual(
        @as(usize, agent_count),
        h.server.connections_accepted.load(.monotonic),
    );
    try testing.expect(
        h.server.frames_handled.load(.monotonic) >= agent_count * agent_steps,
    );

    // Each agent closed its own pane, so the registry is empty and no pane was
    // closed twice.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var remaining: std.ArrayListUnmanaged(pane.PaneInfo) = .empty;
    try h.manager.list(arena.allocator(), h.io, &remaining);
    try testing.expectEqual(@as(usize, 0), remaining.items.len);
    try testing.expectEqual(@as(usize, agent_count), h.fake.close_calls);
}
