//! Represents the libxev thread for handling TCP connections.
pub const Thread = @This();

const std = @import("std");
const xev = @import("xev");
const App = @import("../App.zig");
const Config = @import("../config/Config.zig");
const Server = @import("Server.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tcp_thread);

/// Allocator used for xev allocations.
alloc: std.mem.Allocator,

/// The TCP server for handling incoming connections.
server: ?Server,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator, mailbox: *App.Mailbox.Queue) !Thread {
    const config = try Config.load(alloc);
    const max_clients = config.@"remote-max-connections";
    const addr = config.@"remote-tcp-socket";

    const parsedAddr = Server.parseAddress(addr) catch |err| {
        log.err("failed to parse address addr={any} err={any}", .{ addr, err });
        return Thread{
            .alloc = alloc,
            .server = undefined,
        };
    };

    log.debug("parsed address addr={any}", .{parsedAddr});
    var server = try Server.init(
        alloc,
        parsedAddr,
        max_clients,
        mailbox,
    );

    errdefer server.deinit();
    return Thread{
        .alloc = alloc,
        .server = server,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    if (self.server) |*server| {
        server.deinit();
    }
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.warn("error in tcp thread err={any}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    if (self.server) |*server| {
        log.debug("starting tcp thread", .{});
        defer log.debug("tcp thread exited", .{});
        try server.start();
    }
}
