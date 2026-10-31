//! Native daemon transport. The relay owns reconnection; the surface stays alive.
const Self = @This();
const std = @import("std");
const global = @import("../../global.zig");
const HostIO = @import("../../omg_session_host.zig").HostIO;
const terminal = @import("../../terminal/main.zig");
const renderer = @import("../../renderer.zig");
const apprt = @import("../../apprt.zig");
const ProcessInfo = @import("../../pty.zig").ProcessInfo;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("sys/time.h");
    @cInclude("errno.h");
});
alloc: std.mem.Allocator,
path: [:0]u8,
pane_id: ?[]u8 = null,
fd: c_int = -1,
write_mutex: std.Io.Mutex = .init,
ready: std.atomic.Value(bool) = .init(false),
generation: std.atomic.Value(u64) = .init(0),
stopping: std.atomic.Value(bool) = .init(false),
close_requested: std.atomic.Value(bool) = .init(false),
requested_size: std.atomic.Value(u32) = .init((80 << 16) | 24),

pub fn init(alloc: std.mem.Allocator, path: []const u8, pane_id: ?[]const u8) !Self {
    const owned_path = try alloc.dupeZ(u8, path);
    errdefer alloc.free(owned_path);
    return .{ .alloc = alloc, .path = owned_path, .pane_id = if (pane_id) |id| try alloc.dupe(u8, id) else null };
}
pub fn deinit(self: *Self) void {
    self.alloc.free(self.path);
    if (self.pane_id) |id| self.alloc.free(id);
}
pub fn initTerminal(_: *Self, _: *terminal.Terminal) void {}
pub const ThreadData = struct {
    thread: std.Thread,
    pub fn deinit(_: *ThreadData, _: std.mem.Allocator) void {}
};
pub fn threadEnter(self: *Self, _: std.mem.Allocator, io: *HostIO, td: *HostIO.ThreadData) !void {
    const address: c.struct_sockaddr_un = undefined;
    if (self.path.len >= address.sun_path.len) return error.SocketPathTooLong;
    const grid = io.size.grid();
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    td.backend = .{ .omg_session = .{ .thread = try std.Thread.spawn(.{}, reader, .{ self, io }) } };
}
fn openSocket(self: *Self) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire)) return error.Disconnected;
    self.fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (self.fd < 0) return error.SocketFailed;
    if (@hasDecl(c, "SO_NOSIGPIPE")) {
        var enabled: c_int = 1;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_NOSIGPIPE, &enabled, @sizeOf(c_int));
    }
    var timeout = c.struct_timeval{ .tv_sec = 1, .tv_usec = 0 };
    _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &timeout, @sizeOf(@TypeOf(timeout)));
}
fn closeSocket(self: *Self) void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    self.ready.store(false, .release);
    if (self.fd >= 0) {
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
        _ = c.close(self.fd);
        self.fd = -1;
    }
}
pub fn threadExit(self: *Self, td: *HostIO.ThreadData) void {
    self.write_mutex.lockUncancelable(global.io());
    self.stopping.store(true, .release);
    if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
    self.write_mutex.unlock(global.io());
    td.backend.omg_session.thread.join();
}
pub fn closeSession(self: *Self) void {
    self.close_requested.store(true, .release);
    if (self.ready.load(.acquire)) self.send('K', self.generation.load(.acquire), &.{}) catch {};
}
pub fn focusGained(_: *Self, _: *HostIO.ThreadData, _: bool) !void {}
pub fn resize(self: *Self, grid: renderer.GridSize, _: renderer.ScreenSize) !void {
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    if (!self.ready.load(.acquire)) return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], grid.columns, .big);
    std.mem.writeInt(u16, bytes[2..4], grid.rows, .big);
    try self.send('R', self.generation.load(.acquire), &bytes);
}
pub fn queueWrite(self: *Self, _: std.mem.Allocator, _: *HostIO.ThreadData, data: []const u8, _: bool) !void {
    const generation = self.inputGeneration() orelse return error.SessionNotReady;
    try self.queueWriteGeneration(generation, data);
}
pub fn inputGeneration(self: *Self) ?u64 {
    const generation = self.generation.load(.acquire);
    if (!self.ready.load(.acquire) or generation != self.generation.load(.acquire)) return null;
    return generation;
}
pub fn queueWriteGeneration(self: *Self, generation: u64, data: []const u8) !void {
    if (!self.ready.load(.acquire)) return error.SessionNotReady;
    try self.send('I', generation, data);
}
pub fn getProcessInfo(_: *Self, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return null;
}
fn send(self: *Self, kind: u8, seq: u64, data: []const u8) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if ((kind == 'I' or kind == 'R') and
        (!self.ready.load(.acquire) or seq != self.generation.load(.acquire))) return error.SessionNotReady;
    // A partially written frame cannot be retried on this connection.
    errdefer {
        self.ready.store(false, .release);
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }
    var header: [13]u8 = undefined;
    header[0] = kind;
    std.mem.writeInt(u64, header[1..9], seq, .big);
    std.mem.writeInt(u32, header[9..13], @intCast(data.len), .big);
    for ([_][]const u8{ &header, data }) |part| {
        var offset: usize = 0;
        while (offset < part.len) {
            const n = c.send(self.fd, part.ptr + offset, part.len - offset, 0);
            if (n <= 0) return error.Disconnected;
            offset += @intCast(n);
        }
    }
}
fn readExact(self: *Self, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(self.fd, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
fn reader(self: *Self, io: *HostIO) void {
    defer self.closeSocket();
    var attached = false;
    while (!self.stopping.load(.acquire)) {
        self.openSocket() catch {
            self.publishFailure(io, "Could not open the local runtime connection. The session process is preserved.", false) catch {};
            return;
        };
        self.readLoop(io, &attached) catch |err| {
            self.closeSocket();
            if (self.stopping.load(.acquire)) return;
            std.log.warn("OMG session disconnected: {s}", .{@errorName(err)});
            const recoverable = err == error.Disconnected or err == error.ConnectFailed or err == error.OutputGap;
            self.publishFailure(io, if (recoverable)
                "The session connection ended. Retry to reconnect to the existing session."
            else
                "The terminal protocol could not be restored. The session process is preserved; use a compatible app.", recoverable) catch {};
            // The GUI may restart a failed relay at the same socket path.
            // Keep this Surface and its last frame while waiting for it.
            if (recoverable) {
                _ = c.usleep(100_000);
                continue;
            }
            return;
        };
        return; // A real session exit is not a transport reconnect.
    }
}

fn publishState(self: *Self, io: *HostIO, metadata: []const u8) !void {
    const signal = try apprt.surface.Message.ContextSignal.init(self.alloc, .{
        .action = .start,
        .id = "omg-runtime-state",
        .metadata = metadata,
    });
    _ = io.surface_mailbox.push(.{ .context_signal = signal }, .{ .forever = {} });
}

fn publishFailure(self: *Self, io: *HostIO, message: []const u8, retryable: bool) !void {
    const metadata = try std.json.Stringify.valueAlloc(self.alloc, .{
        .state = "failed",
        .attempt = @as(u32, 0),
        .message = message,
        .retryable = retryable,
    }, .{});
    defer self.alloc.free(metadata);
    try self.publishState(io, metadata);
}
fn readLoop(self: *Self, io: *HostIO, attached: *bool) !void {
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..self.path.len], self.path);
    // Deployment may upload the runtime before publishing the local socket.
    // This runs on the dedicated reader, never the AppKit thread.
    var attempts: usize = 0;
    while (c.connect(self.fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        if (self.stopping.load(.acquire)) return error.Disconnected;
        attempts += 1;
        if (attempts >= 600) return error.ConnectFailed;
        _ = c.usleep(100_000);
    }
    if (self.pane_id) |id| {
        if (attached.*) {
            const request = try reattachRequest(self.alloc, id);
            defer self.alloc.free(request);
            try self.send('H', 0, request);
        } else {
            try self.send('H', 0, id);
        }
    }
    var sequence: ?u64 = null;
    while (true) {
        var h: [13]u8 = undefined;
        try self.readExact(&h);
        const seq = std.mem.readInt(u64, h[1..9], .big);
        const len = std.mem.readInt(u32, h[9..13], .big);
        if (len > 16 * 1024 * 1024) return error.FrameTooLarge;
        const bytes = try self.alloc.alloc(u8, len);
        defer self.alloc.free(bytes);
        try self.readExact(bytes);
        switch (h[0]) {
            'T' => {
                if (bytes.len > 8192) return error.InvalidMetadata;
                const Status = struct {
                    state: enum { connecting, reconnecting, attention },
                    attempt: u32,
                    retry_in_ms: ?u64 = null,
                    message: ?[]const u8 = null,
                };
                const status = try std.json.parseFromSlice(Status, self.alloc, bytes, .{ .ignore_unknown_fields = true });
                defer status.deinit();
                self.ready.store(false, .release);
                self.generation.store(seq, .release);
                sequence = null;
                try self.publishState(io, bytes);
            },
            'J' => {
                const Metadata = struct { version: u32 };
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{ .ignore_unknown_fields = true });
                defer metadata.deinit();
                if (metadata.value.version != 1) return error.UnsupportedProtocol;
            },
            'S' => {
                self.ready.store(false, .release);
                try self.restore(io, bytes);
                attached.* = true;
                sequence = seq;
                var acknowledgement: [8]u8 = undefined;
                std.mem.writeInt(u64, &acknowledgement, self.generation.load(.acquire), .big);
                try self.send('A', seq, &acknowledgement);
                try self.send('W', self.generation.load(.acquire), &.{});
            },
            'O' => {
                const previous = sequence orelse return error.MissingSnapshot;
                if (seq != previous + len) return error.OutputGap;
                io.processOutput(bytes);
                sequence = seq;
            },
            'W' => {
                const generation = self.generation.load(.acquire);
                if (generation != 0 and seq != generation) continue;
                if (sequence == null) return error.MissingSnapshot;
                self.ready.store(true, .release);
                if (self.close_requested.load(.acquire)) {
                    try self.send('K', self.generation.load(.acquire), &.{});
                    continue;
                }
                var dimensions: [4]u8 = undefined;
                std.mem.writeInt(u32, &dimensions, self.requested_size.load(.acquire), .big);
                try self.send('R', self.generation.load(.acquire), &dimensions);
                try self.publishState(io, "{\"state\":\"ready\",\"attempt\":0}");
            },
            'R' => {
                if (bytes.len != 4) return error.InvalidResize;
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                try io.terminal.resize(self.alloc, .{ .cols = std.mem.readInt(u16, bytes[0..2], .big), .rows = std.mem.readInt(u16, bytes[2..4], .big) });
                try io.renderer_wakeup.notify();
            },
            'M' => {
                const Metadata = struct { cwd: ?[]const u8 = null };
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{});
                defer metadata.deinit();
                const path = metadata.value.cwd orelse "";
                if (path.len > 4096 or (path.len > 0 and path[0] != '/') or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidMetadata;
                const Message = @import("../../apprt.zig").surface.Message;
                const req = try Message.WriteReq.init(self.alloc, path);
                _ = io.surface_mailbox.push(.{ .pwd_change = req }, .{ .forever = {} });
            },
            'B' => {
                self.ready.store(false, .release);
                try self.publishState(io, "{\"state\":\"attention\",\"attempt\":0,\"message\":\"This session is attached in another terminal. It is available here as read-only.\"}");
            },
            'E' => {
                self.ready.store(false, .release);
                if (bytes.len > 8192 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidMetadata;
                // A connection failure must not overwrite the retained terminal.
                try self.publishFailure(io, bytes, true);
                sequence = null;
            },
            'X' => {
                const code = std.fmt.parseInt(i32, bytes, 10) catch -1;
                self.ready.store(false, .release);
                const metadata = try std.json.Stringify.valueAlloc(self.alloc, .{
                    .state = "exited",
                    .attempt = @as(u32, 0),
                    .exit_code = code,
                }, .{});
                defer self.alloc.free(metadata);
                try self.publishState(io, metadata);
                _ = io.surface_mailbox.push(.{ .child_exited = .{
                    .exit_code = if (code < 0) 1 else @intCast(code),
                    .runtime_ms = 1,
                } }, .{ .forever = {} });
                return;
            },
            else => return error.InvalidFrame,
        }
    }
}

fn reattachRequest(alloc: std.mem.Allocator, original: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, original, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRequest;
    const create = parsed.value.object.getPtr("create") orelse return error.InvalidOpenRequest;
    create.* = .{ .bool = false };
    return std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
}

test "session relay restart only reattaches the confirmed UUID" {
    const alloc = std.testing.allocator;
    const request = try reattachRequest(alloc, "{\"id\":\"same-pane\",\"create\":true,\"cwd\":\"/tmp\"}");
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("same-pane", parsed.value.object.get("id").?.string);
    try std.testing.expect(!parsed.value.object.get("create").?.bool);
    // Legacy handshakes cannot safely infer attach-only semantics.
    try std.testing.expectError(error.SyntaxError, reattachRequest(alloc, "old-pane"));
}

test "session input generation rejects delayed writes after recovery" {
    var backend = try Self.init(std.testing.allocator, "/unused", null);
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    backend.generation.store(3, .release);
    backend.ready.store(true, .release);
    try std.testing.expectError(error.SessionNotReady, backend.queueWriteGeneration(2, "old"));
    try backend.queueWriteGeneration(3, "x");
    var frame: [14]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 14), c.read(sockets[1], &frame, frame.len));
    try std.testing.expectEqual(@as(u8, 'I'), frame[0]);
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, frame[1..9], .big));
    try std.testing.expectEqual(@as(u8, 'x'), frame[13]);
    backend.ready.store(false, .release);
    try std.testing.expect(backend.inputGeneration() == null);
    try std.testing.expectError(error.SessionNotReady, backend.queueWriteGeneration(3, "offline"));
}
fn restore(self: *Self, io: *HostIO, bytes: []const u8) !void {
    var input: std.Io.Reader = .fixed(bytes);
    var decoded = try terminal.snapshot.decodeExact(self.alloc, global.io(), &input, .{ .max_continuation_bytes = 1024 * 1024 });
    defer decoded.deinit(self.alloc);
    io.renderer_state.mutex.lockUncancelable(global.io());
    defer io.renderer_state.mutex.unlock(global.io());
    var handler = io.terminal_stream.handler;
    // Reset parser-owned allocations while retaining host routing pointers.
    handler.apc = .{};
    handler.dcs = .{};
    if (comptime @TypeOf(handler).tmux_enabled) handler.tmux_viewer = null;
    handler.termio_messaged = false;
    @import("SnapshotPresentation.zig").prepare(&io.terminal, &decoded.terminal.?);
    io.terminal_stream.deinit();
    io.terminal.deinit(self.alloc);
    io.terminal = decoded.toOwned();
    io.renderer_state.terminal_generation +%= 1;
    io.renderer_state.scroll = .{};
    io.renderer_state.visual_offset_y.store(0, .monotonic);
    io.terminal_stream = .init(.{ .allocator = self.alloc, .handler = handler });
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |continuation| io.terminal_stream.nextSlice(continuation),
    }
    try io.renderer_wakeup.notify();
}
