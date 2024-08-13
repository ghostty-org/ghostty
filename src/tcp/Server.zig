const std = @import("std");
const xev = @import("xev");
const Config = @import("../config/Config.zig");
const connections = @import("./handlers/connections.zig");
const App = @import("../App.zig");

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

/// A reference to the app's main mailbox to dispathc messages
mailbox: *App.Mailbox.Queue,

/// Initializes the server with the given allocator and address
pub fn init(
    alloc: Allocator,
    addr: std.net.Address,
    max_clients: u8,
    mailbox: *App.Mailbox.Queue,
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
        .mailbox = mailbox,
    };
}

/// Deinitializes the server
pub fn deinit(self: *Server) void {
    self.close();
    log.info("closing server socket", .{});
    log.info("deinitializing server", .{});
    self.loop.deinit();
    self.comp_pool.deinit();
    self.sock_pool.deinit();
    self.buf_pool.deinit();
}

/// Starts the timer which tries to accept connections
pub fn start(self: *Server) !void {
    try self.socket.bind(self.addr);
    try self.socket.listen(self.max_clients);

    try connections.startAccepting(self);
    log.info("bound server to socket={any}", .{self.socket});

    // TODO(tale): Stop flag? Only necessary if we support signaling the server
    // from the main thread on an event, ie. configuration reloading.
    try self.loop.run(.until_done);
}

/// Closes the server socket
pub fn close(self: *Server) void {
    var c: xev.Completion = undefined;
    self.socket.close(&self.loop, &c, bool, null, (struct {
        fn callback(
            _: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.TCP,
            e: xev.TCP.CloseError!void,
        ) xev.CallbackAction {
            e catch {
                log.err("failed to close server socket: {any}", .{e});
            };

            return .disarm;
        }
    }).callback);
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

test "parseAddress unix socket" {
    const addr = "unix:///tmp/test.sock";
    const expected = try std.net.Address.initUnix("/tmp/test.sock");
    const actual = try parseAddress(addr);
    const result = std.net.Address.eql(actual, expected);
    try std.testing.expect(result == true);
}

test "parseAddress IP address" {
    const addr = "tcp://127.0.0.1:9090";
    const expected = try std.net.Address.parseIp4("127.0.0.1", 9090);
    const actual = try parseAddress(addr);
    const result = std.net.Address.eql(actual, expected);
    try std.testing.expect(result == true);
}
