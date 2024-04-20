//! Represents the libxev thread for handling TCP connections.
pub const Thread = @This();

const std = @import("std");
const xev = @import("xev");
const tcp = @import("../tcp.zig");
const App = @import("../App.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tcp_thread);

/// Allocator used for xev allocations.
alloc: std.mem.Allocator,

/// The TCP server for handling incoming connections.
server: tcp.Server,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator) !Thread {
    // TODO: Configurable addresses and socket paths
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9090);
    var server = try tcp.Server.init(alloc, addr);
    errdefer server.deinit();

    return Thread{
        .alloc = alloc,
        .server = server,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.server.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.warn("error in tcp thread err={any}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    log.debug("starting tcp thread", .{});
    defer log.debug("tcp thread exited", .{});
    try self.server.start();
}
