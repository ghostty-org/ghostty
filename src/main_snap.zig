///! ghostty-snap: Reconnectable terminal demo
///!
///! Demonstrates reconnectable terminal technology using Ghostty's VT emulator.
///!
///! Usage:
///!   ghostty-snap server [-- command]    Start a server with a shell/command
///!   ghostty-snap attach [host:port]     Attach to a running server interactively
///!   ghostty-snap capture [-- command]   Run command, snapshot on Ctrl-\ (SIGQUIT)
///!   ghostty-snap restore [file]         Replay a snapshot file to stdout
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

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();
    const subcmd = args.next() orelse {
        writeStderr(
            \\ghostty-snap: Reconnectable terminal demo
            \\
            \\Usage:
            \\  ghostty-snap server [-- cmd]     Start server with shell/command
            \\  ghostty-snap attach [host:port]  Attach interactively (default: localhost:7681)
            \\  ghostty-snap capture [-- cmd]    Snapshot on Ctrl-\ or exit
            \\  ghostty-snap restore [file]      Replay snapshot to stdout
            \\
        );
        return;
    };

    if (std.mem.eql(u8, subcmd, "server")) {
        try runServer(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "attach")) {
        try runAttach(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "capture")) {
        try runCapture(alloc, &args);
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        try runRestore(alloc, &args);
    } else {
        writeStderr("Unknown subcommand. Use: server, attach, capture, restore\n");
    }
}

// ─── helpers ──────────────────────────────────────────────────────────────────

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
    if (cmd_args.items.len > 0) {
        return try alloc.dupe([]const u8, cmd_args.items);
    }
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

fn allocNullTerminatedArgv(
    alloc: std.mem.Allocator,
    args: []const []const u8,
) ![*:null]const ?[*:0]const u8 {
    const argv_buf = try alloc.alloc(?[*:0]const u8, args.len + 1);
    for (args, 0..) |arg, i| {
        argv_buf[i] = try alloc.dupeZ(u8, arg);
    }
    argv_buf[args.len] = null;
    return @ptrCast(argv_buf.ptr);
}

/// Pending output buffer for the client connection.
/// When a snapshot is queued, raw pty bytes are suppressed until the
/// buffer drains completely. This guarantees snapshots arrive intact.
const OutputBuffer = struct {
    data: ?[]u8 = null,
    offset: usize = 0,

    /// Queue a snapshot frame. Replaces any previously queued data
    /// (the newer snapshot supersedes the older one).
    fn queueSnapshot(self: *OutputBuffer, terminal: *Terminal) ?usize {
        return self.queueSnapshotOpts(terminal, false);
    }

    fn queueSnapshotInitial(self: *OutputBuffer, terminal: *Terminal) ?usize {
        return self.queueSnapshotOpts(terminal, true);
    }

    fn queueSnapshotOpts(self: *OutputBuffer, terminal: *Terminal, initial: bool) ?usize {
        const snap = generateSnapshot(terminal, false) orelse return null;
        defer std.heap.c_allocator.free(snap);

        // Non-initial snapshots clear scrollback — the dropped raw data
        // means scrollback is no longer accurate.
        const header = if (initial) "\x1b[?2026h\x1b[H" else "\x1b[?2026h\x1b[3J\x1b[H";
        const footer = "\x1b[?2026l";
        const frame_len = header.len + snap.len + footer.len;

        if (self.data) |old| std.heap.c_allocator.free(old);

        const frame = std.heap.c_allocator.alloc(u8, frame_len) catch return null;
        @memcpy(frame[0..header.len], header);
        @memcpy(frame[header.len..][0..snap.len], snap);
        @memcpy(frame[header.len + snap.len ..][0..footer.len], footer);

        self.data = frame;
        self.offset = 0;
        return snap.len;
    }

    /// Try to drain pending data to the fd. Returns true if all data
    /// was sent (or there was nothing to send). Returns false on error.
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
            // Real error — drop the buffer
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

    /// True when there's pending snapshot data — raw pty bytes must wait.
    fn hasPending(self: *const OutputBuffer) bool {
        return self.data != null;
    }

    fn deinit(self: *OutputBuffer) void {
        if (self.data) |d| std.heap.c_allocator.free(d);
        self.data = null;
    }
};

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

fn saveSnapshot(terminal: *Terminal, path: []const u8) !void {
    const data = generateSnapshot(terminal, true) orelse return error.SnapshotFailed;
    defer std.heap.c_allocator.free(data);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

// ─── attach (interactive client) ──────────────────────────────────────────────

fn runAttach(_: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const target = args.next() orelse "127.0.0.1:7681";

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 7681;
    if (std.mem.lastIndexOfScalar(u8, target, ':')) |colon| {
        host = target[0..colon];
        port = std.fmt.parseInt(u16, target[colon + 1 ..], 10) catch 7681;
    }
    if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";

    stderrFmt("[attach] Connecting to {s}:{d}...\n", .{ host, port });

    const addr = std.net.Address.parseIp4(host, port) catch {
        stderrFmt("[attach] Invalid address: {s}:{d}\n", .{ host, port });
        return;
    };
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);
    try posix.connect(sock, &addr.any, addr.getOsSockLen());

    // Send our terminal size so the server can resize the pty
    const ws = getWinsize() orelse pty_pkg.winsize{
        .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0,
    };
    const size_msg = [4]u8{
        @truncate(ws.ws_col >> 8), @truncate(ws.ws_col & 0xff),
        @truncate(ws.ws_row >> 8), @truncate(ws.ws_row & 0xff),
    };
    _ = posix.write(sock, &size_msg) catch {};

    // Enter raw mode and take over the terminal
    const orig = setupRawMode() catch {
        writeStderr("[attach] Warning: could not set raw mode\n");
        return;
    };
    // Clear the local screen — the server snapshot will redraw everything
    _ = posix.write(STDOUT, "\x1b[H\x1b[2J") catch {};

    stderrFmt("[attach] Connected. Press Ctrl-] to detach.\n", .{});

    defer {
        restoreTermios(orig);
        // Reset terminal state on detach
        _ = posix.write(STDOUT, "\x1b[H\x1b[2J\x1b[0m") catch {};
        writeStderr("[attach] Detached.\n");
    }

    var buf: [4096]u8 = undefined;

    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = STDIN, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 500) catch break;
        if (ready == 0) continue;

        // Data from server → stdout
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(sock, &buf) catch break;
            if (n == 0) {
                writeStderr("\r\n[attach] Server disconnected.\r\n");
                break;
            }
            _ = posix.write(STDOUT, buf[0..n]) catch {};
        }

        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
            writeStderr("\r\n[attach] Connection lost.\r\n");
            break;
        }

        // User input → server
        if (fds[1].revents & posix.POLL.IN != 0) {
            const n = posix.read(STDIN, &buf) catch break;
            if (n == 0) break;

            // Check for Ctrl-] (0x1d) to detach
            for (buf[0..n]) |byte| {
                if (byte == 0x1d) return;
            }

            _ = posix.write(sock, buf[0..n]) catch break;
        }
    }
}

// ─── server ───────────────────────────────────────────────────────────────────
//
// Architecture: TCP_NOTSENT_LOWAT backpressure
//
// We set TCP_NOTSENT_LOWAT on the client socket to a small value (e.g. 16KB).
// This means POLLOUT only fires when unsent data in the kernel drops below
// that threshold. The server polls for POLLOUT alongside POLLIN:
//
// - When POLLOUT is set: the pipe is clear. Write raw pty bytes (low latency).
// - When POLLOUT is NOT set: the client is behind. Feed pty through the
//   terminal emulator but DON'T send raw bytes (drop them).
// - When state was dropped and POLLOUT fires again: send a fresh snapshot
//   of the current state. The client jumps from stale to current instantly.
//
// Input (client→server) is ALWAYS forwarded immediately to the pty.
// This is why Ctrl-C works within one RTT even during output spew.

const TCP_NOTSENT_LOWAT: u32 = 25;

fn runServer(alloc: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const port: u16 = 7681;

    const ws = getWinsize() orelse pty_pkg.winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const argv = try collectCommandArgs(alloc, args);

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

    stderrFmt("[server] Listening on 0.0.0.0:{d}\n", .{port});
    stderrFmt("[server] Attach with: ghostty-snap attach localhost:{d}\n", .{port});

    var stream = terminal.vtStream();
    defer stream.deinit();

    const master_fd = p.master;
    var client_fd: ?posix.fd_t = null;
    var out_buf: OutputBuffer = .{};
    defer out_buf.deinit();
    var buf: [4096]u8 = undefined;
    var child_alive = true;
    var total_pty_bytes: u64 = 0;
    var snapshots_sent: u64 = 0;
    var drops: u64 = 0;
    var state_dirty = false; // new pty data arrived since last snapshot

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

        // ── Client socket handling ──
        if (n_fds > 2 and client_fd != null) {
            // Try to drain pending output buffer when socket is writable
            if (poll_fds_buf[2].revents & posix.POLL.OUT != 0) {
                if (client_fd) |cfd| {
                    if (out_buf.drain(cfd)) {
                        // Buffer fully drained.
                        if (state_dirty) {
                            // More pty data arrived while draining — queue fresh snapshot
                            if (out_buf.queueSnapshot(&terminal)) |len| {
                                snapshots_sent += 1;
                                stderrFmt("[server] Refresh snapshot: {d} bytes\n", .{len});
                            }
                            state_dirty = false;
                        }
                        // else: no new data, resume raw streaming
                    }
                }
            }

            // Client input → forward to pty (ALWAYS)
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
                        _ = posix.write(master_fd, buf[0..n]) catch {};
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

        // ── Pty output → terminal emulator (always) + client (conditionally) ──
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
                    // Snapshot is still draining — don't send raw bytes.
                    // Mark dirty so we queue a fresh snapshot after this one drains.
                    state_dirty = true;
                } else {
                    // No pending snapshot — try to send raw bytes directly
                    const written = posix.write(cfd, buf[0..n]) catch |err| blk: {
                        if (err == error.WouldBlock) break :blk @as(usize, 0);
                        writeStderr("[server] Client write error, disconnecting\n");
                        posix.close(cfd);
                        client_fd = null;
                        out_buf.deinit();
                        continue;
                    };

                    if (written < n) {
                        drops += 1;
                        stderrFmt("[server] Short write, queueing snapshot (drop #{d})\n", .{drops});
                        if (out_buf.queueSnapshot(&terminal)) |len| {
                            snapshots_sent += 1;
                            stderrFmt("[server] Snapshot queued: {d} bytes\n", .{len});
                        }
                        state_dirty = false;
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

            posix.setsockopt(new_fd, posix.SOL.SOCKET, posix.SO.SNDBUF,
                &std.mem.toBytes(@as(c_int, 4096))) catch {};
            posix.setsockopt(new_fd, posix.IPPROTO.TCP, TCP_NOTSENT_LOWAT,
                &std.mem.toBytes(@as(c_int, 2048))) catch |err| {
                stderrFmt("[server] Warning: TCP_NOTSENT_LOWAT failed: {}\n", .{err});
            };

            // Read client terminal size
            var size_buf: [4]u8 = undefined;
            if (posix.read(new_fd, &size_buf)) |n| {
                if (n == 4) {
                    const new_cols: u16 = (@as(u16, size_buf[0]) << 8) | size_buf[1];
                    const new_rows: u16 = (@as(u16, size_buf[2]) << 8) | size_buf[3];
                    if (new_cols > 0 and new_rows > 0 and new_cols < 500 and new_rows < 200) {
                        stderrFmt("[server] Client size: {d}x{d}\n", .{ new_cols, new_rows });
                        p.setSize(.{
                            .ws_col = new_cols, .ws_row = new_rows,
                            .ws_xpixel = 0, .ws_ypixel = 0,
                        }) catch {};
                        terminal.resize(alloc, new_cols, new_rows) catch {};
                    }
                }
            } else |_| {}

            writeStderr("[server] Client connected\n");

            // Queue initial snapshot (no scrollback clear)
            if (out_buf.queueSnapshotInitial(&terminal)) |len| {
                snapshots_sent += 1;
                stderrFmt("[server] Initial snapshot: {d} bytes\n", .{len});
                // Try to drain immediately
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

    // Drain remaining pty output
    while (true) {
        var drain_fds = [_]posix.pollfd{
            .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 },
        };
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
