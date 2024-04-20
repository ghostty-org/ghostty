const xev = @import("xev");
const std = @import("std");
const Server = @import("../Server.zig").Server;
const Command = @import("../Command.zig").Command;
const reject_client = @import("./reject.zig").reject_client;
const read_client = @import("./reader.zig").read_client;

const log = std.log.scoped(.tcp_thread);

/// Starts accepting client connections on the server's socket.
/// Note: This first xev.Completion is not destroyed here because it gets used
/// for an entire client connection lifecycle.
pub fn startAccepting(self: *Server) !void {
    const c = try self.comp_pool.create();
    self.socket.accept(&self.loop, c, Server, self, aHandler);
}

/// Accepts a new client connection and starts reading from it until EOF.
/// Once an accept handler enters, it queues for a new client connection.
/// It essentially recursively calls itself until shutdown.
fn aHandler(
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
    self.socket.accept(&self.loop, new_c, Server, self, aHandler);

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

fn sHandler(
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

    sock.close(loop, comp, Server, self, cHandler);
    return .disarm;
}

/// Closes the client connection and cleans up the completion.
pub fn cHandler(
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
