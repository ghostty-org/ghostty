const std = @import("std");
const xev = @import("xev");
const tcp = @import("../tcp.zig");

const reject_client = @import("./handlers/reject.zig").reject_client;

const Allocator = std.mem.Allocator;
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const SocketPool = std.heap.MemoryPool(xev.TCP);
const BufferPool = std.heap.MemoryPool([1024]u8);
const log = std.log.scoped(.tcp_thread);

/// Maximum connections we allow at once
const MAX_CLIENTS = 2;

/// Acceptor polling rate in milliseconds
const ACCEPTOR_RATE = 1;

/// A wrapper around the TCP server socket
pub const Server = @This();

/// Memory pool that stores the completions required by xev
comp_pool: CompletionPool,

/// Memory pool that stores client sockets
sock_pool: SocketPool,

/// Memory pool that stores buffers for reading and writing
buf_pool: BufferPool,

/// Stop flag
stop: bool,

/// Event loop
loop: xev.Loop,

/// Server socket
socket: xev.TCP,

/// Timer for accepting connections
acceptor: xev.Timer,

/// Array of client sockets
clients: [MAX_CLIENTS]*xev.TCP,

/// Number of clients connected
clients_count: usize,

/// Initializes the server with the given allocator and address
pub fn init(alloc: Allocator, addr: std.net.Address) !Server {
    const socket = try xev.TCP.init(addr);
    try socket.bind(addr);

    return Server{
        .comp_pool = CompletionPool.init(alloc),
        .sock_pool = SocketPool.init(alloc),
        .buf_pool = BufferPool.init(alloc),
        .stop = false,
        .loop = try xev.Loop.init(.{}),
        .socket = socket,
        .acceptor = try xev.Timer.init(),
        .clients = undefined,
        .clients_count = 0,
    };
}

/// Deinitializes the server
pub fn deinit(self: *Server) void {
    self.buf_pool.deinit();
    self.comp_pool.deinit();
    self.sock_pool.deinit();
    self.loop.deinit();
    self.acceptor.deinit();
}

/// Starts the timer which tries to accept connections
pub fn start(self: *Server) !void {
    try self.socket.listen(MAX_CLIENTS);
    log.info("bound server to socket={any}", .{self.socket});

    // Each acceptor borrows a completion from the pool
    // We do this because the completion is passed to the client TCP handlers
    const c = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return error.OutOfMemory;
    };

    self.acceptor.run(&self.loop, c, ACCEPTOR_RATE, Server, self, acceptor);
    while (!self.stop) {
        try self.loop.run(.until_done);
    }
}

/// Convenience function to destroy a buffer in our pool
fn destroyBuffer(self: *Server, buf: []const u8) void {
    self.buf_pool.destroy(@alignCast(
        @as(*[1024]u8, @ptrFromInt(@intFromPtr(buf.ptr))),
    ));
}

/// This runs on a loop and attempts to accept a connection to pass into the
/// handlers that manage client communication. It is very important to note
/// that the xev.Completion is shared between the acceptor and other handlers.
/// When a client disconnects, only then the completion is freed.
fn acceptor(
    self_: ?*Server,
    loop: *xev.Loop,
    c: *xev.Completion,
    e: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = self_.?;
    e catch {
        log.err("timer error", .{});
        return .disarm;
    };

    self.socket.accept(loop, c, Server, self, acceptHandler);

    // We need to create a new completion for the next acceptor since each
    // TCP connection will need its own if it successfully accepts.
    const accept_recomp = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return .disarm;
    };

    // We can't rearm because it'll repeat *this* instance of the acceptor
    // So if the socket fails to accept it won't actually accept anything new
    self.acceptor.run(loop, accept_recomp, ACCEPTOR_RATE, Server, self, acceptor);
    return .disarm;
}

/// Accepts a new client connection and starts reading from it until EOF.
fn acceptHandler(
    self_: ?*Server,
    l: *xev.Loop,
    c: *xev.Completion,
    e: xev.TCP.AcceptError!xev.TCP,
) xev.CallbackAction {
    const self = self_.?;
    const sock = self.sock_pool.create() catch {
        log.err("couldn't allocate socket in pool", .{});
        return .disarm;
    };

    sock.* = e catch {
        log.err("accept error", .{});
        self.sock_pool.destroy(sock);
        return .disarm;
    };

    const comp_w = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return .disarm;
    };

    const buf_w = self.buf_pool.create() catch {
        log.err("couldn't allocate buffer in pool", .{});
        self.sock_pool.destroy(sock);
        return .disarm;
    };

    if (self.clients_count == MAX_CLIENTS) {
        log.warn("max clients reached, rejecting fd={d}", .{sock.fd});
        reject_client(self, sock) catch return .rearm;
        return .disarm;
    }

    log.info("accepted connection fd={d}", .{sock.fd});
    self.clients[self.clients_count] = sock;
    self.clients_count += 1;

    const buf_r = self.buf_pool.create() catch {
        log.err("couldn't allocate buffer in pool", .{});
        return .disarm;
    };

    @memcpy(buf_w.ptr, "GHOSTTY\n");
    sock.write(l, comp_w, .{ .slice = buf_w }, Server, self, writeHandler);
    sock.read(l, c, .{ .slice = buf_r }, Server, self, readHandler);
    return .disarm;
}

fn readHandler(
    self_: ?*Server,
    loop: *xev.Loop,
    comp: *xev.Completion,
    sock: xev.TCP,
    buf: xev.ReadBuffer,
    e: xev.TCP.ReadError!usize,
) xev.CallbackAction {
    const self = self_.?;
    const l = e catch |err| {
        switch (err) {
            error.EOF => {
                log.info("disconnecting client fd={d}", .{sock.fd});
                destroyBuffer(self, buf.slice);
                self.clients_count -= 1;
                sock.close(loop, comp, Server, self, closeHandler);
                return .disarm;
            },

            else => {
                destroyBuffer(self, buf.slice);
                log.err("read error", .{});
                return .disarm;
            },
        }
    };

    const comp_w = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return .rearm;
    };

    const buf_w = self.buf_pool.create() catch {
        log.err("couldn't allocate buffer in pool", .{});
        return .rearm;
    };

    // TODO: What should we do with the rest of the buffer?
    var iter = std.mem.splitScalar(u8, buf.slice[0..l], '\n');
    while (iter.next()) |item| {
        if (item.len == 0) {
            continue;
        }

        const c = tcp.Command.parse(item) catch |err| {
            const res = try tcp.Command.handleError(err);
            @memcpy(buf_w.ptr, res.ptr[0..res.len]);
            sock.write(loop, comp_w, .{ .slice = buf_w }, Server, self, writeHandler);
            return .rearm;
        };

        const res = try tcp.Command.handle(c);
        @memcpy(buf_w.ptr, res.ptr[0..res.len]);
    }

    sock.write(loop, comp_w, .{ .slice = buf_w }, Server, self, writeHandler);
    return .rearm;
}

fn writeHandler(
    self_: ?*Server,
    loop: *xev.Loop,
    comp: *xev.Completion,
    sock: xev.TCP,
    buf: xev.WriteBuffer,
    e: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    _ = sock;
    _ = comp;
    _ = loop;
    const self = self_.?;
    _ = e catch |err| {
        destroyBuffer(self, buf.slice);
        log.err("write error {any}", .{err});
        return .disarm;
    };

    return .disarm;
}

fn rejectHandler(
    self_: ?*Server,
    l: *xev.Loop,
    c: *xev.Completion,
    sock: xev.TCP,
    buf: xev.WriteBuffer,
    e: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    const self = self_.?;
    _ = e catch |err| {
        destroyBuffer(self, buf.slice);
        log.err("write error {any}", .{err});
        return .disarm;
    };

    sock.close(l, c, Server, self, closeHandler);
    return .disarm;
}

fn shutdownHandler(
    self_: ?*Server,
    loop: *xev.Loop,
    comp: *xev.Completion,
    sock: xev.TCP,
    e: xev.TCP.ShutdownError!void,
) xev.CallbackAction {
    e catch {
        // Is this even possible?
        log.err("couldn't shutdown socket", .{});
    };

    const self = self_.?;

    sock.close(loop, comp, Server, self, closeHandler);
    return .disarm;
}

pub fn closeHandler(
    self_: ?*Server,
    loop: *xev.Loop,
    comp: *xev.Completion,
    sock: xev.TCP,
    e: xev.TCP.CloseError!void,
) xev.CallbackAction {
    _ = sock;
    _ = loop;

    e catch {
        log.err("couldn't close socket", .{});
    };

    const self = self_.?;
    self.comp_pool.destroy(comp);
    return .disarm;
}
