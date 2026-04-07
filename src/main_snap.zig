///! ghostty-snap: Reconnectable terminal prototype
///!
///! Usage:
///!   ghostty-snap server [--name NAME] [-- command]   Start a named server session
///!   ghostty-snap attach [name | host:port]            Attach to a session interactively
///!   ghostty-snap list                                 List active sessions
///!   ghostty-snap capture [-- command]                 Snapshot on Ctrl-\ or exit
///!   ghostty-snap restore [file]                       Replay snapshot to stdout
const std = @import("std");
const posix = std.posix;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

const terminalpkg = @import("terminal/main.zig");
const Terminal = terminalpkg.Terminal;
const pty_pkg = @import("pty.zig");
const Pty = pty_pkg.Pty;

const STDERR = posix.STDERR_FILENO;
const STDOUT = posix.STDOUT_FILENO;
const STDIN = posix.STDIN_FILENO;

fn writeStderr(msg: []const u8) void {
    _ = posix.write(STDERR, msg) catch {};
}

fn stderrFmt(comptime fmt_str: []const u8, fmt_args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt_str, fmt_args) catch return;
    writeStderr(msg);
}

// ─── framing protocol ────────────────────────────────────────────────────────
//
// Wire format: [type: u8] [length: u24 big-endian] [payload: length bytes]
// 4-byte header + payload. Max message: 16MB.

const MsgType = enum(u8) {
    // Server → Client
    pty_data = 0x01,
    snapshot = 0x02,
    scrollback = 0x03,

    // Client → Server
    input = 0x81,
    resize = 0x82,

    _,
};

/// Result of attempting to write a frame.
const WriteFrameResult = enum {
    ok, // fully written
    would_block, // nothing written (EAGAIN before any bytes)
    partial, // partially written — remainder is in out_buf
    err, // connection error
};

/// Write a framed message. If only part of the frame can be written (short write),
/// the REMAINDER is queued into out_buf so the client always receives complete frames.
/// This prevents frame alignment corruption.
fn writeFrame(fd: posix.fd_t, msg_type: MsgType, payload: []const u8, out_buf: ?*OutputBuffer) WriteFrameResult {
    const len: u32 = @intCast(payload.len);
    const header = [4]u8{
        @intFromEnum(msg_type),
        @truncate(len >> 16),
        @truncate((len >> 8) & 0xff),
        @truncate(len & 0xff),
    };

    const total = 4 + payload.len;

    // Build the full frame
    var stack_buf: [8192]u8 = undefined;
    const frame = if (total <= 8192) blk: {
        @memcpy(stack_buf[0..4], &header);
        @memcpy(stack_buf[4..][0..payload.len], payload);
        break :blk stack_buf[0..total];
    } else blk: {
        const heap = std.heap.c_allocator.alloc(u8, total) catch return .err;
        @memcpy(heap[0..4], &header);
        @memcpy(heap[4..], payload);
        break :blk heap;
    };
    defer if (total > 8192) std.heap.c_allocator.free(frame);

    const written = posix.write(fd, frame) catch |err| {
        if (err == error.WouldBlock) return .would_block;
        return .err;
    };

    if (written == total) return .ok;

    // Short write — queue the unwritten remainder so the client
    // receives the complete frame. Without this, the client's frame
    // reader would wait forever for the missing bytes.
    if (out_buf) |buf| {
        const remainder = frame[written..];
        if (buf.data) |old| std.heap.c_allocator.free(old);
        const queued = std.heap.c_allocator.alloc(u8, remainder.len) catch return .err;
        @memcpy(queued, remainder);
        buf.data = queued;
        buf.offset = 0;
        return .partial;
    }

    return .partial;
}

/// Incremental frame reader. Accumulates bytes and yields complete messages.
const FrameReader = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,
    consumed: usize = 0,

    const Frame = struct {
        msg_type: MsgType,
        payload: []const u8,
    };

    /// Add raw bytes and return the next complete frame, if any.
    /// Caller must process one frame at a time (call repeatedly until null).
    fn feed(self: *FrameReader, data: []const u8) void {
        const space = self.buf.len - self.len;
        const to_copy = @min(data.len, space);
        @memcpy(self.buf[self.len..][0..to_copy], data[0..to_copy]);
        self.len += to_copy;
    }

    /// Returns the next complete frame. The payload slice is valid ONLY
    /// until the next call to feed() or next(). Caller must consume
    /// (e.g. write to STDOUT) before calling next() again.
    fn next(self: *FrameReader) ?Frame {
        if (self.len < 4) return null;
        const msg_len: usize = (@as(usize, self.buf[1]) << 16) |
            (@as(usize, self.buf[2]) << 8) |
            @as(usize, self.buf[3]);
        const total = 4 + msg_len;
        if (self.len < total) return null;

        const msg_type: MsgType = @enumFromInt(self.buf[0]);

        // Shift remaining data FIRST, then return the payload.
        // We must be careful: copyForwards copies left-to-right,
        // so if remaining data starts at buf[total], copying to buf[0]
        // won't overwrite the payload at buf[4..total] AS LONG AS
        // total > remaining. But if total <= remaining, there IS overlap.
        //
        // To avoid this entirely: shift the payload to the END of the
        // buffer (after the remaining data), then shift remaining down.
        // Actually, simplest correct approach: DON'T shift. Instead,
        // track an offset into the buffer and only compact on feed().
        //
        // For now: return payload pointing BEFORE the shift region.
        // The payload at buf[4..total] is NOT touched by copyForwards
        // because copyForwards copies from buf[total..] to buf[0..],
        // and the destination buf[0..remaining] only overlaps the
        // payload if remaining >= 4 (i.e. the copy writes past byte 3).
        //
        // If remaining < 4: no overlap, payload is safe.
        // If remaining >= 4: the copy overwrites buf[4..] which IS the payload.
        //
        // Fix: compact AFTER the caller is done with the payload.
        // We defer the compaction to the next call.

        // Instead: just don't shift. Track consumed offset.
        // This is simpler and avoids the overlap entirely.
        self.consumed = total;

        return .{
            .msg_type = msg_type,
            .payload = self.buf[4..total],
        };
    }

    /// Must be called after consuming a frame returned by next().
    /// Shifts the buffer to remove the consumed frame.
    fn advance(self: *FrameReader) void {
        const total = self.consumed;
        if (total == 0) return;
        const remaining = self.len - total;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[total..self.len]);
        }
        self.len = remaining;
        self.consumed = 0;
    }
};

// ─── main ─────────────────────────────────────────────────────────────────────

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();
    const subcmd = args.next() orelse {
        writeStderr(
            \\ghostty-snap: Reconnectable terminal prototype
            \\
            \\Usage:
            \\  ghostty-snap server [--name N] [-- cmd]   Start a named session
            \\  ghostty-snap attach [name | host:port]    Attach interactively
            \\  ghostty-snap list                         List active sessions
            \\  ghostty-snap capture [-- cmd]             Snapshot on Ctrl-\ or exit
            \\  ghostty-snap restore [file]               Replay snapshot to stdout
            \\
        );
        return;
    };

    if (std.mem.eql(u8, subcmd, "server")) {
        try runServer(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "attach")) {
        try runAttach(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try runList();
    } else if (std.mem.eql(u8, subcmd, "capture")) {
        try runCapture(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        try runRestore(alloc, &args);
    } else {
        writeStderr("Unknown subcommand. Use: server, attach, list, capture, restore\n");
    }
}

// ─── common helpers ───────────────────────────────────────────────────────────

fn collectCommandArgs(alloc: std.mem.Allocator, args: *std.process.ArgIterator) ![]const []const u8 {
    var cmd_args: std.ArrayList([]const u8) = .empty;
    defer cmd_args.deinit(alloc);
    var saw_dashdash = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--") and !saw_dashdash) {
            saw_dashdash = true;
            continue;
        }
        try cmd_args.append(alloc, arg);
    }
    if (cmd_args.items.len > 0) return try alloc.dupe([]const u8, cmd_args.items);
    const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
    const result = try alloc.alloc([]const u8, 1);
    result[0] = shell;
    return result;
}

fn spawnChild(alloc: std.mem.Allocator, p: *Pty, argv: []const []const u8) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        _ = std.c.setsid();
        posix.dup2(p.slave, STDIN) catch posix.abort();
        posix.dup2(p.slave, STDOUT) catch posix.abort();
        posix.dup2(p.slave, STDERR) catch posix.abort();
        if (p.slave > STDERR) posix.close(p.slave);
        posix.close(p.master);
        const argv_z = try allocNullTerminatedArgv(alloc, argv);
        const envp = @as([*:null]const ?[*:0]const u8, @ptrCast(std.os.environ.ptr));
        posix.execvpeZ(argv_z[0].?, argv_z, envp) catch {};
        posix.abort();
    }
    return pid;
}

fn getWinsize() ?pty_pkg.winsize {
    var ws: pty_pkg.winsize = undefined;
    const TIOCGWINSZ = 0x5413;
    if (std.os.linux.ioctl(STDOUT, TIOCGWINSZ, @intFromPtr(&ws)) == 0) return ws;
    return null;
}

fn setupRawMode() !posix.termios {
    const orig = try posix.tcgetattr(STDIN);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(STDIN, .FLUSH, raw);
    return orig;
}

fn restoreTermios(orig: posix.termios) void {
    posix.tcsetattr(STDIN, .FLUSH, orig) catch {};
}

fn allocNullTerminatedArgv(alloc: std.mem.Allocator, args: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const argv_buf = try alloc.alloc(?[*:0]const u8, args.len + 1);
    for (args, 0..) |arg, i| argv_buf[i] = try alloc.dupeZ(u8, arg);
    argv_buf[args.len] = null;
    return @ptrCast(argv_buf.ptr);
}

fn generateSnapshot(terminal: *Terminal, include_palette: bool) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    var fmt: terminalpkg.formatter.TerminalFormatter = .init(terminal, .vt);
    fmt.extra = .{
        .palette = include_palette,
        .modes = true,
        .scrolling_region = true,
        .tabstops = true,
        .pwd = true,
        .keyboard = true,
        .screen = .all,
    };
    fmt.format(&builder.writer) catch {
        builder.deinit();
        return null;
    };
    return builder.writer.buffered();
}

fn generateScrollback(terminal: *Terminal) ?[]const u8 {
    const screen = terminal.screens.active;
    const pages = &screen.pages;

    // Get the screen top (includes scrollback) and active top
    const screen_tl = pages.getTopLeft(.screen);
    const active_tl = pages.getTopLeft(.active);

    // If they're the same, there's no scrollback
    if (screen_tl.node == active_tl.node and screen_tl.y == active_tl.y) return null;

    var builder: std.Io.Writer.Allocating = .init(std.heap.c_allocator);

    // Format scrollback rows (everything from screen top to just before active area)
    var screen_fmt: terminalpkg.formatter.ScreenFormatter = .init(screen, .vt);
    screen_fmt.content = .{
        .selection = terminalpkg.Selection.init(
            screen_tl,
            // End just before the active area
            active_tl,
            false,
        ),
    };
    screen_fmt.extra = .styles; // Include SGR styling but not cursor/modes

    screen_fmt.format(&builder.writer) catch {
        builder.deinit();
        return null;
    };

    const data = builder.writer.buffered();
    if (data.len == 0) {
        std.heap.c_allocator.free(data);
        return null;
    }
    return data;
}

fn saveSnapshot(terminal: *Terminal, path: []const u8) !void {
    const data = generateSnapshot(terminal, true) orelse return error.SnapshotFailed;
    defer std.heap.c_allocator.free(data);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// ─── session management ───────────────────────────────────────────────────────

const SESSION_DIR = "/tmp/ghostty-snap-sessions";

fn writeSessionFile(name: []const u8, port: u16) void {
    std.fs.cwd().makePath(SESSION_DIR) catch return;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, SESSION_DIR ++ "/{s}.session", .{name}) catch return;
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var write_buf: [64]u8 = undefined;
    const content = std.fmt.bufPrint(&write_buf, "{d}\n", .{port}) catch return;
    file.writeAll(content) catch {};
}

fn removeSessionFile(name: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, SESSION_DIR ++ "/{s}.session", .{name}) catch return;
    std.fs.cwd().deleteFile(path) catch {};
}

fn readSessionPort(name: []const u8) ?u16 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, SESSION_DIR ++ "/{s}.session", .{name}) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const trimmed = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ' });
    return std.fmt.parseInt(u16, trimmed, 10) catch null;
}

fn runList() !void {
    var dir = std.fs.cwd().openDir(SESSION_DIR, .{ .iterate = true }) catch {
        writeStderr("No active sessions.\n");
        return;
    };
    defer dir.close();

    var found = false;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".session")) {
            const name = entry.name[0 .. entry.name.len - ".session".len];
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, SESSION_DIR ++ "/{s}", .{entry.name}) catch continue;
            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            var buf: [32]u8 = undefined;
            const n = file.readAll(&buf) catch continue;
            const port_str = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ' });
            stderrFmt("  {s}  (port {s})\n", .{ name, port_str });
            found = true;
        }
    }
    if (!found) writeStderr("No active sessions.\n");
}

// ─── OutputBuffer ─────────────────────────────────────────────────────────────

const OutputBuffer = struct {
    data: ?[]u8 = null,
    offset: usize = 0,

    fn queueSnapshot(self: *OutputBuffer, terminal: *Terminal) ?usize {
        return self.queueSnapshotOpts(terminal, false);
    }

    fn queueSnapshotInitial(self: *OutputBuffer, terminal: *Terminal) ?usize {
        return self.queueSnapshotOpts(terminal, true);
    }

    fn queueSnapshotOpts(self: *OutputBuffer, terminal: *Terminal, initial: bool) ?usize {
        const snap = generateSnapshot(terminal, false) orelse return null;
        defer std.heap.c_allocator.free(snap);

        // Initial: clear screen so stale local content is gone.
        // Catch-up: clear scrollback (stale) but no screen clear (overwrite in place).
        const header = if (initial) "\x1b[?2026h\x1b[H\x1b[2J" else "\x1b[?2026h\x1b[3J\x1b[H";
        const footer = "\x1b[?2026l";
        const vt_frame_len = header.len + snap.len + footer.len;

        // Build VT frame
        const vt_frame = std.heap.c_allocator.alloc(u8, vt_frame_len) catch return null;
        defer std.heap.c_allocator.free(vt_frame);
        @memcpy(vt_frame[0..header.len], header);
        @memcpy(vt_frame[header.len..][0..snap.len], snap);
        @memcpy(vt_frame[header.len + snap.len ..][0..footer.len], footer);

        // Wrap in protocol frame
        self.queueRaw(.snapshot, vt_frame);
        return snap.len;
    }

    fn queueRaw(self: *OutputBuffer, msg_type: MsgType, payload: []const u8) void {
        const len: u32 = @intCast(payload.len);
        const frame_header = [4]u8{
            @intFromEnum(msg_type),
            @truncate(len >> 16),
            @truncate((len >> 8) & 0xff),
            @truncate(len & 0xff),
        };

        if (self.data) |old| std.heap.c_allocator.free(old);
        const frame = std.heap.c_allocator.alloc(u8, 4 + payload.len) catch return;
        @memcpy(frame[0..4], &frame_header);
        @memcpy(frame[4..], payload);
        self.data = frame;
        self.offset = 0;
    }

    fn drain(self: *OutputBuffer, fd: posix.fd_t) bool {
        const data = self.data orelse return true;
        const remaining = data[self.offset..];
        if (remaining.len == 0) {
            std.heap.c_allocator.free(data);
            self.data = null;
            return true;
        }
        const n = posix.write(fd, remaining) catch |err| {
            if (err == error.WouldBlock) return false;
            std.heap.c_allocator.free(data);
            self.data = null;
            return false;
        };
        self.offset += n;
        if (self.offset >= data.len) {
            std.heap.c_allocator.free(data);
            self.data = null;
            return true;
        }
        return false;
    }

    fn hasPending(self: *const OutputBuffer) bool {
        return self.data != null;
    }

    fn deinit(self: *OutputBuffer) void {
        if (self.data) |d| std.heap.c_allocator.free(d);
        self.data = null;
    }
};

// ─── attach ───────────────────────────────────────────────────────────────────

var g_resize_requested: bool = false;

fn runAttach(_: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const target = args.next() orelse "127.0.0.1:7681";

    // Resolve target: could be a session name or host:port
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7681;

    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon| {
        // Looks like host:port
        host = target[0..colon];
        port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch 7681;
        if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
    } else {
        // Try as session name
        if (readSessionPort(target)) |p| {
            port = p;
        }
    }

    stderrFmt("[attach] Connecting to {s}:{d}...\n", .{ host, port });

    const addr = std.net.Address.parseIp4(host, port) catch {
        stderrFmt("[attach] Invalid address: {s}:{d}\n", .{ host, port });
        return;
    };
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Send initial resize frame with our terminal size
    const ws = getWinsize() orelse pty_pkg.winsize{
        .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0,
    };
    sendResize(sock, ws.ws_col, ws.ws_row);

    // Install SIGWINCH handler for resize during session
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);

    const orig = setupRawMode() catch {
        writeStderr("[attach] Warning: could not set raw mode\n");
        return;
    };

    stderrFmt("[attach] Connected. Press Ctrl-] to detach.\n", .{});

    defer {
        restoreTermios(orig);
        _ = posix.write(STDOUT, "\x1b[H\x1b[2J\x1b[0m") catch {};
        writeStderr("[attach] Detached.\n");
    }

    var buf: [4096]u8 = undefined;
    var frame_reader: FrameReader = .{};

    while (true) {
        // Check for resize
        if (g_resize_requested) {
            g_resize_requested = false;
            if (getWinsize()) |new_ws| {
                sendResize(sock, new_ws.ws_col, new_ws.ws_row);
            }
        }

        var fds = [_]posix.pollfd{
            .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = STDIN, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 100) catch break;
        if (ready == 0) continue;

        // Data from server → parse frames → stdout
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(sock, &buf) catch break;
            if (n == 0) {
                writeStderr("\r\n[attach] Server disconnected.\r\n");
                break;
            }
            frame_reader.feed(buf[0..n]);
            while (frame_reader.next()) |frame| {
                switch (frame.msg_type) {
                    .pty_data, .snapshot, .scrollback => {
                        _ = posix.write(STDOUT, frame.payload) catch {};
                    },
                    else => {},
                }
                // Advance AFTER consuming the payload — the payload slice
                // points into the buffer and advance() shifts the buffer.
                frame_reader.advance();
            }
        }

        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            writeStderr("\r\n[attach] Connection lost.\r\n");
            break;
        }

        // User input → server
        if (fds[1].revents & posix.POLL.IN != 0) {
            const n = posix.read(STDIN, &buf) catch break;
            if (n == 0) break;
            for (buf[0..n]) |byte| {
                if (byte == 0x1d) return; // Ctrl-]
            }
            if (writeFrame(sock, .input, buf[0..n], null) == .err) break;
        }
    }
}

fn sendResize(fd: posix.fd_t, cols: u16, rows: u16) void {
    const payload = [4]u8{
        @truncate(cols >> 8), @truncate(cols & 0xff),
        @truncate(rows >> 8), @truncate(rows & 0xff),
    };
    _ = writeFrame(fd, .resize, &payload, null);
}

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_resize_requested = true;
}

// ─── server ───────────────────────────────────────────────────────────────────

const TCP_NOTSENT_LOWAT: u32 = 25;

fn runServer(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var port: u16 = 7681;

    // Parse --name flag
    var session_name: ?[]const u8 = null;
    var cmd_args: std.ArrayList([]const u8) = .empty;
    defer cmd_args.deinit(alloc);
    var saw_dashdash = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--") and !saw_dashdash) {
            saw_dashdash = true;
            continue;
        }
        if (!saw_dashdash and std.mem.eql(u8, arg, "--name")) {
            session_name = args.next();
            continue;
        }
        if (!saw_dashdash and std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 7681;
            continue;
        }
        try cmd_args.append(alloc, arg);
    }

    const argv: []const []const u8 = if (cmd_args.items.len > 0)
        cmd_args.items
    else blk: {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const result = try alloc.alloc([]const u8, 1);
        result[0] = shell;
        break :blk result;
    };

    // Generate session name from PID if not specified
    var name_buf: [32]u8 = undefined;
    const name = session_name orelse blk: {
        const n = std.fmt.bufPrint(&name_buf, "s{d}", .{std.os.linux.getpid()}) catch "default";
        break :blk n;
    };

    const ws = getWinsize() orelse pty_pkg.winsize{
        .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0,
    };

    var p = try Pty.open(ws);
    defer p.deinit();

    const pid = try spawnChild(alloc, &p, argv);
    posix.close(p.slave);

    var terminal: Terminal = try .init(alloc, .{
        .cols = ws.ws_col,
        .rows = ws.ws_row,
    });
    defer terminal.deinit(alloc);

    const addr = try std.net.Address.parseIp4("0.0.0.0", port);
    const server_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
    defer posix.close(server_fd);

    try posix.setsockopt(server_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(server_fd, &addr.any, addr.getOsSockLen());
    try posix.listen(server_fd, 5);

    // Write session file
    writeSessionFile(name, port);
    defer removeSessionFile(name);

    stderrFmt("[server] Session '{s}' on port {d}\n", .{ name, port });
    stderrFmt("[server] Attach with: ghostty-snap attach {s}\n", .{name});

    var stream = terminal.vtStream();
    defer stream.deinit();

    const master_fd = p.master;
    var client_fd: ?posix.fd_t = null;
    var out_buf: OutputBuffer = .{};
    defer out_buf.deinit();
    var client_reader: FrameReader = .{};
    var buf: [4096]u8 = undefined;
    var child_alive = true;
    var total_pty_bytes: u64 = 0;
    var snapshots_sent: u64 = 0;
    var drops: u64 = 0;
    _ = &drops;
    var state_dirty = false;

    while (child_alive) {
        var poll_fds_buf: [3]posix.pollfd = undefined;
        var n_fds: usize = 2;
        poll_fds_buf[0] = .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 };
        poll_fds_buf[1] = .{ .fd = server_fd, .events = posix.POLL.IN, .revents = 0 };
        if (client_fd) |cfd| {
            poll_fds_buf[2] = .{ .fd = cfd, .events = posix.POLL.IN | posix.POLL.OUT, .revents = 0 };
            n_fds = 3;
        }

        const ready = posix.poll(poll_fds_buf[0..n_fds], 100) catch 0;

        if (ready == 0) {
            const result = posix.waitpid(pid, std.c.W.NOHANG);
            if (result.pid != 0) {
                child_alive = false;
                break;
            }
            continue;
        }

        // ── Client socket ──
        if (n_fds > 2 and client_fd != null) {
            // Drain output buffer
            if (poll_fds_buf[2].revents & posix.POLL.OUT != 0) {
                if (client_fd) |cfd| {
                    if (out_buf.drain(cfd)) {
                        if (state_dirty and terminal.screens.active_key != .alternate) {
                            if (out_buf.queueSnapshot(&terminal)) |len| {
                                snapshots_sent += 1;
                                stderrFmt("[server] Refresh snapshot: {d} bytes\n", .{len});
                            }
                            state_dirty = false;
                        }
                    }
                }
            }

            // Client input (framed)
            if (poll_fds_buf[2].revents & posix.POLL.IN != 0) {
                if (client_fd) |cfd| {
                    const n = posix.read(cfd, &buf) catch {
                        writeStderr("[server] Client disconnected\n");
                        posix.close(cfd);
                        client_fd = null;
                        out_buf.deinit();
                        continue;
                    };
                    if (n == 0) {
                        writeStderr("[server] Client disconnected\n");
                        posix.close(cfd);
                        client_fd = null;
                        out_buf.deinit();
                    } else {
                        client_reader.feed(buf[0..n]);
                        while (client_reader.next()) |frame| {
                            switch (frame.msg_type) {
                                .input => {
                                    _ = posix.write(master_fd, frame.payload) catch {};
                                },
                                .resize => {
                                    if (frame.payload.len == 4) {
                                        const new_cols: u16 = (@as(u16, frame.payload[0]) << 8) | frame.payload[1];
                                        const new_rows: u16 = (@as(u16, frame.payload[2]) << 8) | frame.payload[3];
                                        if (new_cols > 0 and new_rows > 0 and new_cols < 500 and new_rows < 200) {
                                            stderrFmt("[server] Resize: {d}x{d}\n", .{ new_cols, new_rows });
                                            p.setSize(.{
                                                .ws_col = new_cols, .ws_row = new_rows,
                                                .ws_xpixel = 0, .ws_ypixel = 0,
                                            }) catch {};
                                            terminal.resize(alloc, new_cols, new_rows) catch {};
                                        }
                                    }
                                },
                                else => {},
                            }
                            client_reader.advance();
                        }
                    }
                }
            }

            if (poll_fds_buf[2].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                if (client_fd) |cfd| {
                    writeStderr("[server] Client connection error\n");
                    posix.close(cfd);
                    client_fd = null;
                    out_buf.deinit();
                }
            }
        }

        // ── Pty output ──
        if (poll_fds_buf[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(master_fd, &buf) catch {
                child_alive = false;
                break;
            };
            if (n == 0) {
                child_alive = false;
                break;
            }

            stream.nextSlice(buf[0..n]);
            total_pty_bytes += n;

            if (client_fd) |cfd| {
                if (out_buf.hasPending()) {
                    // Don't queue snapshots while in alt screen — full-screen
                    // programs (vi, tmux) manage their own screen state.
                    // Snapshots would conflict with the program's drawing.
                    if (terminal.screens.active_key != .alternate) {
                        state_dirty = true;
                    }
                } else {
                    // Send as framed PTY_DATA. On short write, the
                    // remainder goes into out_buf to preserve frame alignment.
                    switch (writeFrame(cfd, .pty_data, buf[0..n], &out_buf)) {
                        .ok => {},
                        .partial => {
                            state_dirty = terminal.screens.active_key != .alternate;
                            drops += 1;
                        },
                        .would_block => {
                            drops += 1;
                            // Only snapshot if NOT in alt screen
                            if (terminal.screens.active_key != .alternate) {
                                if (out_buf.queueSnapshot(&terminal)) |slen| {
                                    snapshots_sent += 1;
                                    stderrFmt("[server] Blocked, snapshot {d}B\n", .{slen});
                                }
                                state_dirty = false;
                            }
                        },
                        .err => {
                            writeStderr("[server] Client write error, disconnecting\n");
                            posix.close(cfd);
                            client_fd = null;
                            out_buf.deinit();
                            continue;
                        },
                    }
                }
            }
        } else if (poll_fds_buf[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            child_alive = false;
            break;
        }

        // ── New TCP connection ──
        if (poll_fds_buf[1].revents & posix.POLL.IN != 0) {
            const new_fd = posix.accept(server_fd, null, null, posix.SOCK.NONBLOCK) catch continue;
            if (client_fd) |old| {
                posix.close(old);
                writeStderr("[server] Previous client replaced\n");
            }
            client_fd = new_fd;
            out_buf.deinit();
            client_reader = .{};
            state_dirty = false;

            posix.setsockopt(new_fd, posix.SOL.SOCKET, posix.SO.SNDBUF,
                &std.mem.toBytes(@as(c_int, 4096))) catch {};
            posix.setsockopt(new_fd, posix.IPPROTO.TCP, TCP_NOTSENT_LOWAT,
                &std.mem.toBytes(@as(c_int, 2048))) catch {};

            writeStderr("[server] Client connected\n");

            // Send scrollback first (if any), then snapshot
            if (generateScrollback(&terminal)) |sb_data| {
                defer std.heap.c_allocator.free(sb_data);
                _ = writeFrame(new_fd, .scrollback, sb_data, null);
                stderrFmt("[server] Scrollback: {d} bytes\n", .{sb_data.len});
            }

            if (out_buf.queueSnapshotInitial(&terminal)) |len| {
                snapshots_sent += 1;
                stderrFmt("[server] Initial snapshot: {d} bytes\n", .{len});
                if (client_fd) |cfd| _ = out_buf.drain(cfd);
            }
        }
    }

    if (client_fd) |cfd| posix.close(cfd);
    _ = posix.waitpid(pid, 0);

    stderrFmt("[server] Exiting. Snapshots: {d}, drops: {d}, pty: {d} bytes\n", .{
        snapshots_sent, drops, total_pty_bytes,
    });
}

// ─── capture ──────────────────────────────────────────────────────────────────

var g_snapshot_requested: bool = false;

fn runCapture(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const ws = getWinsize() orelse pty_pkg.winsize{
        .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0,
    };
    const argv = try collectCommandArgs(alloc, args);
    var p = try Pty.open(ws);
    defer p.deinit();

    const pid = try spawnChild(alloc, &p, argv);
    posix.close(p.slave);

    var terminal: Terminal = try .init(alloc, .{ .cols = ws.ws_col, .rows = ws.ws_row });
    defer terminal.deinit(alloc);

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = sigquitHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.QUIT, &sa, null);

    const orig_termios = setupRawMode() catch null;
    defer if (orig_termios) |t| restoreTermios(t);

    const master_fd = p.master;
    var stream = terminal.vtStream();
    defer stream.deinit();
    var buf: [4096]u8 = undefined;
    var child_alive = true;

    while (child_alive) {
        if (g_snapshot_requested) {
            g_snapshot_requested = false;
            saveSnapshot(&terminal, "/tmp/ghostty-snap.vt") catch {
                writeStderr("\r\n[capture] Snapshot error\r\n");
                continue;
            };
            writeStderr("\r\n[capture] Saved to /tmp/ghostty-snap.vt\r\n");
        }

        var fds = [_]posix.pollfd{
            .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = STDIN, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 100) catch 0;
        if (ready == 0) continue;

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(master_fd, &buf) catch { child_alive = false; break; };
            if (n == 0) { child_alive = false; break; }
            stream.nextSlice(buf[0..n]);
            _ = posix.write(STDOUT, buf[0..n]) catch {};
        } else if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            child_alive = false;
            break;
        }

        if (fds[1].revents & posix.POLL.IN != 0) {
            const n = posix.read(STDIN, &buf) catch continue;
            if (n > 0) _ = posix.write(master_fd, buf[0..n]) catch {};
        }
    }

    while (true) {
        var drain_fds = [_]posix.pollfd{.{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&drain_fds, 50) catch break) == 0) break;
        if (drain_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(master_fd, &buf) catch break;
            if (n == 0) break;
            stream.nextSlice(buf[0..n]);
            _ = posix.write(STDOUT, buf[0..n]) catch {};
        } else break;
    }

    _ = posix.waitpid(pid, 0);
    saveSnapshot(&terminal, "/tmp/ghostty-snap.vt") catch {};
    writeStderr("\r\n[capture] Final snapshot saved\r\n");
}

fn sigquitHandler(_: c_int) callconv(.c) void {
    g_snapshot_requested = true;
}

// ─── restore ──────────────────────────────────────────────────────────────────

fn runRestore(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const path = args.next() orelse "/tmp/ghostty-snap.vt";
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024);
    defer alloc.free(data);
    _ = posix.write(STDOUT, "\x1b[H\x1b[2J") catch {};
    _ = posix.write(STDOUT, data) catch {};
}
