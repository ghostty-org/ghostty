const std = @import("std");
const xev = @import("xev");
const Config = @import("../config/Config.zig");
const connections = @import("./handlers/connections.zig");

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
    try connections.startAccepting(self);
    log.info("bound server to socket={any}", .{self.socket});

    // TODO: Stop flag? Only necessary if we support signaling the server
    // from the main thread on an event, ie. configuration reloading.
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

const BindError = error{
    NoAddress,
    InvalidAddress,
};

/// Tries to generate a valid address to bind to, expects that the address will
/// start with tcp:// when binding to an IP and unix:// when binding to a file
/// based socket.
pub fn parseAddress(raw_addr: ?[:0]const u8) BindError!std.net.Address {
    const addr = raw_addr orelse {
        return BindError.NoAddress;
    };

    if (addr.len == 0) {
        return BindError.NoAddress;
    }

    const uri = std.Uri.parse(addr) catch return BindError.InvalidAddress;
    if (std.mem.eql(u8, uri.scheme, "tcp")) {
        const host = uri.host orelse return BindError.InvalidAddress;
        const port = uri.port orelse return BindError.InvalidAddress;

        return std.net.Address.parseIp4(host.percent_encoded, port) catch {
            return BindError.InvalidAddress;
        };
    }

    // TODO: Should we check for valid file paths or just rely on the initUnix
    // function to return an error?
    if (std.mem.eql(u8, uri.scheme, "unix")) {
        return std.net.Address.initUnix(uri.path.percent_encoded) catch {
            return BindError.InvalidAddress;
        };
    }

    return BindError.InvalidAddress;
}
