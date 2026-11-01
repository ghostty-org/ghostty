//! Native daemon transport. The relay owns reconnection; the surface stays alive.
const Self = @This();
const std = @import("std");
const global = @import("../../global.zig");
const HostIO = @import("../../omg_session_host.zig").HostIO;
const terminal = @import("../../terminal/main.zig");
const renderer = @import("../../renderer.zig");
const apprt = @import("../../apprt.zig");
const ProcessInfo = @import("../../pty.zig").ProcessInfo;
const LocalLaunch = @import("LocalLaunch.zig");
const connect_wait_budget_us: u64 = 60_000_000;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("sys/time.h");
    @cInclude("errno.h");
});
const max_pre_ready_input = 64 * 1024;
alloc: std.mem.Allocator,
path: [:0]u8,
pane_id: ?[]u8 = null,
is_local: bool = false,
creating: bool = false,
initial_cwd: ?[]u8 = null,
initial_input: std.ArrayList(u8) = .empty,
startup_input: std.ArrayList(u8) = .empty,
startup_input_enabled: std.atomic.Value(bool) = .init(false),
first_generation: std.atomic.Value(u64) = .init(0),
foreground_pid: std.atomic.Value(u64) = .init(0),
tty_name: std.atomic.Value(usize) = .init(0),
tty_names: std.ArrayList([:0]u8) = .empty,
protocol_version: std.atomic.Value(u32) = .init(1),
runtime_ms: u64 = 1,
password_input: bool = false,
fd: c_int = -1,
write_mutex: std.Io.Mutex = .init,
ready: std.atomic.Value(bool) = .init(false),
generation: std.atomic.Value(u64) = .init(0),
stopping: std.atomic.Value(bool) = .init(false),
close_requested: std.atomic.Value(bool) = .init(false),
attachment_enabled: std.atomic.Value(bool) = .init(true),
attachment_epoch: std.atomic.Value(u64) = .init(1),
force_attach: std.atomic.Value(bool) = .init(false),
attachment_changed: std.Io.Condition = .init,
requested_size: std.atomic.Value(u32) = .init((80 << 16) | 24),
requested_pixels: std.atomic.Value(u32) = .init((640 << 16) | 384),

pub const Options = struct {
    is_local: bool = false,
    working_directory: ?[]const u8 = null,
};

pub fn init(alloc: std.mem.Allocator, path: []const u8, pane_id: ?[]const u8, options: Options) !Self {
    const owned_path = try alloc.dupeZ(u8, path);
    errdefer alloc.free(owned_path);
    const owned_id = if (pane_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (owned_id) |id| alloc.free(id);
    const creating = LocalLaunch.createsSession(alloc, pane_id);
    return .{
        .alloc = alloc,
        .path = owned_path,
        .pane_id = owned_id,
        .is_local = options.is_local,
        .creating = creating,
        .startup_input_enabled = .init(options.is_local and creating),
        .initial_cwd = if (options.working_directory) |cwd| try alloc.dupe(u8, cwd) else null,
    };
}
pub fn deinit(self: *Self) void {
    self.alloc.free(self.path);
    if (self.pane_id) |id| {
        std.crypto.secureZero(u8, id);
        self.alloc.free(id);
    }
    if (self.initial_cwd) |cwd| self.alloc.free(cwd);
    std.crypto.secureZero(u8, self.initial_input.items);
    self.initial_input.deinit(self.alloc);
    self.clearStartupInput();
    self.startup_input.deinit(self.alloc);
    for (self.tty_names.items) |name| self.alloc.free(name);
    self.tty_names.deinit(self.alloc);
}
pub fn initTerminal(self: *Self, term: *terminal.Terminal) void {
    if (self.initial_cwd) |cwd| term.setPwd(cwd) catch {};
}
pub fn acceptsInitialInput(self: *const Self) bool {
    return self.is_local and self.creating;
}
pub fn appendInitialInput(self: *Self, bytes: []const u8) !void {
    if (!self.acceptsInitialInput()) return;
    if (bytes.len > LocalLaunch.max_initial_input -| self.initial_input.items.len) return error.InitialInputTooLarge;
    try self.initial_input.appendSlice(self.alloc, bytes);
}
pub const ThreadData = struct {
    thread: std.Thread,
    pub fn deinit(_: *ThreadData, _: std.mem.Allocator) void {}
};
pub fn threadEnter(self: *Self, _: std.mem.Allocator, io: *HostIO, td: *HostIO.ThreadData) !void {
    const address: c.struct_sockaddr_un = undefined;
    if (self.path.len >= address.sun_path.len) return error.SocketPathTooLong;
    const grid = io.size.grid();
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    self.requested_pixels.store(packedPixels(io.size.terminal()), .release);
    td.backend = .{ .omg_session = .{ .thread = try std.Thread.spawn(.{}, reader, .{ self, io }) } };
}
fn openSocket(self: *Self) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire)) return error.Disconnected;
    if (!self.attachment_enabled.load(.acquire) or self.close_requested.load(.acquire)) return error.SessionPaused;
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
    self.disableStartupInputLocked();
    self.clearProcessInfo();
    if (self.fd >= 0) {
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
        _ = c.close(self.fd);
        self.fd = -1;
    }
}

/// Pause transport I/O while retaining the server-side session and this Surface.
pub fn setSessionAttached(self: *Self, attached: bool) bool {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());

    if (self.stopping.load(.acquire)) return false;
    if (attached) {
        if (self.close_requested.load(.acquire)) return false;
        if (!self.attachment_enabled.load(.acquire)) {
            self.attachment_enabled.store(true, .release);
            self.attachment_changed.broadcast(global.io());
        }
        return true;
    }

    if (!self.attachment_enabled.load(.acquire)) return true;
    self.attachment_enabled.store(false, .release);
    _ = self.attachment_epoch.fetchAdd(1, .acq_rel);
    self.force_attach.store(true, .release);
    self.ready.store(false, .release);
    self.disableStartupInputLocked();
    self.clearProcessInfo();
    if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
    self.attachment_changed.broadcast(global.io());
    return true;
}

fn attachmentIsCurrent(self: *Self, epoch: u64) bool {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    return self.attachment_enabled.load(.acquire) and
        !self.stopping.load(.acquire) and
        self.attachment_epoch.load(.acquire) == epoch;
}

fn waitForAttachment(self: *Self) bool {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());

    while (!self.stopping.load(.acquire) and
        !self.close_requested.load(.acquire) and
        !self.attachment_enabled.load(.acquire))
    {
        self.attachment_changed.waitUncancelable(global.io(), &self.write_mutex);
    }
    return !self.stopping.load(.acquire) and !self.close_requested.load(.acquire);
}

pub fn threadExit(self: *Self, td: *HostIO.ThreadData) void {
    self.write_mutex.lockUncancelable(global.io());
    self.stopping.store(true, .release);
    self.disableStartupInputLocked();
    if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
    self.attachment_changed.broadcast(global.io());
    self.write_mutex.unlock(global.io());
    td.backend.omg_session.thread.join();
}
pub fn closeSession(self: *Self) void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    self.close_requested.store(true, .release);
    const was_ready = self.ready.load(.acquire);
    const generation = self.generation.load(.acquire);
    self.ready.store(false, .release);
    self.disableStartupInputLocked();
    if (was_ready) self.sendFrameLocked('K', generation, &.{}) catch {};
    self.attachment_changed.broadcast(global.io());
}
pub fn focusGained(_: *Self, _: *HostIO.ThreadData, _: bool) !void {}
pub fn resize(self: *Self, grid: renderer.GridSize, screen: renderer.ScreenSize) !void {
    self.requested_size.store((@as(u32, grid.columns) << 16) | grid.rows, .release);
    self.requested_pixels.store(packedPixels(screen), .release);
    if (!self.ready.load(.acquire)) return;
    try self.sendDimensions();
}

fn sendDimensions(self: *Self) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], self.requested_size.load(.acquire), .big);
    std.mem.writeInt(u32, bytes[4..8], self.requested_pixels.load(.acquire), .big);
    const length: usize = if (self.protocol_version.load(.acquire) >= 2) 8 else 4;
    try self.send('R', self.generation.load(.acquire), bytes[0..length]);
}
pub fn queueWrite(self: *Self, _: std.mem.Allocator, _: *HostIO.ThreadData, data: []const u8, linefeed: bool) !void {
    const generation = self.inputGeneration() orelse return error.SessionNotReady;
    try self.queueWriteGeneration(generation, data, linefeed);
}
pub fn inputGeneration(self: *Self) ?u64 {
    if (self.stopping.load(.acquire) or !self.attachment_enabled.load(.acquire)) return null;
    const generation = self.generation.load(.acquire);
    if (self.ready.load(.acquire) and generation != 0) return generation;
    if (self.startup_input_enabled.load(.acquire)) return 0;
    return null;
}
pub fn queueWriteGeneration(self: *Self, generation: u64, data: []const u8, linefeed: bool) !void {
    if (data.len == 0) return;
    const extra = if (linefeed) std.mem.count(u8, data, "\r") else 0;
    const payload_len = std.math.add(usize, data.len, extra) catch std.math.maxInt(usize);
    if (generation == 0 and payload_len > max_pre_ready_input) {
        self.write_mutex.lockUncancelable(global.io());
        defer self.write_mutex.unlock(global.io());
        const first = self.first_generation.load(.acquire);
        if (first == 0 and self.startup_input_enabled.load(.acquire)) {
            self.disableStartupInputLocked();
            return error.InitialInputTooLarge;
        }
        if (!self.ready.load(.acquire) or first == 0 or first != self.generation.load(.acquire)) {
            return error.SessionNotReady;
        }
    }
    var converted: ?[]u8 = null;
    defer if (converted) |bytes| self.alloc.free(bytes);
    var payload = data;
    if (extra > 0) {
        converted = self.alloc.alloc(u8, payload_len) catch |err| {
            if (generation == 0) self.discardUncommittedStartupInput();
            return err;
        };
        var offset: usize = 0;
        for (data) |byte| {
            converted.?[offset] = byte;
            offset += 1;
            if (byte == '\r') {
                converted.?[offset] = '\n';
                offset += 1;
            }
        }
        payload = converted.?;
    }

    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire) or !self.attachment_enabled.load(.acquire)) return error.SessionNotReady;

    if (generation == 0) {
        const first = self.first_generation.load(.acquire);
        if (self.ready.load(.acquire) and first != 0 and first == self.generation.load(.acquire)) {
            return self.sendFrameLocked('I', first, payload);
        }
        if (first == 0 and self.startup_input_enabled.load(.acquire)) {
            if (payload.len > max_pre_ready_input -| self.startup_input.items.len) {
                self.disableStartupInputLocked();
                return error.InitialInputTooLarge;
            }
            self.startup_input.appendSlice(self.alloc, payload) catch |err| {
                self.disableStartupInputLocked();
                return err;
            };
            return;
        }
        return error.SessionNotReady;
    }

    if (!self.ready.load(.acquire) or generation != self.generation.load(.acquire)) {
        return error.SessionNotReady;
    }
    try self.sendFrameLocked('I', generation, payload);
}
pub fn getProcessInfo(self: *Self, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (!self.is_local or
        !self.attachment_enabled.load(.acquire) or
        !self.ready.load(.acquire)) return null;
    return switch (info) {
        .foreground_pid => pid: {
            const value = self.foreground_pid.load(.acquire);
            break :pid if (value > 1) value else null;
        },
        .tty_name => tty: {
            const pointer = self.tty_name.load(.acquire);
            break :tty if (pointer == 0) null else std.mem.span(@as([*:0]const u8, @ptrFromInt(pointer)));
        },
    };
}

fn packedPixels(screen: renderer.ScreenSize) u32 {
    return (@as(u32, @min(screen.width, std.math.maxInt(u16))) << 16) | @min(screen.height, std.math.maxInt(u16));
}

fn clearProcessInfo(self: *Self) void {
    self.foreground_pid.store(0, .release);
    self.tty_name.store(0, .release);
}

fn clearStartupInput(self: *Self) void {
    std.crypto.secureZero(u8, self.startup_input.items);
    self.startup_input.clearAndFree(self.alloc);
}

fn disableStartupInputLocked(self: *Self) void {
    self.startup_input_enabled.store(false, .release);
    self.first_generation.store(0, .release);
    self.clearStartupInput();
}

fn invalidateStartupInput(self: *Self) void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    self.ready.store(false, .release);
    self.disableStartupInputLocked();
}

fn discardUncommittedStartupInput(self: *Self) void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.first_generation.load(.acquire) == 0 and self.startup_input_enabled.load(.acquire)) {
        self.disableStartupInputLocked();
    }
}

fn updateStatusGeneration(self: *Self, generation: u64, expected_epoch: ?u64) !void {
    if (generation == 0) return error.InvalidMetadata;
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire)) return error.Disconnected;
    if (!self.attachment_enabled.load(.acquire)) return error.SessionPaused;
    if (expected_epoch) |epoch| {
        if (self.attachment_epoch.load(.acquire) != epoch) return error.SessionPaused;
    }
    const previous = self.generation.load(.acquire);
    if (previous != 0 and previous != generation) self.disableStartupInputLocked();
    self.ready.store(false, .release);
    self.generation.store(generation, .release);
}

fn activateWriter(self: *Self, generation: u64, expected_epoch: ?u64) !bool {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire)) return error.Disconnected;
    if (!self.attachment_enabled.load(.acquire)) return error.SessionPaused;
    if (expected_epoch) |epoch| {
        if (self.attachment_epoch.load(.acquire) != epoch) return error.SessionPaused;
    }
    const previous = self.generation.load(.acquire);
    if (generation == 0 or (previous != 0 and previous != generation)) return error.StaleGeneration;
    if (previous == 0) self.generation.store(generation, .release);

    if (self.close_requested.load(.acquire)) {
        self.ready.store(false, .release);
        self.disableStartupInputLocked();
        try self.sendFrameLocked('K', generation, &.{});
        return false;
    }
    if (self.startup_input_enabled.load(.acquire) and self.first_generation.load(.acquire) == 0) {
        self.first_generation.store(generation, .release);
        if (self.startup_input.items.len > 0) {
            try self.sendFrameLocked('I', generation, self.startup_input.items);
        }
        self.clearStartupInput();
    }
    self.ready.store(true, .release);
    return true;
}

const ProcessMetadata = struct {
    foreground_pid: ?u64 = null,
    tty_name: ?[]const u8 = null,
};

fn updateProcessInfo(self: *Self, value: ProcessMetadata) !void {
    if (!self.is_local) return;
    self.foreground_pid.store(if (value.foreground_pid) |pid|
        if (pid > 1 and pid <= std.math.maxInt(i32)) pid else 0
    else
        0, .release);
    const name = value.tty_name orelse {
        self.tty_name.store(0, .release);
        return;
    };
    if (!std.mem.startsWith(u8, name, "/dev/") or name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidMetadata;
    for (self.tty_names.items) |saved| {
        if (std.mem.eql(u8, name, saved)) {
            self.tty_name.store(@intFromPtr(saved.ptr), .release);
            return;
        }
    }
    if (self.tty_names.items.len >= 64) return error.InvalidMetadata;
    const saved = try self.alloc.dupeZ(u8, name);
    errdefer self.alloc.free(saved);
    try self.tty_names.append(self.alloc, saved);
    self.tty_name.store(@intFromPtr(saved.ptr), .release);
}

fn updateProcessInfoForEpoch(self: *Self, value: ProcessMetadata, epoch: u64) !bool {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (!self.attachment_enabled.load(.acquire) or
        self.attachment_epoch.load(.acquire) != epoch or
        self.stopping.load(.acquire))
    {
        return false;
    }
    try self.updateProcessInfo(value);
    return true;
}

fn confirmCreation(self: *Self) !void {
    if (!self.creating) return;
    if (self.pane_id) |id| {
        const compact = try LocalLaunch.attachOnly(self.alloc, id);
        std.crypto.secureZero(u8, id);
        self.alloc.free(id);
        self.pane_id = compact;
    }
    std.crypto.secureZero(u8, self.initial_input.items);
    self.initial_input.clearAndFree(self.alloc);
    self.creating = false;
}

fn updatePasswordInput(self: *Self, io: *HostIO, value: bool) void {
    if (self.password_input == value) return;
    self.password_input = value;
    _ = self.publishSurface(io, .{ .password_input = value });
}

fn updatePasswordInputForEpoch(self: *Self, io: *HostIO, value: bool, epoch: u64) void {
    self.write_mutex.lockUncancelable(global.io());
    if (!self.attachment_enabled.load(.acquire) or
        self.attachment_epoch.load(.acquire) != epoch or
        self.stopping.load(.acquire))
    {
        self.write_mutex.unlock(global.io());
        return;
    }
    const changed = self.password_input != value;
    self.password_input = value;
    self.write_mutex.unlock(global.io());
    if (changed) _ = self.publishSurface(io, .{ .password_input = value });
}

fn publishSurface(self: *Self, io: *HostIO, message: apprt.surface.Message) bool {
    return publishUntilStopped(&self.stopping, io.surface_mailbox, message);
}

fn publishUntilStopped(stopping: *std.atomic.Value(bool), mailbox: anytype, message: apprt.surface.Message) bool {
    // Surface destruction joins this reader on the app thread. A full app
    // mailbox must not keep the reader waiting for that same thread forever.
    while (!stopping.load(.acquire)) {
        if (mailbox.push(message, .{ .ns = 50 * std.time.ns_per_ms }) != 0) return true;
    }
    return false;
}
fn send(self: *Self, kind: u8, seq: u64, data: []const u8) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire) or !self.attachment_enabled.load(.acquire) or
        self.close_requested.load(.acquire)) return error.SessionPaused;
    if ((kind == 'I' or kind == 'R') and
        (!self.ready.load(.acquire) or seq != self.generation.load(.acquire))) return error.SessionNotReady;
    try self.sendFrameLocked(kind, seq, data);
}

fn sendForAttachment(self: *Self, kind: u8, seq: u64, data: []const u8, expected_epoch: u64) !void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.stopping.load(.acquire)) return error.Disconnected;
    if (!self.attachment_enabled.load(.acquire) or
        self.attachment_epoch.load(.acquire) != expected_epoch or
        self.close_requested.load(.acquire)) return error.SessionPaused;
    if ((kind == 'I' or kind == 'R') and
        (!self.ready.load(.acquire) or seq != self.generation.load(.acquire))) return error.SessionNotReady;
    try self.sendFrameLocked(kind, seq, data);
}

/// Caller owns write_mutex. The initial W path uses this before ready is set.
fn sendFrameLocked(self: *Self, kind: u8, seq: u64, data: []const u8) !void {
    if (self.fd < 0) return error.Disconnected;
    if (data.len > std.math.maxInt(u32)) return error.FrameTooLarge;
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
    var connected_once = false;
    var retry_delay_us: u32 = 100_000;
    while (self.waitForAttachment()) {
        const epoch = self.attachment_epoch.load(.acquire);
        self.openSocket() catch {
            if (self.close_requested.load(.acquire)) return;
            if (!self.attachmentIsCurrent(epoch)) continue;
            self.publishFailure(io, "Could not open the local runtime connection. The session process is preserved.", false) catch {};
            return;
        };
        self.readLoop(io, epoch, &attached, &connected_once) catch |err| {
            self.closeSocket();
            if (self.stopping.load(.acquire)) return;
            if (self.close_requested.load(.acquire)) return;
            if (!self.attachmentIsCurrent(epoch)) continue;
            if (err == error.SessionPaused) continue;
            if (connected_once) {
                retry_delay_us = 100_000;
                connected_once = false;
            }
            self.updatePasswordInputForEpoch(io, false, epoch);
            std.log.warn("OMG session disconnected: {s}", .{@errorName(err)});
            const recoverable = err == error.Disconnected or err == error.ConnectFailed or err == error.OutputGap;
            self.publishFailure(io, if (recoverable)
                "The session connection ended. Retry to reconnect to the existing session."
            else
                "The terminal protocol could not be restored. The session process is preserved; use a compatible app.", recoverable) catch {};
            // The GUI may restart a failed relay at the same socket path.
            // Keep this Surface and its last frame while waiting for it.
            if (recoverable) {
                switch (self.waitForReconnect(retry_delay_us, epoch)) {
                    .elapsed => {},
                    .paused => continue,
                    .stopped => return,
                }
                retry_delay_us = nextReconnectDelay(retry_delay_us);
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
    if (!self.publishSurface(io, .{ .context_signal = signal })) signal.deinit();
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

const ReconnectWait = enum { elapsed, paused, stopped };

fn waitForReconnect(self: *Self, delay_us: u32, expected_epoch: u64) ReconnectWait {
    var remaining = delay_us;
    while (remaining > 0) {
        self.write_mutex.lockUncancelable(global.io());
        if (self.stopping.load(.acquire) or self.close_requested.load(.acquire)) {
            self.write_mutex.unlock(global.io());
            return .stopped;
        }
        if (!self.attachment_enabled.load(.acquire)) {
            self.write_mutex.unlock(global.io());
            return .paused;
        }
        const interval = @min(remaining, 100_000);
        _ = @import("../../lib/compat/thread.zig").waitTimeout(
            &self.attachment_changed,
            global.io(),
            &self.write_mutex,
            .{ .duration = .{
                .raw = .fromNanoseconds(@as(i96, interval) * std.time.ns_per_us),
                .clock = .awake,
            } },
        ) catch {};
        const stopping = self.stopping.load(.acquire) or self.close_requested.load(.acquire);
        const paused = !self.attachment_enabled.load(.acquire);
        const changed = self.attachment_epoch.load(.acquire) != expected_epoch;
        self.write_mutex.unlock(global.io());
        if (stopping) return .stopped;
        if (paused or changed) return .paused;
        remaining -= interval;
    }
    return .elapsed;
}

fn nextReconnectDelay(delay_us: u32) u32 {
    return @min(delay_us * 2, 2_000_000);
}

fn readLoop(self: *Self, io: *HostIO, epoch: u64, attached: *bool, connected_once: *bool) !void {
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..self.path.len], self.path);
    // Deployment may upload the runtime before publishing the local socket.
    // This runs on the dedicated reader, never the AppKit thread.
    var retry_delay_us: u32 = 100_000;
    var waited_us: u64 = 0;
    while (c.connect(self.fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        if (!self.attachmentIsCurrent(epoch)) return error.SessionPaused;
        if (waited_us >= connect_wait_budget_us) return error.ConnectFailed;
        const remaining_budget = connect_wait_budget_us - waited_us;
        const wait_us: u32 = @intCast(@min(@as(u64, retry_delay_us), remaining_budget));
        switch (self.waitForReconnect(wait_us, epoch)) {
            .elapsed => {},
            .paused => return error.SessionPaused,
            .stopped => return error.Disconnected,
        }
        waited_us += wait_us;
        retry_delay_us = nextReconnectDelay(retry_delay_us);
    }
    if (!self.attachmentIsCurrent(epoch)) return error.SessionPaused;
    if (self.pane_id) |id| {
        if (attached.* or self.force_attach.load(.acquire)) {
            const request = try reattachRequest(self.alloc, id);
            defer self.alloc.free(request);
            try self.sendForAttachment('H', 0, request, epoch);
        } else if (self.acceptsInitialInput()) {
            const request = try LocalLaunch.withInitialInput(self.alloc, id, self.initial_input.items, self.requested_size.load(.acquire), self.requested_pixels.load(.acquire));
            defer {
                std.crypto.secureZero(u8, request);
                self.alloc.free(request);
            }
            try self.sendForAttachment('H', 0, request, epoch);
        } else {
            try self.sendForAttachment('H', 0, id, epoch);
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
        if (!self.attachmentIsCurrent(epoch)) return error.SessionPaused;
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
                try self.updateStatusGeneration(seq, epoch);
                self.clearProcessInfo();
                self.updatePasswordInputForEpoch(io, false, epoch);
                sequence = null;
                try self.publishState(io, bytes);
            },
            'J' => {
                const Metadata = struct {
                    version: u32,
                    foreground_pid: ?u64 = null,
                    tty_name: ?[]const u8 = null,
                    password_input: bool = false,
                    runtime_ms: ?u64 = null,
                };
                if (bytes.len > 16 * 1024) return error.InvalidMetadata;
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{ .ignore_unknown_fields = true });
                defer metadata.deinit();
                if (metadata.value.version != 1 and metadata.value.version != 2) return error.UnsupportedProtocol;
                self.protocol_version.store(metadata.value.version, .release);
                self.runtime_ms = metadata.value.runtime_ms orelse 1;
                self.updatePasswordInputForEpoch(io, metadata.value.password_input, epoch);
                if (!try self.updateProcessInfoForEpoch(.{
                    .foreground_pid = metadata.value.foreground_pid,
                    .tty_name = metadata.value.tty_name,
                }, epoch)) return error.SessionPaused;
            },
            'S' => {
                self.ready.store(false, .release);
                try self.restore(io, bytes);
                attached.* = true;
                try self.confirmCreation();
                sequence = seq;
                var acknowledgement: [8]u8 = undefined;
                std.mem.writeInt(u64, &acknowledgement, self.generation.load(.acquire), .big);
                try self.sendForAttachment('A', seq, &acknowledgement, epoch);
                try self.sendForAttachment('W', self.generation.load(.acquire), &.{}, epoch);
            },
            'O' => {
                const previous = sequence orelse return error.MissingSnapshot;
                if (seq != previous + len) return error.OutputGap;
                io.processOutput(bytes);
                sequence = seq;
            },
            'W' => {
                const generation = self.generation.load(.acquire);
                if (generation != 0 and seq != generation) {
                    self.invalidateStartupInput();
                    continue;
                }
                if (sequence == null) return error.MissingSnapshot;
                if (!try self.activateWriter(seq, epoch)) continue;
                connected_once.* = true;
                try self.sendDimensions();
                try self.publishState(io, "{\"state\":\"ready\",\"attempt\":0}");
            },
            'R' => {
                if (bytes.len != 4 and bytes.len != 8) return error.InvalidResize;
                io.renderer_state.mutex.lockUncancelable(global.io());
                defer io.renderer_state.mutex.unlock(global.io());
                try io.terminal.resize(self.alloc, .{ .cols = std.mem.readInt(u16, bytes[0..2], .big), .rows = std.mem.readInt(u16, bytes[2..4], .big) });
                if (bytes.len == 8) {
                    io.terminal.width_px = std.mem.readInt(u16, bytes[4..6], .big);
                    io.terminal.height_px = std.mem.readInt(u16, bytes[6..8], .big);
                }
                try io.renderer_wakeup.notify();
            },
            'M' => {
                const Metadata = struct {
                    cwd: ?[]const u8 = null,
                    foreground_pid: ?u64 = null,
                    tty_name: ?[]const u8 = null,
                    password_input: bool = false,
                    runtime_ms: ?u64 = null,
                };
                if (bytes.len > 16 * 1024) return error.InvalidMetadata;
                const metadata = try std.json.parseFromSlice(Metadata, self.alloc, bytes, .{ .ignore_unknown_fields = true });
                defer metadata.deinit();
                const path = metadata.value.cwd orelse "";
                if (path.len > 4096 or (path.len > 0 and path[0] != '/') or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidMetadata;
                self.runtime_ms = metadata.value.runtime_ms orelse self.runtime_ms;
                self.updatePasswordInputForEpoch(io, metadata.value.password_input, epoch);
                if (!try self.updateProcessInfoForEpoch(.{
                    .foreground_pid = metadata.value.foreground_pid,
                    .tty_name = metadata.value.tty_name,
                }, epoch)) return error.SessionPaused;
                {
                    // Seed native inheritance for commands without OSC 7.
                    // Process sampling must not overwrite shell-reported cwd.
                    io.renderer_state.mutex.lockUncancelable(global.io());
                    defer io.renderer_state.mutex.unlock(global.io());
                    if (io.terminal.getPwd() == null and path.len > 0) {
                        try io.terminal.setPwd(path);
                    }
                }
                const Message = @import("../../apprt.zig").surface.Message;
                const req = try Message.WriteReq.init(self.alloc, path);
                if (!self.publishSurface(io, .{ .pwd_change = req })) req.deinit();
            },
            'B' => {
                self.invalidateStartupInput();
                try self.publishState(io, "{\"state\":\"attention\",\"attempt\":0,\"message\":\"This session is attached in another terminal. It is available here as read-only.\"}");
            },
            'E' => {
                self.invalidateStartupInput();
                self.clearProcessInfo();
                self.updatePasswordInput(io, false);
                if (bytes.len > 8192 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidMetadata;
                // A connection failure must not overwrite the retained terminal.
                try self.publishFailure(io, bytes, true);
                sequence = null;
            },
            'X' => {
                const code = std.fmt.parseInt(i32, bytes, 10) catch -1;
                self.invalidateStartupInput();
                self.clearProcessInfo();
                self.updatePasswordInput(io, false);
                const metadata = try std.json.Stringify.valueAlloc(self.alloc, .{
                    .state = "exited",
                    .attempt = @as(u32, 0),
                    .exit_code = code,
                }, .{});
                defer self.alloc.free(metadata);
                try self.publishState(io, metadata);
                _ = self.publishSurface(io, .{ .child_exited = .{
                    .exit_code = if (code < 0) 1 else @intCast(code),
                    .runtime_ms = self.runtime_ms,
                } });
                return;
            },
            else => return error.InvalidFrame,
        }
    }
}

fn reattachRequest(alloc: std.mem.Allocator, original: []const u8) ![]u8 {
    return LocalLaunch.attachOnly(alloc, original);
}

fn readTestBytes(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) return error.TestReadFailed;
        offset += @intCast(n);
    }
}

test "session relay restart only reattaches the confirmed UUID" {
    const alloc = std.testing.allocator;
    const request = try reattachRequest(alloc, "{\"id\":\"same-pane\",\"policy\":{},\"create\":true,\"cwd\":\"/tmp\"}");
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("same-pane", parsed.value.object.get("id").?.string);
    try std.testing.expect(!parsed.value.object.get("create").?.bool);
    // Legacy handshakes cannot safely infer attach-only semantics.
    try std.testing.expectError(error.SyntaxError, reattachRequest(alloc, "old-pane"));
}

test "session reconnect backoff is capped at two seconds" {
    var delay: u32 = 100_000;
    delay = nextReconnectDelay(delay);
    try std.testing.expectEqual(@as(u32, 200_000), delay);
    delay = nextReconnectDelay(delay);
    try std.testing.expectEqual(@as(u32, 400_000), delay);
    while (delay < 2_000_000) delay = nextReconnectDelay(delay);
    try std.testing.expectEqual(@as(u32, 2_000_000), nextReconnectDelay(delay));
}

test "session input generation rejects delayed writes after recovery" {
    var backend = try Self.init(std.testing.allocator, "/unused", null, .{});
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    backend.generation.store(3, .release);
    backend.ready.store(true, .release);
    try std.testing.expectError(error.SessionNotReady, backend.queueWriteGeneration(2, "old", false));
    try backend.queueWriteGeneration(3, "x", false);
    var frame: [14]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 14), c.read(sockets[1], &frame, frame.len));
    try std.testing.expectEqual(@as(u8, 'I'), frame[0]);
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, frame[1..9], .big));
    try std.testing.expectEqual(@as(u8, 'x'), frame[13]);
    backend.ready.store(false, .release);
    try std.testing.expect(backend.inputGeneration() == null);
    try std.testing.expectError(error.SessionNotReady, backend.queueWriteGeneration(3, "offline", false));
}

test "detaching pauses writes and resumes only the same session attachment epoch" {
    var backend = try Self.init(std.testing.allocator, "/unused", null, .{ .is_local = true });
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    backend.generation.store(9, .release);
    backend.ready.store(true, .release);
    try backend.updateProcessInfo(.{ .foreground_pid = 123, .tty_name = "/dev/ttys123" });
    const previous_epoch = backend.attachment_epoch.load(.acquire);

    try std.testing.expect(backend.setSessionAttached(false));
    try std.testing.expect(!backend.attachment_enabled.load(.acquire));
    try std.testing.expect(!backend.ready.load(.acquire));
    try std.testing.expect(backend.force_attach.load(.acquire));
    try std.testing.expect(backend.inputGeneration() == null);
    try std.testing.expect(backend.getProcessInfo(.foreground_pid) == null);
    try std.testing.expect(backend.getProcessInfo(.tty_name) == null);
    var eof_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(sockets[1], &eof_byte, eof_byte.len));

    try std.testing.expect(backend.setSessionAttached(true));
    try std.testing.expect(backend.attachment_enabled.load(.acquire));
    try std.testing.expectError(error.SessionPaused, backend.activateWriter(9, previous_epoch));
    try std.testing.expect(!backend.ready.load(.acquire));
}

test "an explicitly closed session cannot resume after detaching" {
    var backend = try Self.init(std.testing.allocator, "/unused", null, .{});
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    backend.generation.store(2, .release);
    backend.ready.store(true, .release);

    backend.closeSession();
    var close_frame: [13]u8 = undefined;
    try readTestBytes(sockets[1], &close_frame);
    try std.testing.expect(backend.setSessionAttached(false));
    try std.testing.expect(!backend.setSessionAttached(true));

    try std.testing.expect(backend.close_requested.load(.acquire));
    try std.testing.expect(!backend.attachment_enabled.load(.acquire));
}

test "fresh local input waits for the first writer and late tag zero maps once" {
    const alloc = std.testing.allocator;
    const create = "{\"id\":\"pane\",\"policy\":{},\"create\":true}";
    var backend = try Self.init(alloc, "/unused", create, .{ .is_local = true });
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    try backend.updateStatusGeneration(7, null);

    try std.testing.expectEqual(@as(?u64, 0), backend.inputGeneration());
    backend.write_mutex.lockUncancelable(global.io());
    backend.first_generation.store(7, .release);
    const during_flush = backend.inputGeneration();
    backend.first_generation.store(0, .release);
    backend.write_mutex.unlock(global.io());
    try std.testing.expectEqual(@as(?u64, 0), during_flush);
    try backend.queueWriteGeneration(0, "first\r", true);
    try backend.queueWriteGeneration(0, "second", false);
    try std.testing.expectEqualStrings("first\r\nsecond", backend.startup_input.items);
    try std.testing.expect(!backend.ready.load(.acquire));

    try std.testing.expect(try backend.activateWriter(7, null));
    try std.testing.expect(backend.ready.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), backend.startup_input.items.len);
    var initial: [26]u8 = undefined;
    try readTestBytes(sockets[1], &initial);
    try std.testing.expectEqual(@as(u8, 'I'), initial[0]);
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, initial[1..9], .big));
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, initial[9..13], .big));
    try std.testing.expectEqualStrings("first\r\nsecond", initial[13..]);

    // A write queued by Termio before W may be dispatched after W.
    try backend.queueWriteGeneration(0, "late", false);
    var delayed: [17]u8 = undefined;
    try readTestBytes(sockets[1], &delayed);
    try std.testing.expectEqual(@as(u8, 'I'), delayed[0]);
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, delayed[1..9], .big));
    try std.testing.expectEqualStrings("late", delayed[13..]);

    try backend.updateStatusGeneration(8, null);
    try std.testing.expect(backend.inputGeneration() == null);
    try std.testing.expectError(error.SessionNotReady, backend.queueWriteGeneration(0, "stale", false));
}

test "startup input overflow drops the entire pending command" {
    const create = "{\"id\":\"pane\",\"policy\":{},\"create\":true}";
    var backend = try Self.init(std.testing.allocator, "/unused", create, .{ .is_local = true });
    defer backend.deinit();
    try backend.updateStatusGeneration(3, null);
    try backend.queueWriteGeneration(0, "echo partial\n", false);
    var too_large: [max_pre_ready_input]u8 = undefined;
    @memset(&too_large, 'x');

    try std.testing.expectError(error.InitialInputTooLarge, backend.queueWriteGeneration(0, &too_large, false));
    try std.testing.expectEqual(@as(usize, 0), backend.startup_input.items.len);
    try std.testing.expect(!backend.startup_input_enabled.load(.acquire));
    try std.testing.expect(backend.inputGeneration() == null);
}

test "startup input is disabled by generation change and failed first writer" {
    const create = "{\"id\":\"pane\",\"policy\":{},\"create\":true}";
    var changed = try Self.init(std.testing.allocator, "/unused", create, .{ .is_local = true });
    defer changed.deinit();
    try changed.updateStatusGeneration(3, null);
    try changed.queueWriteGeneration(0, "echo once\n", false);
    try changed.updateStatusGeneration(4, null);
    try std.testing.expectEqual(@as(usize, 0), changed.startup_input.items.len);
    try std.testing.expect(!changed.startup_input_enabled.load(.acquire));
    try std.testing.expectError(error.SessionNotReady, changed.queueWriteGeneration(0, "stale\n", false));

    var failed = try Self.init(std.testing.allocator, "/unused", create, .{ .is_local = true });
    defer failed.deinit();
    try failed.queueWriteGeneration(0, "echo once\n", false);
    failed.invalidateStartupInput();
    try std.testing.expectEqual(@as(usize, 0), failed.startup_input.items.len);
    try std.testing.expect(!failed.startup_input_enabled.load(.acquire));
    try std.testing.expectError(error.SessionNotReady, failed.queueWriteGeneration(0, "stale\n", false));
}

test "closing before the first writer discards early input" {
    const create = "{\"id\":\"pane\",\"policy\":{},\"create\":true}";
    var backend = try Self.init(std.testing.allocator, "/unused", create, .{ .is_local = true });
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    try backend.updateStatusGeneration(5, null);
    try backend.queueWriteGeneration(0, "do not run\n", false);
    backend.closeSession();
    try std.testing.expect(!try backend.activateWriter(5, null));

    var close_frame: [13]u8 = undefined;
    try readTestBytes(sockets[1], &close_frame);
    try std.testing.expectEqual(@as(u8, 'K'), close_frame[0]);
    try std.testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, close_frame[1..9], .big));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, close_frame[9..13], .big));
    try std.testing.expectEqual(@as(usize, 0), backend.startup_input.items.len);
    try std.testing.expect(!backend.startup_input_enabled.load(.acquire));
    try std.testing.expect(!backend.ready.load(.acquire));
}

test "startup input is limited to a fresh local session" {
    const create = "{\"id\":\"pane\",\"policy\":{},\"create\":true}";
    const attach = "{\"id\":\"pane\",\"policy\":{},\"create\":false}";
    var remote = try Self.init(std.testing.allocator, "/unused", create, .{});
    defer remote.deinit();
    var local_attach = try Self.init(std.testing.allocator, "/unused", attach, .{ .is_local = true });
    defer local_attach.deinit();

    try std.testing.expect(remote.inputGeneration() == null);
    try std.testing.expect(local_attach.inputGeneration() == null);
}

test "local session process metadata cannot expose remote or disconnected process IDs" {
    const alloc = std.testing.allocator;
    var local = try Self.init(alloc, "/unused", null, .{ .is_local = true });
    defer local.deinit();
    var remote = try Self.init(alloc, "/unused", null, .{});
    defer remote.deinit();
    const metadata: ProcessMetadata = .{ .foreground_pid = 123, .tty_name = "/dev/ttys123" };
    try local.updateProcessInfo(metadata);
    local.ready.store(true, .release);
    try remote.updateProcessInfo(metadata);
    try std.testing.expectEqual(@as(?u64, 123), local.getProcessInfo(.foreground_pid));
    const original_tty = local.getProcessInfo(.tty_name).?;
    try std.testing.expectEqualStrings("/dev/ttys123", original_tty);
    try std.testing.expect(remote.getProcessInfo(.foreground_pid) == null);
    try std.testing.expect(remote.getProcessInfo(.tty_name) == null);
    try local.updateProcessInfo(.{ .foreground_pid = 456, .tty_name = "/dev/ttys456" });
    try std.testing.expectEqualStrings("/dev/ttys456", local.getProcessInfo(.tty_name).?);
    // Borrowed strings stay valid even after a later generation gets a new TTY.
    try std.testing.expectEqualStrings("/dev/ttys123", original_tty);
    local.clearProcessInfo();
    try std.testing.expect(local.getProcessInfo(.foreground_pid) == null);
    try std.testing.expect(local.getProcessInfo(.tty_name) == null);
}

test "session writes honor Ghostty linefeed mode" {
    var backend = try Self.init(std.testing.allocator, "/unused", null, .{ .is_local = true });
    defer backend.deinit();
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &sockets));
    defer _ = c.close(sockets[0]);
    defer _ = c.close(sockets[1]);
    backend.fd = sockets[0];
    backend.generation.store(3, .release);
    backend.ready.store(true, .release);
    try backend.queueWriteGeneration(3, "a\rb", true);
    var frame: [17]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 17), c.read(sockets[1], &frame, frame.len));
    try std.testing.expectEqualStrings("a\r\nb", frame[13..]);
}

test "local session confirms creation without retaining startup secrets" {
    const alloc = std.testing.allocator;
    var backend = try Self.init(alloc, "/unused", "{\"id\":\"pane\",\"policy\":{},\"create\":true,\"launch\":{\"env\":{\"SECRET\":\"value\"}}}", .{ .is_local = true });
    defer backend.deinit();
    try backend.appendInitialInput("echo one-time\n");
    try std.testing.expect(backend.acceptsInitialInput());
    try backend.confirmCreation();
    try std.testing.expect(!backend.acceptsInitialInput());
    try std.testing.expect(std.mem.indexOf(u8, backend.pane_id.?, "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, backend.pane_id.?, "launch") == null);
    try std.testing.expectEqual(@as(usize, 0), backend.initial_input.items.len);
}

test "local session shutdown interrupts a full app mailbox" {
    const Mailbox = struct {
        stopping: *std.atomic.Value(bool),
        attempts: usize = 0,
        fn push(self: *@This(), _: apprt.surface.Message, _: @import("../../App.zig").Mailbox.Queue.Timeout) u8 {
            self.attempts += 1;
            self.stopping.store(true, .release);
            return 0;
        }
    };
    var stopping: std.atomic.Value(bool) = .init(false);
    var mailbox: Mailbox = .{ .stopping = &stopping };
    try std.testing.expect(!publishUntilStopped(&stopping, &mailbox, .{ .password_input = false }));
    try std.testing.expectEqual(@as(usize, 1), mailbox.attempts);
    try std.testing.expect(!publishUntilStopped(&stopping, &mailbox, .{ .password_input = false }));
    try std.testing.expectEqual(@as(usize, 1), mailbox.attempts);
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
