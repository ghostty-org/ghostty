//! Runs esctest (https://github.com/ThomasDickey/esctest2) against
//! libghostty-vt, with no GUI in the way.
//!
//! The build installs esctest in share/esctest beside the bin directory
//! holding this executable. It runs under a pty. Everything it writes is
//! fed through a libghostty-vt terminal, and the terminal's replies
//! (DECRQCRA checksums, device attributes, cursor position and size
//! reports, and so on) are written back to it. When esctest exits, its
//! log is copied to stdout.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Handler = @FieldType(ghostty_vt.TerminalStream, "handler");

/// The size esctest resets the terminal to before every test, and so the
/// size it starts at.
const rows = 25;
const cols = 80;

/// The xterm checksum calculation esctest expects with --xterm-checksum
/// 334 and later, which is xterm's `checksumExtension: 23`.
const xt_checksum: ghostty_vt.xt_checksum.Flags = .{
    .positive = true,
    .no_attributes = true,
    .no_trim = true,
    .full = true,
};

/// Arguments always passed to esctest, before the user's own so that
/// theirs win. esctest only knows how to check a terminal that answers
/// like some real one, and xterm is the closest to libghostty-vt.
const esctest_args = [_][:0]const u8{
    "--expected-terminal=xterm",
    "--xterm-checksum=411",
    "--xterm-reverse-wrap=411",
    "--timeout=0.2",
};

const usage =
    \\Usage: esctest-libghostty [--verbose] [esctest arguments...]
    \\
    \\Arguments are passed to esctest, for example --include=DECSTR.
    \\The log goes to stdout.
    \\
    \\--verbose shows libghostty-vt's own log on stderr, which names each
    \\sequence it ignores.
    \\
;

pub const std_options: std.Options = .{ .logFn = logFn };

/// Whether to show libghostty-vt's log. Without --verbose there is a
/// warning for every sequence esctest sends that isn't implemented,
/// which buries everything else.
var verbose = false;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!verbose and level != .err) return;
    std.log.defaultLog(level, scope, format, args);
}

extern "c" fn forkpty(
    amaster: *std.c.fd_t,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const std.c.winsize,
) std.c.pid_t;

extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) c_int;

/// The pty master. Effects only get the handler, so this is how replies
/// reach esctest.
var pty: std.c.fd_t = -1;

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.arena.allocator();
    var args = (try init.minimal.args.toSlice(alloc))[1..];
    if (args.len >= 1 and std.mem.eql(u8, args[0], "--verbose")) {
        verbose = true;
        args = args[1..];
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "--help")) {
        std.debug.print("{s}", .{usage});
        return 1;
    }

    // Without this check, a missing python3 only shows up as esctest
    // writing no log, since the child's own error goes to the pty.
    if (!try onPath(alloc, init.environ_map.get("PATH") orelse "", "python3")) {
        std.debug.print(
            "warning: python3 was not found on PATH, and esctest needs it\n",
            .{},
        );
        return 1;
    }

    const exe_dir = try std.process.executableDirPathAlloc(init.io, alloc);
    const esctest_dir = try alloc.dupeSentinel(
        u8,
        try std.fs.path.resolve(alloc, &.{
            exe_dir,
            "..",
            "share",
            "esctest",
        }),
        0,
    );

    // esctest writes its log to a file rather than the terminal, so we
    // give it one to copy from afterwards.
    const log_path = try alloc.printSentinel(
        "/tmp/esctest-libghostty-{d}.log",
        .{std.c.getpid()},
        0,
    );
    defer _ = std.c.unlink(log_path);

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    try argv.append(alloc, "python3");
    try argv.append(alloc, "esctest.py");
    for (esctest_args) |arg| try argv.append(alloc, arg);
    try argv.append(alloc, try alloc.printSentinel(
        "--logfile={s}",
        .{log_path},
        0,
    ));
    for (args) |arg| try argv.append(alloc, arg);
    try argv.append(alloc, null);

    const ws: std.c.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    const pid = forkpty(&pty, null, null, &ws);
    if (pid < 0) return error.ForkptyFailed;
    if (pid == 0) {
        if (std.c.chdir(esctest_dir) != 0) {
            std.debug.print("cannot change to directory {s}\n", .{esctest_dir});
            std.c._exit(127);
        }
        _ = execvp("python3", @ptrCast(argv.items.ptr));
        std.debug.print("cannot run python3\n", .{});
        std.c._exit(127);
    }

    try run(init);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const exit_status = std.c.W.EXITSTATUS(@bitCast(status));

    // The child's own message about this went to the pty, not to us.
    if (exit_status == 127) {
        std.debug.print(
            "warning: couldn't start esctest with python3 in {s}\n",
            .{esctest_dir},
        );
        return 1;
    }

    try copyLog(init.io, log_path);
    return @intCast(exit_status);
}

/// Whether an executable with this name is in one of the directories of
/// a PATH value.
fn onPath(alloc: std.mem.Allocator, path: []const u8, name: []const u8) !bool {
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.joinZ(alloc, &.{ dir, name });
        defer alloc.free(candidate);
        if (std.c.access(candidate, std.c.X_OK) == 0) return true;
    }
    return false;
}

/// Feed esctest's output through the terminal until it exits.
fn run(init: std.process.Init) !void {
    var t: ghostty_vt.Terminal = try .init(init.io, init.gpa, .{
        .cols = cols,
        .rows = rows,
        .default_xt_checksum = xt_checksum,
    });
    defer t.deinit(init.gpa);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.handler.xt_checksum_report = true;
    stream.handler.effects.write_pty = &writePty;
    stream.handler.effects.size = &size;
    stream.handler.effects.device_attributes = &deviceAttributes;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pty, &buf, buf.len);
        if (n > 0) {
            stream.nextSlice(buf[0..@intCast(n)]);
            continue;
        }

        // Linux reports the other end closing as EIO rather than EOF.
        if (n == 0) return;
        switch (std.c.errno(n)) {
            .INTR => continue,
            .IO => return,
            else => |err| {
                std.debug.print("reading the pty failed: {t}\n", .{err});
                return error.ReadFailed;
            },
        }
    }
}

fn writePty(_: *Handler, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = std.c.write(pty, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

fn size(h: *Handler) ?ghostty_vt.size_report.Size {
    return .{
        .rows = h.terminal.rows,
        .columns = h.terminal.cols,
        .cell_width = 10,
        .cell_height = 20,
    };
}

/// Answer as a VT520, the terminal esctest's highest VT level tests.
fn deviceAttributes(_: *Handler) ghostty_vt.device_attributes.Attributes {
    return .{
        .primary = .{
            .conformance_level = .level_5,
            .features = &.{.ansi_color},
        },
        .secondary = .{ .device_type = .vt520 },
    };
}

fn copyLog(io: std.Io, path: [:0]const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("esctest wrote no log to {s}: {t}\n", .{ path, err });
        return;
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &write_buf);
    _ = try reader.interface.streamRemaining(&writer.interface);
    try writer.interface.flush();
}
