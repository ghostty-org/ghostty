const std = @import("std");
const xev = @import("xev");
const Config = @import("../config/Config.zig");

const reject_client = @import("./handlers/reject.zig").reject_client;
const read_client = @import("./handlers/reader.zig").read_client;

const Allocator = std.mem.Allocator;
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const SocketPool = std.heap.MemoryPool(xev.TCP);
const BufferPool = std.heap.MemoryPool([1024]u8);
const log = std.log.scoped(.tcp_thread);

/// A wrapper around the TCP server socket
pub const Server = @This();

/// Used for response formatting
alloc: Allocator,

/// Memory pool that stores the completions required by xev
comp_pool: CompletionPool,

/// Memory pool that stores client sockets
sock_pool: SocketPool,

/// Memory pool that stores buffers for reading and writing
buf_pool: BufferPool,

/// Event loop
loop: xev.Loop,

/// Server socket
socket: xev.TCP,

/// Number of clients connected
clients_count: usize,

/// Address to bind to
addr: std.net.Address,

/// Maximum clients allowed
max_clients: u8,

/// Initializes the server with the given allocator and address
pub fn init(
    alloc: Allocator,
    addr: std.net.Address,
    max_clients: u8,
) !Server {
    return Server{
        .alloc = alloc,
        .comp_pool = CompletionPool.init(alloc),
        .sock_pool = SocketPool.init(alloc),
        .buf_pool = BufferPool.init(alloc),
        .loop = try xev.Loop.init(.{}),
        .socket = try xev.TCP.init(addr),
        .clients_count = 0,
        .addr = addr,
        .max_clients = max_clients,
    };
}

const BindError = error{
    NoAddress,
    InvalidAddress,
};

/// Tries to generate a valid address to bind to
/// TODO: Maybe unix sockets should start with unix://
pub fn parseAddress(raw_addr: ?[:0]const u8) BindError!std.net.Address {
    const addr = raw_addr orelse {
        return BindError.NoAddress;
    };

    if (addr.len == 0) {
        return BindError.NoAddress;
    }

    var iter = std.mem.splitScalar(u8, addr, ':');
    const host = iter.next() orelse return BindError.InvalidAddress;
    const port = iter.next() orelse return BindError.InvalidAddress;
    const numPort = std.fmt.parseInt(u16, port, 10) catch {
        return std.net.Address.initUnix(addr) catch BindError.InvalidAddress;
    };

    const ip = std.net.Address.parseIp4(host, numPort) catch {
        return std.net.Address.initUnix(addr) catch BindError.InvalidAddress;
    };

    return ip;
}

/// Deinitializes the server
pub fn deinit(self: *Server) void {
    log.info("shutting down server", .{});
    self.comp_pool.deinit();
    self.sock_pool.deinit();
    self.buf_pool.deinit();
    self.loop.deinit();
}

/// Starts the timer which tries to accept connections
pub fn start(self: *Server) !void {
    try self.socket.bind(self.addr);
    try self.socket.listen(self.max_clients);
    log.info("bound server to socket={any}", .{self.socket});

    // Each acceptor borrows a completion from the pool
    // We do this because the completion is passed to the client TCP handlers
    const c = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return error.OutOfMemory;
    };

    self.socket.accept(&self.loop, c, Server, self, acceptHandler);
    while (true) {
        try self.loop.run(.until_done);
    }
}

/// Convenience function to destroy a buffer in our pool
pub fn destroyBuffer(self: *Server, buf: []const u8) void {
    self.buf_pool.destroy(@alignCast(
        @as(*[1024]u8, @ptrFromInt(@intFromPtr(buf.ptr))),
    ));
}

/// Accepts a new client connection and starts reading from it until EOF.
/// Once an accept handler enters, it queues for a new client connection.
/// It essentially recursively calls itself until shutdown.
fn acceptHandler(
    self_: ?*Server,
    _: *xev.Loop,
    c: *xev.Completion,
    e: xev.TCP.AcceptError!xev.TCP,
) xev.CallbackAction {
    const self = self_.?;
    const new_c = self.comp_pool.create() catch {
        log.err("couldn't allocate completion in pool", .{});
        return .disarm;
    };

    // Accept a new client connection now that we have a new completion
    self.socket.accept(&self.loop, new_c, Server, self, acceptHandler);

    const sock = self.sock_pool.create() catch {
        log.err("couldn't allocate socket in pool", .{});
        return .disarm;
    };

    sock.* = e catch {
        log.err("accept error", .{});
        self.sock_pool.destroy(sock);
        return .disarm;
    };

    if (self.clients_count == self.max_clients) {
        log.warn("max clients reached, rejecting fd={d}", .{sock.fd});
        reject_client(self, sock) catch return .rearm;
        return .disarm;
    }

    log.info("accepted connection fd={d}", .{sock.fd});
    self.clients_count += 1;

    read_client(self, sock, c) catch {
        log.err("couldn't read from client", .{});
    };

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
    _: *xev.Loop,
    comp: *xev.Completion,
    _: xev.TCP,
    e: xev.TCP.CloseError!void,
) xev.CallbackAction {
    e catch {
        log.err("couldn't close socket", .{});
    };

    const self = self_.?;
    self.comp_pool.destroy(comp);
    return .disarm;
}
