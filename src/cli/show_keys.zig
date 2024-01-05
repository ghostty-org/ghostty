const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const terminal = @import("../terminal/main.zig");
const key = @import("../input/key.zig");

pub const Stream = terminal.Stream(VTHandler);

const log = std.log.scoped(.show_keys);

/// Our CLI args. `+show-keys` can take in a single parameter "mode" which
/// alters the key encoding mode requested of the underlying terminal
pub const Config = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    mode: Mode = .normal,

    pub fn deinit(self: *Config) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

/// The possible modes of encoding we can request
pub const Mode = enum {
    // The default mode
    normal,
    // Application cursor keys (DECCKM)
    application,
    // Kitty key encoding (CSIu). When kitty mode is requested, we enable all
    // flags
    kitty,
};

/// Our VT Stream handler
pub const VTHandler = struct {
    alloc: std.mem.Allocator,

    mode: Mode,

    /// If the main read loop should exit
    should_exit: bool = false,

    /// The stdout writer. We retain this so we can call from the parser
    /// callback without having to get a new writer
    stdout: std.fs.File.Writer,

    fn init(alloc: std.mem.Allocator) VTHandler {
        return VTHandler{
            .alloc = alloc,
            .stdout = std.io.getStdOut().writer(),
        };
    }

    /// The main loop
    fn run(self: VTHandler) !u8 {
        // First we get a handle on stdin and disable line bufferingm echo, etc
        // ("make it raw")
        const stdin = std.io.getStdIn();
        const termios = try makeRaw(stdin.handle);
        // Restore our state when we are done. Ignore the error because there is
        // nothing we can do if this fails
        defer os.tcsetattr(stdin.handle, .FLUSH, termios) catch {};

        // Hide the cursor
        try self.stdout.print("\x1B[?25l", .{});
        // Show the cursor when we are done
        defer self.stdout.print("\x1B[?25h", .{}) catch {};

        try self.stdout.print("\r\n\x1B[33;1mShow me your keys!\x1b[m\r\n", .{});
        try self.stdout.print("\x1B[3mPress Ctrl+c to exit\x1b[m\r\n\n", .{});

        // Set our requested key encoding mode
        switch (self.mode) {
            .normal => {},
            .application => try self.stdout.print("\x1B[?1h", .{}),
            .kitty => try self.stdout.print("\x1B[>31u", .{}),
        }
        // Clean up our mode
        defer {
            switch (self.mode) {
                .normal => {},
                .application => self.stdout.print("\x1B[?1l", .{}) catch {},
                .kitty => self.stdout.print("\x1B[<u", .{}) catch {},
            }
        }

        // Print our table header
        switch (self.mode) {
            .kitty => {
                // try self.stdout.print("{s: ^4}{s: ^4}{}\r\n", .{});
            },
            else => {
                try self.stdout.print("{s: <8}{s: <8}\r\n", .{ "Key", "Encoding" });
            },
        }

        // Set up our processing stream
        var stream: Stream = .{
            .handler = self,
        };

        // Our reads will always be small since it will generally be a single
        // keypress at a time. Still, we use a fairly large buffer for this so we
        // never interupt a sequence between reads
        var buf: [1024]u8 = undefined;

        // Simple loop to process input. We read the input, parse it, and print out
        // the result
        while (true) {
            const n = try stdin.read(&buf);
            try stream.nextSlice(buf[0..n]);
            if (stream.handler.should_exit) return 0;
        }
    }

    /// This is called from our stream after parsing the input
    pub fn handleManually(self: *VTHandler, seq: terminal.Parser.Action) !bool {
        // try self.stdout.print("{s}\r\n", .{action});

        // If we couldn't decode the event as a key, we return early
        switch (seq) {
            .print => |cp| {
                switch (cp) {
                    0x20 => {
                        try self.stdout.print("{s: <8}{s: <8}\r\n", .{ "space", "0x20" });
                    },
                    0x7F => {
                        try self.stdout.print("{s: <8}{s: <8}\r\n", .{ "backspace", "0x7F" });
                    },
                    else => {
                        try self.stdout.print("{u: <8}{u: <8}\r\n", .{ cp, cp });
                    },
                }
            },
            .execute => |b| {
                // We distinguish different cases here so we can print lower
                // case to match what we do in kitty
                switch (b) {
                    0x00, 0x1B...0x1F => {
                        try self.stdout.print("ctrl+{c}  0x{X}\r\n", .{ b + 0x40, b });
                    },
                    0x03 => {
                        try self.stdout.print("ctrl+{c}  0x{X}\r\n", .{ b + 0x60, b });
                        self.should_exit = true;
                    },
                    0x09 => {
                        try self.stdout.print("tab     0x09\r\n", .{});
                    },
                    0x0D => {
                        try self.stdout.print("enter   0x0D\r\n", .{});
                    },
                    else => {
                        try self.stdout.print("ctrl+{c}  0x{X}\r\n", .{ b + 0x60, b });
                    },
                }
            },
            .csi_dispatch => {},
            .esc_dispatch => {},
            // We ignore everything else; they are never keypresses
            else => {},
        }
        return true;
    }
};

pub fn run(alloc: Allocator) !u8 {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();

    var config: Config = .{};
    try args.parse(Config, alloc, &config, &iter);
    defer config.deinit();

    var handler: VTHandler = .{
        .alloc = alloc,
        .mode = config.mode,
        .stdout = std.io.getStdOut().writer(),
    };

    return handler.run();
}

/// Set the termios to "raw" state. This disables line buffering, echo, etc. so
/// that we can read the raw events happening on fd
pub fn makeRaw(fd: os.fd_t) !os.termios {
    const c = struct {
        usingnamespace switch (builtin.os.tag) {
            .macos => @cImport({
                @cInclude("sys/ioctl.h"); // ioctl and constants
                @cInclude("util.h"); // openpty()
            }),
            else => @cImport({
                @cInclude("sys/ioctl.h"); // ioctl and constants
                @cInclude("pty.h");
            }),
        };
    };
    const state = try os.tcgetattr(fd);
    var raw = state;
    // see golang/x/term
    raw.iflag &= ~@as(
        os.tcflag_t,
        c.IGNBRK |
            c.BRKINT |
            c.PARMRK |
            c.ISTRIP |
            c.INLCR |
            c.IGNCR |
            c.ICRNL |
            c.IXON,
    );
    raw.oflag &= ~@as(os.tcflag_t, c.OPOST);
    raw.lflag &= ~@as(
        os.tcflag_t,
        c.ECHO |
            c.ECHONL |
            c.ICANON |
            c.ISIG |
            c.IEXTEN,
    );
    raw.cflag &= ~@as(
        os.tcflag_t,
        c.CSIZE |
            c.PARENB,
    );
    raw.cflag |= @as(
        os.tcflag_t,
        c.CS8,
    );
    raw.cc[c.VMIN] = 1;
    raw.cc[c.VTIME] = 0;
    try os.tcsetattr(fd, .FLUSH, raw);
    return state;
}

// Parse a sequence into a Key
fn parseKey(seq: terminal.Parser.Action) ?key.KeyEvent {
    var k: key.KeyEvent = .{ .key = .invalid };
    var buf: [128]u8 = undefined;
    switch (seq) {
        .print => |cp| {
            const n = std.unicode.utf8Encode(cp, &buf) catch {
                log.err("couldn't encode codepoint: {d}", .{seq});
                return null;
            };
            k.utf8 = buf[0..n];
            return k;
        },
        .execute => {},
        .csi_dispatch => {},
        .esc_dispatch => {},
        // We ignore everything else; they are never keypresses
        else => {},
    }
    return null;
}
