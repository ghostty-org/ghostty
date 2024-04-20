const xev = @import("xev");
const std = @import("std");
const Server = @import("../Server.zig").Server;

const log = std.log.scoped(.tcp_thread);

const RejectError = error{
    AllocError,
    WriteError,
};

// TODO: Support client rejection reasons.
pub fn reject_client(self: *Server, c: *xev.TCP) !void {
    const buf_w = self.buf_pool.create() catch return RejectError.AllocError;
    const comp_w = self.comp_pool.create() catch {
        Server.destroyBuffer(self, buf_w);
        return RejectError.AllocError;
    };

    @memcpy(buf_w.ptr, "ERR: Max connections reached\n");
    c.write(&self.loop, comp_w, .{ .slice = buf_w }, Server, self, wHandler);
}

fn wHandler(
    self_: ?*Server,
    l: *xev.Loop,
    c: *xev.Completion,
    client: xev.TCP,
    b: xev.WriteBuffer,
    e: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    const self = self_.?;
    _ = e catch |err| {
        Server.destroyBuffer(self, b.slice);
        log.err("write error {any}", .{err});
        return .disarm;
    };

    client.close(l, c, Server, self, Server.closeHandler);
    return .disarm;
}
