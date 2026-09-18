//! State for a single tmux control mode (`tmux -CC`) connection.
//!
//! The surface that saw the DCS 1000p sequence is the "gateway". It owns
//! the pty that speaks the control protocol and shows the control plate
//! (the command menu, logging output and the command prompt). GUI input
//! is translated into tmux commands rather than written as raw bytes on
//! the control pty.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Surface = @import("Surface.zig");

const log = std.log.scoped(.tmux_session);

pub const Session = struct {
    alloc: Allocator,

    /// The gateway surface. Owns the control pty.
    leader: *Surface,

    /// Accumulated input for the "C" command prompt, or null when we're
    /// not prompting.
    prompt: ?std.ArrayList(u8) = null,

    pub fn init(alloc: Allocator, leader: *Surface) Session {
        return .{ .alloc = alloc, .leader = leader };
    }

    pub fn deinit(self: *Session) void {
        if (self.prompt) |*v| v.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn isLeader(self: *const Session, surface: *const Surface) bool {
        return self.leader == surface;
    }

    /// Queue a tmux command on the gateway pty. The command must include
    /// its trailing newline. This goes through the IO thread so that it
    /// can be interleaved with the viewer's own command queue.
    pub fn sendCommand(self: *Session, command: []const u8) void {
        if (command.len == 0) return;
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux command err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_command = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Write bytes straight to the gateway pty, bypassing the viewer's
    /// command queue. Use this when we're about to tear the viewer down
    /// (detach / force-quit): a queued `tmux_command` would be freed with
    /// the viewer and never reach tmux.
    pub fn sendRaw(self: *Session, command: []const u8) void {
        if (command.len == 0) return;
        const data = self.alloc.dupe(u8, command) catch |err| {
            log.warn("failed to allocate tmux raw write err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .write_alloc = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Format and queue a tmux command. The format must produce the
    /// trailing newline.
    pub fn sendCommandFmt(
        self: *Session,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var stack = std.heap.stackFallback(256, self.alloc);
        const alloc = stack.get();
        const command = std.fmt.allocPrint(alloc, fmt, args) catch |err| {
            log.warn("failed to format tmux command err={}", .{err});
            return;
        };
        defer alloc.free(command);
        self.sendCommand(command);
    }

    /// Print text on the gateway terminal without sending anything to
    /// tmux. Used for the control plate.
    pub fn echo(self: *Session, text: []const u8) void {
        if (text.len == 0) return;
        const data = self.alloc.dupe(u8, text) catch |err| {
            log.warn("failed to allocate tmux echo err={}", .{err});
            return;
        };

        self.leader.io.queueMessage(.{ .tmux_echo = .{
            .alloc = self.alloc,
            .data = data,
        } }, .unlocked);
    }

    /// Send raw terminal bytes to a pane as tmux keys. If `pane_id` is
    /// null the session's active pane is targeted.
    ///
    /// Bytes go out as `send-keys -H` codepoints rather than `-l` literals
    /// because tmux's command parser treats `;`, `$`, `#` and quotes as
    /// syntax, so a literal semicolon never reaches the pane.
    pub fn sendKeys(self: *Session, pane_id: ?usize, data: []const u8) void {
        if (data.len == 0) return;

        var stack = std.heap.stackFallback(512, self.alloc);
        const alloc = stack.get();

        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        const writer = &buf.writer;

        writer.writeAll("send-keys") catch return;
        if (pane_id) |id| writer.print(" -t %{d}", .{id}) catch return;
        writer.writeAll(" -H") catch return;

        // Send codepoints, not bytes: `-H` values are Unicode codepoints
        // so tmux would re-encode every byte of a multi-byte sequence.
        var i: usize = 0;
        while (i < data.len) {
            var cp: u21 = data[i];
            var len: usize = 1;
            decode: {
                const seq_len = std.unicode.utf8ByteSequenceLength(
                    data[i],
                ) catch break :decode;
                if (i + seq_len > data.len) break :decode;
                cp = std.unicode.utf8Decode(
                    data[i..][0..seq_len],
                ) catch break :decode;
                len = seq_len;
            }

            writer.print(" 0x{x}", .{cp}) catch return;
            i += len;
        }

        writer.writeByte('\n') catch return;
        self.sendCommand(buf.writer.buffered());
    }

    /// Detach from tmux. Writes go out of band (`sendRaw`) so a
    /// following force-quit can't destroy the viewer before
    /// `detach-client` is flushed to the pty.
    pub fn detach(self: *Session) void {
        self.sendRaw("detach-client\n");
    }
};
