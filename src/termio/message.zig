const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the messages are IO thread sends are also very few. At the current size
/// we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

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

    /// Resize the window.
    resize: renderer.Size,

    /// Request a size report is sent to the pty ([in-band
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

    /// The types of size reports that we support
    pub const SizeReport = enum {
        mode_2048,
        csi_14_t,
        csi_16_t,
        csi_18_t,
    };
};

/// Creates a union that can be used to accommodate data that fit within an array,
/// are a stable pointer, or require deallocation. This is helpful for thread
/// messaging utilities.
pub fn MessageData(comptime Elem: type, comptime small_size: comptime_int) type {
    return union(enum) {
        pub const Self = @This();

        pub const Small = struct {
            pub const Max = small_size;
            pub const Array = [Max]Elem;
            pub const Len = std.math.IntFittingRange(0, small_size);
            data: Array = undefined,
            len: Len = 0,
        };

        pub const Alloc = struct {
            alloc: Allocator,
            data: []Elem,
        };

        pub const Stable = []const Elem;

        /// A small write where the data fits into this union size.
        small: Small,

        /// A stable pointer so we can just pass the slice directly through.
        /// This is useful i.e. for const data.
        stable: Stable,

        /// Allocated and must be freed with the provided allocator. This
        /// should be rarely used.
        alloc: Alloc,

        /// Initializes the union for a given data type. This will
        /// attempt to fit into a small value if possible, otherwise
        /// will allocate and put into alloc.
        ///
        /// This can't and will never detect stable pointers.
        pub fn init(alloc: Allocator, data: anytype) !Self {
            switch (@typeInfo(@TypeOf(data))) {
                .pointer => |info| {
                    assert(info.size == .slice);
                    assert(info.child == Elem);

                    // If it fits in our small request, do that.
                    if (data.len <= Small.Max) {
                        var buf: Small.Array = undefined;
                        @memcpy(buf[0..data.len], data);
                        return Self{
                            .small = .{
                                .data = buf,
                                .len = @intCast(data.len),
                            },
                        };
                    }

                    // Otherwise, allocate
                    const buf = try alloc.dupe(Elem, data);
                    errdefer alloc.free(buf);
                    return Self{
                        .alloc = .{
                            .alloc = alloc,
                            .data = buf,
                        },
                    };
                },

                else => unreachable,
            }
        }

        pub fn deinit(self: Self) void {
            switch (self) {
                .small, .stable => {},
                .alloc => |v| v.alloc.free(v.data),
            }
        }

        /// Returns a const slice of the data pointed to by this request.
        pub fn slice(self: *const Self) []const Elem {
            return switch (self.*) {
                .small => |*v| v.data[0..v.len],
                .stable => |v| v,
                .alloc => |v| v.data,
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}

test "MessageData init small" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Data = MessageData(u8, 10);
    const input = "hello!";
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .small);
}

test "MessageData init alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Data = MessageData(u8, 10);
    const input = "hello! " ** 100;
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .alloc);
    io.alloc.alloc.free(io.alloc.data);
}

test "MessageData small fits non-u8 sized data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const len = 500;
    const Data = MessageData(u8, len);
    const input: []const u8 = "X" ** len;
    const io = try Data.init(alloc, input);
    try testing.expect(io == .small);
}
