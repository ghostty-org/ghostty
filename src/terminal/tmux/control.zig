//! This file contains the implementation for tmux control mode. See
//! tmux(1) for more information on control mode. Some basics are documented
//! here but this is not meant to be a comprehensive source of protocol
//! documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const oni = @import("oniguruma");

const log = std.log.scoped(.terminal_tmux);

/// Undo tmux's escaping of bytes that can't travel in the control
/// stream, in place. The result is never longer than the input so we
/// just compact the slice and return the shorter view of it.
///
/// tmux writes a byte it can't send as a three digit octal escape. It
/// uses this for `%output` (where the backslash itself is `\134`) and
/// for `capture-pane -C` (where the backslash is doubled instead), so
/// both forms are accepted here.
pub fn unescape(data: []u8) []u8 {
    var w: usize = 0;
    var r: usize = 0;
    while (r < data.len) {
        escape: {
            if (data[r] != '\\') break :escape;
            if (r + 1 >= data.len) break :escape;

            if (data[r + 1] == '\\') {
                data[w] = '\\';
                w += 1;
                r += 2;
                continue;
            }

            if (r + 3 >= data.len) break :escape;
            var value: u16 = 0;
            for (data[r + 1 ..][0..3]) |digit| {
                if (digit < '0' or digit > '7') break :escape;
                value = value * 8 + (digit - '0');
            }
            if (value > std.math.maxInt(u8)) break :escape;

            data[w] = @intCast(value);
            w += 1;
            r += 4;
            continue;
        }

        data[w] = data[r];
        w += 1;
        r += 1;
    }

    return data[0..w];
}

/// Copy and unescape, for callers that only have a const view of the
/// data. See unescape. The result can be shorter than the allocation
/// behind it, so this is meant for arenas; anything else has to keep the
/// copy and free that instead.
pub fn unescapeAlloc(alloc: Allocator, data: []const u8) Allocator.Error![]u8 {
    return unescape(try alloc.dupe(u8, data));
}

/// The most input bytes a single `send-keys` command carries. Longer
/// input, such as a paste, is split across several commands rather than
/// one unbounded command line.
pub const send_keys_max = 1024;

/// Write one newline-terminated `send-keys` command that types `data`
/// into `pane`, or into tmux's active pane when `pane` is null.
///
/// The bytes go out as `-H` hex values rather than a `-l` literal
/// because tmux's command parser treats `;`, `$`, `#` and quotes as
/// syntax. tmux sends each `-H` value as one byte and drops values above
/// 0xff, so a multi-byte UTF-8 sequence is sent byte by byte.
pub fn writeSendKeys(
    writer: *std.Io.Writer,
    pane: ?usize,
    data: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeAll("send-keys");
    if (pane) |id| try writer.print(" -t %{d}", .{id});
    try writer.writeAll(" -H");
    for (data) |byte| try writer.print(" 0x{x:0>2}", .{byte});
    try writer.writeByte('\n');
}

/// A tmux control mode parser. This takes in output from tmux control
/// mode and parses it into a structured notifications.
///
/// It is up to the caller to establish the connection to the tmux
/// control mode session in some way (e.g. via exec, a network socket,
/// whatever). This is fully agnostic to how the data is received and sent.
pub const Parser = struct {
    /// Current state of the client.
    state: State = .idle,

    /// The buffer used to store in-progress notifications, output, etc.
    buffer: std.Io.Writer.Allocating,

    /// The maximum size in bytes of the buffer. This is used to limit
    /// memory usage. A begin/end block that outgrows it has its output
    /// dropped (see `Block.truncated`) but the stream stays usable,
    /// because the guard line still tells us where the block ends. Any
    /// other line that outgrows it puts the parser in a broken state
    /// (the control mode session will be forcibly exited and future
    /// data dropped).
    max_bytes: usize = 1024 * 1024,

    /// Whether the block we're in was started by a command this client
    /// sent. See `Block.client`.
    block_client: bool = true,

    /// While in `block_overflow`, the start of the current line. A guard
    /// line is short, so this is all we need to recognize the one that
    /// ends the block.
    overflow_line: [96]u8 = undefined,

    /// The length of the current line in `block_overflow`. Larger than
    /// `overflow_line.len` once the line is too long to be a guard line.
    overflow_len: usize = 0,

    const State = enum {
        /// Outside of any active notifications. This should drop any output
        /// unless it is '%' on the first byte of a line. The buffer will be
        /// cleared when it sees '%', this is so that the previous notification
        /// data is valid until we receive/process new data.
        idle,

        /// We experienced unexpected input and are in a broken state
        /// so we cannot continue processing. When this state is set,
        /// the buffer has been deinited and must not be accessed.
        broken,

        /// Inside an active notification (started with '%').
        notification,

        /// Inside a begin/end block.
        block,

        /// Inside a begin/end block whose output outgrew `max_bytes`. The
        /// output is dropped while we look for the guard line that ends
        /// the block.
        block_overflow,

        /// Inside a line that doesn't start with '%'. tmux writes the
        /// output of a `run-shell` that this client ran as plain lines
        /// outside of any block, so these are dropped up to the newline
        /// rather than treated as a broken stream.
        skip,
    };

    pub fn deinit(self: *Parser) void {
        // If we're in a broken state, we already deinited
        // the buffer, so we don't need to do anything.
        if (self.state == .broken) return;

        self.buffer.deinit();
    }

    // Handle a byte of input.
    //
    // If a line outside of a begin/end block reaches our byte limit this
    // will return OutOfMemory. It only does this on the first time we
    // exceed the limit; subsequent calls will return null as we drop all
    // input in a broken state.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        // If we're in a broken state, just do nothing.
        //
        // We have to do this check here before we check the buffer, because if
        // we're in a broken state then we'd have already deinited the buffer.
        if (self.state == .broken) return null;

        switch (self.state) {
            // Drop because we're in a broken state.
            .broken => return null,

            // Control mode output is wrapped in '%begin/%end' or is a
            // notification, both of which start with '%'. The only
            // exception is the output of a `run-shell` this client ran,
            // which tmux writes as-is; drop that line.
            .idle => if (byte != '%') {
                if (byte != '\n') self.state = .skip;
                return null;
            } else {
                self.buffer.clearRetainingCapacity();
                self.state = .notification;
            },

            .skip => {
                if (byte == '\n') self.state = .idle;
                return null;
            },

            .block_overflow => return self.putOverflow(byte),

            // If we're in a notification and its not a newline then
            // we accumulate. If it is a newline then we have a
            // complete notification we need to parse.
            .notification => if (byte == '\n') {
                // We have a complete notification, parse it.
                return self.parseNotification() catch {
                    // If parsing failed, then we do not mark the state
                    // as broken because we may be able to continue parsing
                    // other types of notifications.
                    //
                    // In the future we may want to emit a notification
                    // here about unknown or unsupported notifications.
                    return null;
                };
            },

            // If we're in a block then we accumulate until we see a newline
            // and then we check to see if that line ended the block.
            .block => if (byte == '\n') {
                const written = self.buffer.written();
                const idx = if (std.mem.lastIndexOfScalar(
                    u8,
                    written,
                    '\n',
                )) |v| v + 1 else 0;
                const line = written[idx..];

                if (parseBlockTerminator(line)) |terminator| {
                    const output = std.mem.trimEnd(
                        u8,
                        written[0..idx],
                        "\r\n",
                    );

                    // Important: do not clear buffer since the notification
                    // contains it.
                    self.state = .idle;
                    const block: Block = .{
                        .data = output,
                        .client = self.block_client,
                    };
                    switch (terminator) {
                        .end => return .{ .block_end = block },
                        .err => {
                            log.warn("tmux control mode error={s}", .{output});
                            return .{ .block_err = block };
                        },
                    }
                }

                // Didn't end the block, continue accumulating.
            },
        }

        // Only enforce the limit on bytes we actually store, so a line
        // filling the buffer exactly can still be terminated.
        if (self.buffer.written().len >= self.max_bytes) {
            // A block is delimited by its guard lines, so we can drop
            // its output and still find where it ends. The output that
            // tmux sends in blocks (a whole pane history, for example)
            // is also the only thing that can realistically get this
            // large.
            if (self.state == .block) {
                self.startOverflow();
                return self.putOverflow(byte);
            }

            self.broken();
            return error.OutOfMemory;
        }

        self.buffer.writer.writeByte(byte) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };

        return null;
    }

    /// Drop the output of the block we're in because it outgrew
    /// `max_bytes`. The part of the current line we have so far is kept
    /// so a guard line that straddles the limit is still recognized.
    fn startOverflow(self: *Parser) void {
        assert(self.state == .block);

        const written = self.buffer.written();
        const idx = if (std.mem.lastIndexOfScalar(u8, written, '\n')) |v|
            v + 1
        else
            0;
        const line = written[idx..];
        if (line.len <= self.overflow_line.len) {
            @memcpy(self.overflow_line[0..line.len], line);
            self.overflow_len = line.len;
        } else {
            self.overflow_len = self.overflow_line.len + 1;
        }

        self.buffer.clearRetainingCapacity();
        self.state = .block_overflow;
    }

    /// Handle a byte of a block whose output we're dropping. Returns the
    /// (empty, truncated) block once its guard line arrives.
    fn putOverflow(self: *Parser, byte: u8) ?Notification {
        assert(self.state == .block_overflow);

        if (byte != '\n') {
            if (self.overflow_len < self.overflow_line.len) {
                self.overflow_line[self.overflow_len] = byte;
            }
            self.overflow_len +|= 1;
            return null;
        }

        defer self.overflow_len = 0;
        if (self.overflow_len > self.overflow_line.len) return null;
        const terminator = parseBlockTerminator(
            self.overflow_line[0..self.overflow_len],
        ) orelse return null;

        log.warn(
            "tmux control mode block exceeded {d} bytes, output dropped",
            .{self.max_bytes},
        );
        self.state = .idle;
        const block: Block = .{
            .client = self.block_client,
            .truncated = true,
        };
        return switch (terminator) {
            .end => .{ .block_end = block },
            .err => .{ .block_err = block },
        };
    }

    /// Whether a `%begin <time> <number> <flags>` line is for a command
    /// this client sent. tmux sets bit 0 of the flags for commands it
    /// read from a control client; output from hooks and from the
    /// command the client was started with has it clear. A line we can't
    /// read is assumed to be ours, which is how every block was treated
    /// before tmux started reporting this.
    fn beginFromClient(line: []const u8) bool {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next(); // %begin
        _ = fields.next() orelse return true; // time
        _ = fields.next() orelse return true; // command number
        const flags = fields.next() orelse return true;
        const value = std.fmt.parseInt(usize, flags, 10) catch return true;
        return value & 1 != 0;
    }

    const ParseError = error{RegexError};

    const BlockTerminator = enum { end, err };

    /// Block payload is raw data, so a line only terminates a block if it
    /// exactly matches tmux's `%end`/`%error` guard-line shape.
    fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
        var line = line_raw;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = fields.next() orelse return null;
        const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
            .end
        else if (std.mem.eql(u8, cmd, "%error"))
            .err
        else
            return null;

        const time = fields.next() orelse return null;
        const command_id = fields.next() orelse return null;
        const flags = fields.next() orelse return null;
        const extra = fields.next();

        // In the future, we should compare these to the %begin block
        // because the tmux source guarantees that these always match and
        // that is a more robust way to match.
        _ = std.fmt.parseInt(usize, time, 10) catch return null;
        _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
        _ = std.fmt.parseInt(usize, flags, 10) catch return null;
        if (extra != null) return null;

        return terminator;
    }

    fn parseNotification(self: *Parser) ParseError!?Notification {
        assert(self.state == .notification);

        const line = line: {
            var line = self.buffer.written();
            if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            break :line line;
        };
        const cmd = cmd: {
            const idx = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            break :cmd line[0..idx];
        };

        // The notification MUST exist because we guard entering the notification
        // state on seeing at least a '%'.
        if (std.mem.eql(u8, cmd, "%begin")) {
            // tmux guarantees that begin/end are always in order and never
            // intermixed, so the time and command number aren't needed to
            // pair them up. The flags tell us who the command came from.
            self.block_client = beginFromClient(line);

            // Move to block state because we expect a corresponding end/error
            // and want to accumulate the data.
            self.state = .block;
            self.buffer.clearRetainingCapacity();
            return null;
        } else if (std.mem.eql(u8, cmd, "%output")) cmd: {
            var re = oni.Regex.init(
                "^%output %([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const data = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .output = .{ .pane_id = id, .data = data } };
        } else if (std.mem.eql(u8, cmd, "%session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%session-changed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_changed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%sessions-changed")) cmd: {
            if (!std.mem.eql(u8, line, "%sessions-changed")) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .sessions_changed = {} };
        } else if (std.mem.eql(u8, cmd, "%layout-change")) cmd: {
            var re = oni.Regex.init(
                "^%layout-change @([0-9]+) (.+) (.+) (.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const layout = line[@intCast(starts[2])..@intCast(ends[2])];
            const visible_layout = line[@intCast(starts[3])..@intCast(ends[3])];
            const raw_flags = line[@intCast(starts[4])..@intCast(ends[4])];

            // Important: do not clear buffer here since layout strings point to it
            self.state = .idle;
            return .{ .layout_change = .{
                .window_id = id,
                .layout = layout,
                .visible_layout = visible_layout,
                .raw_flags = raw_flags,
            } };
        } else if (std.mem.eql(u8, cmd, "%window-add")) cmd: {
            var re = oni.Regex.init(
                "^%window-add @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_add = .{ .id = id } };
        } else if (std.mem.eql(u8, cmd, "%window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-close") or
            std.mem.eql(u8, cmd, "%unlinked-window-add"))
        cmd: {
            // tmux picks the plain or the "unlinked" name depending on
            // whether the window is linked to this client's session at
            // the moment it notifies. A window closed in our own session
            // is already unlinked by then, so `%unlinked-window-close`
            // can be about one of our windows too; the receiver has to
            // check the id.
            const Kind = enum { close, unlinked_close, unlinked_add };
            const kind: Kind = if (std.mem.eql(u8, cmd, "%window-close"))
                .close
            else if (std.mem.eql(u8, cmd, "%unlinked-window-close"))
                .unlinked_close
            else
                .unlinked_add;
            const pattern = switch (kind) {
                .close => "^%window-close @([0-9]+)$",
                .unlinked_close => "^%unlinked-window-close @([0-9]+)$",
                .unlinked_add => "^%unlinked-window-add @([0-9]+)$",
            };
            var re = oni.Regex.init(
                pattern,
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return switch (kind) {
                .close => .{ .window_close = .{ .id = id } },
                .unlinked_close => .{ .unlinked_window_close = .{ .id = id } },
                .unlinked_add => .{ .unlinked_window_add = .{ .id = id } },
            };
        } else if (std.mem.eql(u8, cmd, "%window-renamed") or
            std.mem.eql(u8, cmd, "%unlinked-window-renamed"))
        cmd: {
            // As with %unlinked-window-close, the name only says whether
            // the window was linked to our session when tmux notified.
            //
            // A window can be renamed to nothing, which leaves the line
            // ending in the separator, or without it if something trimmed
            // the line.
            const unlinked = !std.mem.eql(u8, cmd, "%window-renamed");
            var re = oni.Regex.init(
                if (unlinked)
                    "^%unlinked-window-renamed @([0-9]+) ?(.*)$"
                else
                    "^%window-renamed @([0-9]+) ?(.*)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return if (unlinked)
                .{ .unlinked_window_renamed = .{ .id = id, .name = name } }
            else
                .{ .window_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%window-pane-changed")) cmd: {
            var re = oni.Regex.init(
                "^%window-pane-changed @([0-9]+) %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .window_pane_changed = .{ .window_id = window_id, .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%session-window-changed")) cmd: {
            // Emitted when the session's current window changes (select-window).
            // Distinct from %window-pane-changed (active pane within a window).
            var re = oni.Regex.init(
                "^%session-window-changed \\$([0-9]+) @([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const window_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .session_window_changed = .{
                .session_id = session_id,
                .window_id = window_id,
            } };
        } else if (std.mem.eql(u8, cmd, "%client-detached")) cmd: {
            var re = oni.Regex.init(
                "^%client-detached (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];

            // Important: do not clear buffer here since client points to it
            self.state = .idle;
            return .{ .client_detached = .{ .client = client } };
        } else if (std.mem.eql(u8, cmd, "%exit")) {
            // tmux emits %exit when the control client leaves control
            // mode. Act on it immediately rather than waiting for the
            // trailing ST.
            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .exit = {} };
        } else if (std.mem.eql(u8, cmd, "%client-session-changed")) cmd: {
            var re = oni.Regex.init(
                "^%client-session-changed (.+) \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const client = line[@intCast(starts[1])..@intCast(ends[1])];
            const session_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[2])..@intCast(ends[2])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[3])..@intCast(ends[3])];

            // Important: do not clear buffer here since client/name point to it
            self.state = .idle;
            return .{ .client_session_changed = .{ .client = client, .session_id = session_id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%session-renamed")) cmd: {
            var re = oni.Regex.init(
                "^%session-renamed \\$([0-9]+) (.+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;
            const name = line[@intCast(starts[2])..@intCast(ends[2])];

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .session_renamed = .{ .id = id, .name = name } };
        } else if (std.mem.eql(u8, cmd, "%pane-mode-changed")) cmd: {
            var re = oni.Regex.init(
                "^%pane-mode-changed %([0-9]+)$",
                .{ .capture_group = true },
                oni.Encoding.utf8,
                oni.Syntax.default,
                null,
            ) catch |err| {
                log.warn("regex init failed error={}", .{err});
                return error.RegexError;
            };
            defer re.deinit();

            var region = re.search(line, .{}) catch |err| {
                log.warn("failed to match notification cmd={s} line=\"{s}\" err={}", .{ cmd, line, err });
                break :cmd;
            };
            defer region.deinit();
            const starts = region.starts();
            const ends = region.ends();

            const pane_id = std.fmt.parseInt(
                usize,
                line[@intCast(starts[1])..@intCast(ends[1])],
                10,
            ) catch unreachable;

            self.buffer.clearRetainingCapacity();
            self.state = .idle;
            return .{ .pane_mode_changed = .{ .pane_id = pane_id } };
        } else if (std.mem.eql(u8, cmd, "%subscription-changed")) cmd: {
            // `%subscription-changed name $session @window index %pane ... : value`.
            // Only the name matters to us; what a subscription watches is
            // ours to know.
            const rest = line[cmd.len..];
            if (rest.len < 2) {
                log.warn("failed to match notification cmd={s} line=\"{s}\"", .{ cmd, line });
                break :cmd;
            }
            const name = std.mem.sliceTo(rest[1..], ' ');

            // Important: do not clear buffer here since name points to it
            self.state = .idle;
            return .{ .subscription_changed = .{ .name = name } };
        } else if (std.mem.eql(u8, cmd, "%config-error")) {
            // Errors in the server's configuration file. Nothing to act
            // on, but worth having in the log.
            log.info("tmux configuration error: {s}", .{line});
        } else if (std.mem.eql(u8, cmd, "%message") or
            std.mem.eql(u8, cmd, "%paste-buffer-changed") or
            std.mem.eql(u8, cmd, "%paste-buffer-deleted") or
            std.mem.eql(u8, cmd, "%continue") or
            std.mem.eql(u8, cmd, "%pause") or
            std.mem.eql(u8, cmd, "%extended-output"))
        {
            // Known notifications we have no use for. `%pause`,
            // `%continue` and `%extended-output` only happen with the
            // pause-after client flag, which we don't use.
            log.debug("ignoring tmux control mode notification={s}", .{cmd});
        } else {
            // Unknown notification, log it and return to idle state.
            log.warn("unknown tmux control mode notification={s}", .{cmd});
        }

        // Unknown command. Clear the buffer and return to idle state.
        self.buffer.clearRetainingCapacity();
        self.state = .idle;

        return null;
    }

    // Mark the tmux state as broken.
    fn broken(self: *Parser) void {
        self.state = .broken;
        self.buffer.deinit();
    }
};

/// Possible notification types from tmux control mode. These are documented
/// in tmux(1). A lot of the simple documentation was copied from that man
/// page here.
pub const Notification = union(enum) {
    /// Entering tmux control mode. This isn't an actual event sent by
    /// tmux but is one sent by us to indicate that we have detected that
    /// tmux control mode is starting.
    enter,

    /// Exit.
    ///
    /// NOTE: The tmux protocol contains a "reason" string (human friendly)
    /// associated with this. We currently drop it because we don't need it
    /// but this may be something we want to add later. If we do add it,
    /// we have to consider buffer limits and how we handle those (dropping
    /// vs truncating, etc.).
    exit,

    /// Dispatched at the end of a begin/end block with the raw data.
    /// The control mode parser can't parse the data because it is unaware
    /// of the command that was sent to trigger this output.
    block_end: Block,
    block_err: Block,

    /// Raw output from a pane.
    output: struct {
        pane_id: usize,

        /// Still escaped as tmux sent it. Decoding is left to the
        /// consumers (see `unescape`) so that a client that ignores
        /// pane output doesn't pay for it.
        data: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    session_changed: struct {
        id: usize,
        name: []const u8,
    },

    /// A session was created or destroyed.
    sessions_changed,

    /// The layout of the window with ID window-id changed.
    layout_change: struct {
        window_id: usize,
        layout: []const u8,
        visible_layout: []const u8,
        raw_flags: []const u8,
    },

    /// The window with ID window-id was linked to the current session.
    window_add: struct {
        id: usize,
    },

    /// The window with ID window-id was closed while still linked to
    /// this session.
    window_close: struct {
        id: usize,
    },

    /// The window with ID window-id was linked to a session other than
    /// ours.
    unlinked_window_add: struct {
        id: usize,
    },

    /// The window with ID window-id was closed or unlinked and isn't
    /// linked to this session (any more). This is also what tmux sends
    /// when one of our own windows is killed or its last pane exits,
    /// because the window is gone from our session by the time tmux
    /// notifies.
    unlinked_window_close: struct {
        id: usize,
    },

    /// The window with ID window-id was renamed to name.
    window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// A window that isn't linked to this session was renamed.
    unlinked_window_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The session with ID session-id was renamed to name.
    session_renamed: struct {
        id: usize,
        name: []const u8,
    },

    /// The pane with ID pane-id entered or left a mode (copy mode, ...).
    pane_mode_changed: struct {
        pane_id: usize,
    },

    /// The value of a format the client subscribed to with
    /// `refresh-client -B name:...` changed. tmux checks subscriptions
    /// about once a second.
    subscription_changed: struct {
        name: []const u8,
    },

    /// The active pane in the window with ID window-id changed to the pane
    /// with ID pane-id.
    window_pane_changed: struct {
        window_id: usize,
        pane_id: usize,
    },

    /// The session's current window changed (e.g. `select-window`).
    session_window_changed: struct {
        session_id: usize,
        window_id: usize,
    },

    /// The client has detached.
    client_detached: struct {
        client: []const u8,
    },

    /// The client is now attached to the session with ID session-id, which is
    /// named name.
    client_session_changed: struct {
        client: []const u8,
        session_id: usize,
        name: []const u8,
    },

    pub fn format(self: Notification, writer: *std.Io.Writer) !void {
        const T = Notification;
        const info = @typeInfo(T).@"union";

        try writer.writeAll(@typeName(T));
        if (info.tag_type) |TagType| {
            try writer.writeAll("{ .");
            try writer.writeAll(@tagName(@as(TagType, self)));
            try writer.writeAll(" = ");

            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (self == @field(TagType, field_name)) {
                    const value = @field(self, field_name);
                    switch (field_type) {
                        []const u8 => try writer.print("\"{s}\"", .{std.mem.trim(u8, value, " \t\r\n")}),
                        Block => try writer.print(
                            "\"{s}\" client={} truncated={}",
                            .{
                                std.mem.trim(u8, value.data, " \t\r\n"),
                                value.client,
                                value.truncated,
                            },
                        ),
                        else => try writer.print("{any}", .{value}),
                    }
                }
            }

            try writer.writeAll(" }");
        }
    }
};

/// The output of a command: everything between a `%begin` line and the
/// `%end` or `%error` line that closes it.
pub const Block = struct {
    /// The raw output, without the trailing newline.
    data: []const u8 = "",

    /// True if the command was sent by this client. Blocks from hooks
    /// (and the one answering the command the client was started with)
    /// are written to us too, but they aren't the reply to anything we
    /// sent and must not be matched against our commands.
    client: bool = true,

    /// The output was larger than the parser allows and was dropped, so
    /// `data` is empty. The stream is still in sync.
    truncated: bool = false,
};

test "tmux begin/end empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("", n.block_end.data);
}

test "tmux begin/error empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("", n.block_err.data);
}

test "tmux notification exactly max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = line.len };
    defer c.deinit();

    // Twice, because the second '%' arrives while the buffer is still
    // full from the first notification.
    for (0..2) |_| {
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        const n = (try c.put('\n')).?;
        try testing.expect(n == .sessions_changed);
    }
}

test "tmux block terminator exactly max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const block = "hello\n%end 1578922740 269 1";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = block.len };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for (block) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello", n.block_end.data);
}

test "tmux exceeding max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const line = "%sessions-changed";
    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = line.len - 1 };
    defer c.deinit();
    for (line[0 .. line.len - 1]) |byte| try testing.expect(try c.put(byte) == null);
    try testing.expectError(error.OutOfMemory, c.put(line[line.len - 1]));
    try testing.expect(try c.put('\n') == null);
}

test "tmux begin/end data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1578922740 269 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\nworld\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1578922740 269 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("hello\nworld", n.block_end.data);
}

test "tmux block payload may start with %end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end not really\nhello", n.block_end.data);
}

test "tmux block payload may start with %error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%error not really\nhello", n.block_end.data);
}

test "tmux block may terminate with real %error after misleading payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error not really\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%error 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_err);
    try testing.expectEqualStrings("%error not really\nhello", n.block_err.data);
}

test "tmux block terminator requires exact token count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1 trailing\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end 1 1 1 trailing\nhello", n.block_end.data);
}

test "tmux block terminator requires numeric metadata" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%begin 1 1 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end foo bar baz\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("hello\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("%end 1 1 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expectEqualStrings("%end foo bar baz\nhello", n.block_end.data);
}

test "tmux output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%output %42 foo bar baz") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(42, n.output.pane_id);
    try testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "tmux output octal escapes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // The parser hands the data on still escaped. \033 is ESC, \015 is CR,
    // \134 is the backslash itself. Anything that isn't a complete octal
    // escape has to survive decoding untouched.
    const escaped = "\\033[1mbold\\033[0m\\015\\134n \\9 \\77";
    for ("%output %1 " ++ escaped) |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .output);
    try testing.expectEqual(1, n.output.pane_id);
    try testing.expectEqualStrings(escaped, n.output.data);

    const copy = try alloc.dupe(u8, n.output.data);
    defer alloc.free(copy);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m\r\\n \\9 \\77", unescape(copy));
}

test "tmux send-keys sends UTF-8 byte by byte" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeSendKeys(&writer, 3, "a\u{e9}\u{4e2d}\u{1f600};");
    try testing.expectEqualStrings(
        "send-keys -t %3 -H 0x61 0xc3 0xa9 0xe4 0xb8 0xad 0xf0 0x9f 0x98 0x80 0x3b\n",
        writer.buffered(),
    );
}

test "tmux send-keys without a pane types into the active pane" {
    const testing = std.testing;

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeSendKeys(&writer, null, "\x1b\r");
    try testing.expectEqualStrings("send-keys -H 0x1b 0x0d\n", writer.buffered());
}

test "tmux unescape" {
    const testing = std.testing;

    // `capture-pane -C` doubles the backslash instead of escaping it as
    // \134, so both spellings have to work.
    var buf: [64]u8 = undefined;
    const data = try std.fmt.bufPrint(
        &buf,
        "{s}",
        .{"\\033[1mA\\033[0m b\\\\c\\134d"},
    );
    try testing.expectEqualStrings(
        "\x1b[1mA\x1b[0m b\\c\\d",
        unescape(data),
    );
}

test "tmux session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-changed $42 foo") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_changed);
    try testing.expectEqual(42, n.session_changed.id);
    try testing.expectEqualStrings("foo", n.session_changed.name);
}

test "tmux sessions-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux sessions-changed carriage return" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux layout-change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%layout-change @2 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} 1234x791,0,0{617x791,0,0,0,617x791,618,0,1} *-") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .layout_change);
    try testing.expectEqual(2, n.layout_change.window_id);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.layout);
    try testing.expectEqualStrings("1234x791,0,0{617x791,0,0,0,617x791,618,0,1}", n.layout_change.visible_layout);
    try testing.expectEqualStrings("*-", n.layout_change.raw_flags);
}

test "tmux window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-add @14") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_add);
    try testing.expectEqual(14, n.window_add.id);
}

test "tmux window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-close @7") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_close);
    try testing.expectEqual(7, n.window_close.id);
}

test "tmux unlinked-window-close" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-close @2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_close);
    try testing.expectEqual(2, n.unlinked_window_close.id);
}

test "tmux unlinked-window-add" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-add @9") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_add);
    try testing.expectEqual(9, n.unlinked_window_add.id);
}

test "tmux unlinked-window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-renamed @2 zzz top") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_renamed);
    try testing.expectEqual(2, n.unlinked_window_renamed.id);
    try testing.expectEqualStrings("zzz top", n.unlinked_window_renamed.name);
}

test "tmux session-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-renamed $0 proto2\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_renamed);
    try testing.expectEqual(0, n.session_renamed.id);
    try testing.expectEqualStrings("proto2", n.session_renamed.name);
}

test "tmux pane-mode-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%pane-mode-changed %1\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .pane_mode_changed);
    try testing.expectEqual(1, n.pane_mode_changed.pane_id);
}

test "tmux known notifications we don't use are dropped quietly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Lines as tmux writes them, each followed by a notification we do
    // use to show the parser is still in sync.
    const lines = [_][]const u8{
        "%message hi-there",
        "%config-error /tmp/tmux.conf:2: invalid option: bogus-option",
        "%paste-buffer-changed buffer0",
        "%paste-buffer-deleted buffer0",
        "%continue %1",
        "%pause %1",
        "%extended-output %1 12 : hello",
    };
    for (lines) |line| {
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        try testing.expect(try c.put('\r') == null);
        try testing.expect(try c.put('\n') == null);
        for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
        const n = (try c.put('\n')).?;
        try testing.expect(n == .sessions_changed);
    }
}

test "tmux subscription-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Real tmux output for a session subscription, whose window, index
    // and pane are dashes.
    for ("%subscription-changed ghostty-windows $0 - - - : @0 @3 @2 @1 \r") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const n = (try c.put('\n')).?;
    try testing.expect(n == .subscription_changed);
    try testing.expectEqualStrings("ghostty-windows", n.subscription_changed.name);

    // Still in sync afterwards.
    for ("%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect((try c.put('\n')).? == .sessions_changed);
}

test "tmux begin flags tell our replies from hook output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // Real tmux output for `split-window` with an `after-split-window`
    // hook that runs `display-message -p HOOKED`.
    for ("%begin 1793135566 296 1\r\n%end 1793135566 296 1\r") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const ours = (try c.put('\n')).?;
    try testing.expect(ours == .block_end);
    try testing.expect(ours.block_end.client);

    for ("%begin 1793135566 297 0\r\nHOOKED\r\n%end 1793135566 297 0\r") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const hook = (try c.put('\n')).?;
    try testing.expect(hook == .block_end);
    try testing.expect(!hook.block_end.client);
    try testing.expectEqualStrings("HOOKED", hook.block_end.data);

    // Parse errors are reported as our own block too.
    for ("%begin 1 298 1\r\nparse error: syntax error\r\n%error 1 298 1\r") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    const err = (try c.put('\n')).?;
    try testing.expect(err == .block_err);
    try testing.expect(err.block_err.client);
}

test "tmux run-shell output outside a block is skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();

    // tmux writes `run-shell 'echo hi'` output as a bare line after the
    // command's (empty) block.
    for ("%begin 1 294 1\r\n%end 1 294 1\r") |byte| try testing.expect(try c.put(byte) == null);
    try testing.expect((try c.put('\n')).? == .block_end);
    for ("hi\r\n\n%sessions-changed\r") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .sessions_changed);
}

test "tmux oversized block is dropped but the stream stays in sync" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc), .max_bytes = 16 };
    defer c.deinit();

    // The limit is reached in the middle of the guard line.
    for ("%begin 1 2 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("0123456789\n%end ") |byte| try testing.expect(try c.put(byte) == null);
    for ("1 2 1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .block_end);
    try testing.expect(n.block_end.truncated);
    try testing.expect(n.block_end.client);
    try testing.expectEqualStrings("", n.block_end.data);

    // A guard line hidden at the end of a long line isn't one.
    for ("%begin 1 3 1\n") |byte| try testing.expect(try c.put(byte) == null);
    for ("xxxxxxxxxxxxxxxxxxxxxxxx%end 1 3 1\n") |byte| {
        try testing.expect(try c.put(byte) == null);
    }
    for ("%error 1 3 1") |byte| try testing.expect(try c.put(byte) == null);
    const e = (try c.put('\n')).?;
    try testing.expect(e == .block_err);
    try testing.expect(e.block_err.truncated);

    // And the next notification parses normally.
    for ("%window-add @1") |byte| try testing.expect(try c.put(byte) == null);
    const w = (try c.put('\n')).?;
    try testing.expect(w == .window_add);
}

test "tmux window-renamed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-renamed @42 bar") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_renamed);
    try testing.expectEqual(42, n.window_renamed.id);
    try testing.expectEqualStrings("bar", n.window_renamed.name);
}

test "tmux window-renamed to an empty name" {
    const testing = std.testing;
    const alloc = testing.allocator;

    inline for (.{ "%window-renamed @7 ", "%window-renamed @7" }) |line| {
        var c: Parser = .{ .buffer = .init(alloc) };
        defer c.deinit();
        for (line) |byte| try testing.expect(try c.put(byte) == null);
        const n = (try c.put('\n')).?;
        try testing.expect(n == .window_renamed);
        try testing.expectEqual(7, n.window_renamed.id);
        try testing.expectEqualStrings("", n.window_renamed.name);
    }

    // Leading spaces after the separator are part of the name.
    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%unlinked-window-renamed @3  x") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .unlinked_window_renamed);
    try testing.expectEqualStrings(" x", n.unlinked_window_renamed.name);
}

test "tmux window-pane-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%window-pane-changed @42 %2") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .window_pane_changed);
    try testing.expectEqual(42, n.window_pane_changed.window_id);
    try testing.expectEqual(2, n.window_pane_changed.pane_id);
}

test "tmux session-window-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%session-window-changed $0 @3") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .session_window_changed);
    try testing.expectEqual(0, n.session_window_changed.session_id);
    try testing.expectEqual(3, n.session_window_changed.window_id);
}

test "tmux client-detached" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-detached /dev/pts/1") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_detached);
    try testing.expectEqualStrings("/dev/pts/1", n.client_detached.client);
}

test "tmux client-session-changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Parser = .{ .buffer = .init(alloc) };
    defer c.deinit();
    for ("%client-session-changed /dev/pts/1 $2 mysession") |byte| try testing.expect(try c.put(byte) == null);
    const n = (try c.put('\n')).?;
    try testing.expect(n == .client_session_changed);
    try testing.expectEqualStrings("/dev/pts/1", n.client_session_changed.client);
    try testing.expectEqual(2, n.client_session_changed.session_id);
    try testing.expectEqualStrings("mysession", n.client_session_changed.name);
}
