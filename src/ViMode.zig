const std = @import("std");
const terminal = @import("terminal/main.zig");
const input = @import("input.zig");
const PageList = terminal.PageList;
const Pin = PageList.Pin;

const ViMode = @This();

pub const SubMode = enum {
    normal,
    visual,
    visual_line,
    visual_block,
};

pub const ViResult = struct {
    scroll_delta: ?isize = null,
    scroll_top: bool = false,
    scroll_bottom: bool = false,
    selection_changed: bool = false,
    copy_clipboard: bool = false,
    start_search_forward: bool = false,
    start_search_backward: bool = false,
    navigate_search_next: bool = false,
    navigate_search_prev: bool = false,
    exit: bool = false,
    redraw: bool = false,
};

pub const ViewportInfo = struct {
    top: Pin,
    rows: usize,
};

cursor_pin: *Pin,
sub_mode: SubMode = .normal,
count: ?u32 = null,
pending_key: ?u8 = null,
selection_anchor: ?*Pin = null,
marks: [26]?*Pin = .{null} ** 26,
search_direction: enum { forward, backward } = .forward,

pub fn init(cursor_pin: *Pin) ViMode {
    return .{ .cursor_pin = cursor_pin };
}

pub fn deinit(self: *ViMode, pages: *PageList) void {
    pages.untrackPin(self.cursor_pin);
    if (self.selection_anchor) |anchor| {
        pages.untrackPin(anchor);
        self.selection_anchor = null;
    }
    for (&self.marks) |*mark| {
        if (mark.*) |pin| {
            pages.untrackPin(pin);
            mark.* = null;
        }
    }
}

/// Process a key event. Returns side-effects for Surface.
pub fn handleKey(self: *ViMode, t: *terminal.Terminal, vp: ViewportInfo, event: input.KeyEvent) ViResult {
    _ = t;
    _ = vp;
    _ = self;

    // Decode the first codepoint from the UTF-8 text, if any.
    const cp: u21 = if (event.utf8.len > 0) blk: {
        const len = std.unicode.utf8ByteSequenceLength(event.utf8[0]) catch break :blk 0;
        if (event.utf8.len < len) break :blk 0;
        break :blk std.unicode.utf8Decode(event.utf8[0..len]) catch 0;
    } else 0;

    if (event.key == .escape or cp == 'q' or event.key == .enter) {
        return .{ .exit = true, .redraw = true };
    }

    return .{ .redraw = true };
}

test "ViMode init defaults" {
    var vi = ViMode{
        .cursor_pin = undefined,
    };
    try std.testing.expectEqual(SubMode.normal, vi.sub_mode);
    try std.testing.expectEqual(@as(?u32, null), vi.count);
    try std.testing.expectEqual(@as(?u8, null), vi.pending_key);
    _ = &vi;
}
