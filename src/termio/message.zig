const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~56 bytes at the time of writing this comment),
/// but the number of messages we send to the IO thread is also very small.
/// At the current size we can queue 18,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    /// Request a color scheme report is sent to the PTY.
    color_scheme_report: struct {
        /// Force write the current color scheme
        force: bool,
    },

    /// Request a visibility report is sent to the PTY.
    visibility_report: struct {
        /// The visibility state to report.
        visible: bool,

        /// Send the report even when mode 2033 is disabled.
        force: bool,
    },

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash: void,

    /// The derived configuration to update the implementation with. This
    /// is allocated via the allocator and is expected to be freed when done.
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// Resize the terminal grid, renderer, and child PTY.
    resize: renderer.Size,

    /// Resize only the terminal grid and renderer during an interactive
    /// presentation change. The child PTY is committed separately so a live
    /// drag does not generate a SIGWINCH/output-redraw storm.
    resize_live: renderer.Size,

    /// Publish the final interactive size to the child PTY. The IO thread also
    /// applies this visual size first if a coalesced live update is pending.
    resize_commit: renderer.Size,

    /// Request a size report is sent to the PTY ([in-band
    /// size report, mode 2048](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) and
    /// [XTWINOPS](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps;Ps;Ps-t.1EB0)).
    size_report: SizeReport,

    /// Clear the screen.
    clear_screen: struct {
        /// Include clearing the history
        history: bool,
    },

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Selection scrolling. If this is set to true then the termio
    /// thread starts a timer that will trigger a `selection_scroll_tick`
    /// message back to the surface. This ping/pong is because the
    /// surface thread doesn't have access to an event loop from libghostty.
    selection_scroll: bool,

    /// Jump forward/backward n prompts.
    jump_to_prompt: isize,

    /// Send this when a synchronized output mode is started. This will
    /// start the timer so that the output mode is disabled after a
    /// period of time so that a bad actor can't hang the terminal.
    start_synchronized_output: void,

    /// Enable or disable linefeed mode (mode 20).
    linefeed_mode: bool,

    /// The surface gained or lost focus.
    focused: bool,

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// User input captured for a specific durable-session connection generation.
    /// The generation must not be refreshed when the IO thread consumes this.
    omg_session_write: struct {
        generation: u64,
        data: WriteReq,
    },

    /// Returns true for the three untagged write messages.
    pub fn isWriteRequest(self: *const Message) bool {
        return switch (self.*) {
            .write_small, .write_stable, .write_alloc => true,
            else => false,
        };
    }

    /// Tags a write with the generation observed when it entered the IO mailbox.
    /// The payload ownership transfers to the returned message.
    pub fn withOmgSessionGeneration(self: Message, generation: u64) ?Message {
        return switch (self) {
            .write_small => |data| .{ .omg_session_write = .{
                .generation = generation,
                .data = .{ .small = data },
            } },
            .write_stable => |data| .{ .omg_session_write = .{
                .generation = generation,
                .data = .{ .stable = data },
            } },
            .write_alloc => |data| .{ .omg_session_write = .{
                .generation = generation,
                .data = .{ .alloc = data },
            } },
            else => null,
        };
    }

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }

    /// Free resources owned by a message that will not be processed.
    /// The message is invalid after this call.
    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.ptr.deinit();
                v.alloc.destroy(v.ptr);
            },
            .write_alloc => |v| v.alloc.free(v.data),
            .omg_session_write => |v| v.data.deinit(),
            else => {},
        }
    }

    /// The types of size reports that we support.
    pub const SizeReport = terminal.size_report.Style;
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 56), @sizeOf(Message));
}

test "generation-tagged runtime writes preserve payload and ownership" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const stable: []const u8 = "\x1b[A";
    const stable_message = Message{ .write_stable = stable };
    const tagged_stable = stable_message.withOmgSessionGeneration(7).?;
    try testing.expectEqual(@as(u64, 7), tagged_stable.omg_session_write.generation);
    try testing.expectEqualStrings(stable, tagged_stable.omg_session_write.data.slice());

    const allocated = try alloc.dupe(u8, "a user paste larger than the inline write buffer");
    const allocated_message = Message{ .write_alloc = .{
        .alloc = alloc,
        .data = allocated,
    } };
    var tagged_allocated = allocated_message.withOmgSessionGeneration(9).?;
    try testing.expectEqual(@as(u64, 9), tagged_allocated.omg_session_write.generation);
    try testing.expectEqualStrings(
        "a user paste larger than the inline write buffer",
        tagged_allocated.omg_session_write.data.slice(),
    );
    tagged_allocated.deinit();

    try testing.expect(stable_message.withOmgSessionGeneration(10) != null);
    const non_write = Message{ .focused = true };
    try testing.expect(non_write.withOmgSessionGeneration(10) == null);
}
