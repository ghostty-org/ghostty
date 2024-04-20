const std = @import("std");
const xev = @import("xev");
const Config = @import("../Config.zig").Config;

const reject_client = @import("./handlers/reject.zig").reject_client;
const read_client = @import("./handlers/reader.zig").read_client;

const Allocator = std.mem.Allocator;
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const SocketPool = std.heap.MemoryPool(xev.TCP);
const BufferPool = std.heap.MemoryPool([1024]u8);
const log = std.log.scoped(.tcp_thread);

/// Acceptor polling rate in milliseconds
const ACCEPTOR_RATE = 1;

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

/// Timer for accepting connections
acceptor: xev.Timer,

/// Array of client sockets
/// TODO: Merge with `sock_pool`? or make a hashmap
clients: SocketPool,

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
        .comp_pool = CompletionPool.init(alloc),
        .sock_pool = SocketPool.init(alloc),
        .buf_pool = BufferPool.init(alloc),
        .loop = try xev.Loop.init(.{}),
        .socket = try xev.TCP.init(addr),
        .acceptor = try xev.Timer.init(),
        .clients = undefined,
        .clients_count = 0,
        .alloc = alloc,
        .max_clients = max_clients,
        .addr = addr,
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
    self.buf_pool.deinit();
    self.comp_pool.deinit();
    self.sock_pool.deinit();
    self.loop.deinit();
    self.acceptor.deinit();
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

    self.acceptor.run(&self.loop, c, ACCEPTOR_RATE, Server, self, acceptor);
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
    _: *xev.Loop,
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

    if (self.clients_count == self.max_clients) {
        log.warn("max clients reached, rejecting fd={d}", .{sock.fd});
        reject_client(self, sock) catch return .rearm;
        return .disarm;
    }

    log.info("accepted connection fd={d}", .{sock.fd});
    // self.clients[self.clients_count] = sock;
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
