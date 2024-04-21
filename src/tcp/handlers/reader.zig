const xev = @import("xev");
const std = @import("std");
const Server = @import("../Server.zig").Server;
const Command = @import("../Command.zig").Command;
const connections = @import("./connections.zig");

const log = std.log.scoped(.tcp_thread);

pub fn read_client(
    self: *Server,
    client: *xev.TCP,
    c: *xev.Completion,
) !void {
    const buf_r = self.buf_pool.create() catch return error.OutOfMemory;
    client.read(&self.loop, c, .{ .slice = buf_r }, Server, self, rHandler);
}

fn rHandler(
    self_: ?*Server,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    e: xev.TCP.ReadError!usize,
) xev.CallbackAction {
    const self = self_.?;
    const len = e catch |err| {
        Server.destroyBuffer(self, b.slice);
        switch (err) {
            error.EOF => {
                log.info("client disconnected fd={d}", .{s.fd});
                self.clients_count -= 1;
                s.close(l, c, Server, self, connections.cHandler);
                return .disarm;
            },

            else => {
                log.err("client read error fd={d} err={any}", .{ s.fd, err });
                return .disarm;
            },
        }
    };

    // Create the completion task and buffer for our command responses
    const c_w = self.comp_pool.create() catch return .rearm;
    const b_w = self.buf_pool.create() catch return .rearm;

    // Split commands by newline
    var iter = std.mem.splitScalar(u8, b.slice[0..len], '\n');
    while (iter.next()) |line| {
        // Skip empty lines
        if (line.len == 0) {
            continue;
        }

        const cmd = Command.parse(line) catch |err| {
            const res = try Command.handleError(err);
            @memcpy(b_w.ptr, res.ptr[0..res.len]);
            continue;
        };

        const res = try Command.handle(cmd, self);
        @memcpy(b_w.ptr, res.ptr[0..res.len]);
    }

    s.write(l, c_w, .{ .slice = b_w }, Server, self, wHandler);
    return .rearm;
}

fn wHandler(
    self_: ?*Server,
    _: *xev.Loop,
    _: *xev.Completion,
    s: xev.TCP,
    b: xev.WriteBuffer,
    e: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    const self = self_.?;
    _ = e catch |err| {
        log.err("client write error fd={d} err={any}", .{ s.fd, err });
        Server.destroyBuffer(self, b.slice);
    };

    return .disarm;
}
