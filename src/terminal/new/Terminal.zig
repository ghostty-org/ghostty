//! The primary terminal emulation structure. This represents a single
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const unicode = @import("../../unicode/main.zig");

const ansi = @import("../ansi.zig");
const modes = @import("../modes.zig");
const charsets = @import("../charsets.zig");
const csi = @import("../csi.zig");
const kitty = @import("../kitty.zig");
const sgr = @import("../sgr.zig");
const Tabstops = @import("../Tabstops.zig");
const color = @import("../color.zig");
const mouse_shape = @import("../mouse_shape.zig");

const pagepkg = @import("page.zig");
const style = @import("style.zig");
const Screen = @import("Screen.zig");
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// Screen type is an enum that tracks whether a screen is primary or alternate.
pub const ScreenType = enum {
    primary,
    alternate,
};

/// The semantic prompt type. This is used when tracking a line type and
/// requires integration with the shell. By default, we mark a line as "none"
/// meaning we don't know what type it is.
///
/// See: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
pub const SemanticPrompt = enum {
    prompt,
    prompt_continuation,
    input,
    command,
};

/// Screen is the current screen state. The "active_screen" field says what
/// the current screen is. The backup screen is the opposite of the active
/// screen.
active_screen: ScreenType,
screen: Screen,
secondary_screen: Screen,

/// Whether we're currently writing to the status line (DECSASD and DECSSDT).
/// We don't support a status line currently so we just black hole this
/// data so that it doesn't mess up our main display.
status_display: ansi.StatusDisplay = .main,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: usize,
cols: usize,

/// The size of the screen in pixels. This is used for pty events and images
width_px: u32 = 0,
height_px: u32 = 0,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The last reported pwd, if any.
pwd: std.ArrayList(u8),

/// The default color palette. This is only modified by changing the config file
/// and is used to reset the palette when receiving an OSC 104 command.
default_palette: color.Palette = color.default,

/// The color palette to use. The mask indicates which palette indices have been
/// modified with OSC 4
color_palette: struct {
    const Mask = std.StaticBitSet(@typeInfo(color.Palette).Array.len);
    colors: color.Palette = color.default,
    mask: Mask = Mask.initEmpty(),
} = .{},

/// The previous printed character. This is used for the repeat previous
/// char CSI (ESC [ <n> b).
previous_char: ?u21 = null,

/// The modes that this terminal currently has active.
modes: modes.ModeState = .{},

/// The most recently set mouse shape for the terminal.
mouse_shape: mouse_shape.MouseShape = .text,

/// These are just a packed set of flags we may set on the terminal.
flags: packed struct {
    // This isn't a mode, this is set by OSC 133 using the "A" event.
    // If this is true, it tells us that the shell supports redrawing
    // the prompt and that when we resize, if the cursor is at a prompt,
    // then we should clear the screen below and allow the shell to redraw.
    shell_redraws_prompt: bool = false,

    // This is set via ESC[4;2m. Any other modify key mode just sets
    // this to false and we act in mode 1 by default.
    modify_other_keys_2: bool = false,

    /// The mouse event mode and format. These are set to the last
    /// set mode in modes. You can't get the right event/format to use
    /// based on modes alone because modes don't show you what order
    /// this was called so we have to track it separately.
    mouse_event: MouseEvents = .none,
    mouse_format: MouseFormat = .x10,

    /// Set via the XTSHIFTESCAPE sequence. If true (XTSHIFTESCAPE = 1)
    /// then we want to capture the shift key for the mouse protocol
    /// if the configuration allows it.
    mouse_shift_capture: enum { null, false, true } = .null,
} = .{},

/// The event types that can be reported for mouse-related activities.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseEvents = enum(u3) {
    none = 0,
    x10 = 1, // 9
    normal = 2, // 1000
    button = 3, // 1002
    any = 4, // 1003

    /// Returns true if this event sends motion events.
    pub fn motion(self: MouseEvents) bool {
        return self == .button or self == .any;
    }
};

/// The format of mouse events when enabled.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseFormat = enum(u3) {
    x10 = 0,
    utf8 = 1, // 1005
    sgr = 2, // 1006
    urxvt = 3, // 1015
    sgr_pixels = 4, // 1016
};

/// Scrolling region is the area of the screen designated where scrolling
/// occurs. When scrolling the screen, only this viewport is scrolled.
pub const ScrollingRegion = struct {
    // Top and bottom of the scroll region (0-indexed)
    // Precondition: top < bottom
    top: usize,
    bottom: usize,

    // Left/right scroll regions.
    // Precondition: right > left
    // Precondition: right <= cols - 1
    left: usize,
    right: usize,
};

/// Initialize a new terminal.
pub fn init(alloc: Allocator, cols: usize, rows: usize) !Terminal {
    return Terminal{
        .cols = cols,
        .rows = rows,
        .active_screen = .primary,
        // TODO: configurable scrollback
        .screen = try Screen.init(alloc, rows, cols, 10000),
        // No scrollback for the alternate screen
        .secondary_screen = try Screen.init(alloc, rows, cols, 0),
        .tabstops = try Tabstops.init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = std.ArrayList(u8).init(alloc),
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screen.deinit();
    self.secondary_screen.deinit();
    self.pwd.deinit();
    self.* = undefined;
}

pub fn print(self: *Terminal, c: u21) !void {
    // log.debug("print={x} y={} x={}", .{ c, self.screen.cursor.y, self.screen.cursor.x });

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) return;

    // Our right margin depends where our cursor is now.
    const right_limit = if (self.screen.cursor.x > self.scrolling_region.right)
        self.cols
    else
        self.scrolling_region.right + 1;

    // Perform grapheme clustering if grapheme support is enabled (mode 2027).
    // This is MUCH slower than the normal path so the conditional below is
    // purposely ordered in least-likely to most-likely so we can drop out
    // as quickly as possible.
    if (c > 255 and self.modes.get(.grapheme_cluster) and self.screen.cursor.x > 0) {
        @panic("TODO: graphemes");
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly. We have a fast-path for
    // byte-sized characters since they're so common. We can ignore
    // control characters because they're always filtered prior.
    const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);

    // Note: it is possible to have a width of "3" and a width of "-1"
    // from ziglyph. We should look into those cases and handle them
    // appropriately.
    assert(width <= 2);
    // log.debug("c={x} width={}", .{ c, width });

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        // If we have grapheme clustering enabled, we don't blindly attach
        // any zero width character to our cells and we instead just ignore
        // it.
        if (self.modes.get(.grapheme_cluster)) return;

        // If we're at cell zero, then this is malformed data and we don't
        // print anything or even store this. Zero-width characters are ALWAYS
        // attached to some other non-zero-width character at the time of
        // writing.
        if (self.screen.cursor.x == 0) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        @panic("TODO: zero-width characters");
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screen.cursor.pending_wrap and self.modes.get(.wraparound)) {
        try self.printWrap();
    }

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screen.cursor.x + width < self.cols)
    {
        @panic("TODO: insert mode");
        //self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => @call(.always_inline, printCell, .{ self, c }),

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => @panic("TODO: wide characters"),

        else => unreachable,
    }

    // If we're at the column limit, then we need to wrap the next time.
    // In this case, we don't move the cursor.
    if (self.screen.cursor.x == right_limit - 1) {
        self.screen.cursor.pending_wrap = true;
        return;
    }

    // Move the cursor
    self.screen.cursorRight();
}

fn printCell(self: *Terminal, unmapped_c: u21) void {
    // TODO: charsets
    const c: u21 = unmapped_c;

    // If this cell is wide char then we need to clear it.
    // We ignore wide spacer HEADS because we can just write
    // single-width characters into that.
    // if (cell.attrs.wide) {
    //     const x = self.screen.cursor.x + 1;
    //     if (x < self.cols) {
    //         const spacer_cell = row.getCellPtr(x);
    //         spacer_cell.* = self.screen.cursor.pen;
    //     }
    //
    //     if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
    //         self.clearWideSpacerHead();
    //     }
    // } else if (cell.attrs.wide_spacer_tail) {
    //     assert(self.screen.cursor.x > 0);
    //     const x = self.screen.cursor.x - 1;
    //
    //     const wide_cell = row.getCellPtr(x);
    //     wide_cell.* = self.screen.cursor.pen;
    //
    //     if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
    //         self.clearWideSpacerHead();
    //     }
    // }

    // If the prior value had graphemes, clear those
    //if (cell.attrs.grapheme) row.clearGraphemes(self.screen.cursor.x);

    // TODO: prev cell overwriting style

    // Write
    self.screen.cursor.page_cell.* = .{
        .style_id = self.screen.cursor.style_id,
        .codepoint = c,
    };

    // If we have non-default style then we need to update the ref count.
    if (self.screen.cursor.style_ref) |ref| {
        ref.* += 1;
    }
}

fn printWrap(self: *Terminal) !void {
    self.screen.cursor.page_row.flags.wrap = true;

    // Get the old semantic prompt so we can extend it to the next
    // line. We need to do this before we index() because we may
    // modify memory.
    // TODO(mitchellh): before merge
    //const old_prompt = row.getSemanticPrompt();

    // Move to the next line
    try self.index();
    self.screen.cursorHorizontalAbsolute(self.scrolling_region.left);

    // TODO(mitchellh): before merge
    // New line must inherit semantic prompt of the old line
    // const new_row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    // new_row.setSemanticPrompt(old_prompt);
    self.screen.cursor.page_row.flags.wrap_continuation = true;
}

/// Move the cursor to the next line in the scrolling region, possibly scrolling.
///
/// If the cursor is outside of the scrolling region: move the cursor one line
/// down if it is not on the bottom-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///   If the cursor is on the bottom-most line of the scrolling region:
///     invoke scroll up with amount=1
///   If the cursor is not on the bottom-most line of the scrolling region:
///     move the cursor one line down
///
/// This unsets the pending wrap state without wrapping.
pub fn index(self: *Terminal) !void {
    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Outside of the scroll region we move the cursor one line down.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom)
    {
        // We only move down if we're not already at the bottom of
        // the screen.
        if (self.screen.cursor.y < self.rows - 1) {
            self.screen.cursorDown();
        }

        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (self.screen.cursor.y == self.scrolling_region.bottom and
        self.screen.cursor.x >= self.scrolling_region.left and
        self.screen.cursor.x <= self.scrolling_region.right)
    {
        // If our scrolling region is the full screen, we create scrollback.
        // Otherwise, we simply scroll the region.
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.bottom == self.rows - 1 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1)
        {
            @panic("TODO: scroll screen");
            //try self.screen.scroll(.{ .screen = 1 });
        } else {
            @panic("TODO: scroll up");
            //try self.scrollUp(1);
        }

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    if (self.screen.cursor.y < self.scrolling_region.bottom) {
        self.screen.cursorDown();
    }
}

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screen.dumpStringAlloc(alloc, .{ .viewport = .{} });
}

test "Terminal: input with no control characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, 40, 40);
    defer t.deinit(alloc);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "Terminal: input with basic wraparound" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 40);
    defer t.deinit(alloc);

    // Basic grid writing
    for ("helloworldabc12") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screen.cursor.x);
    try testing.expect(t.screen.cursor.pending_wrap);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\nabc12", str);
    }
}

test "Terminal: zero-width character at start" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // This used to crash the terminal. This is not allowed so we should
    // just ignore it.
    try t.print(0x200D);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

// https://github.com/mitchellh/ghostty/issues/1400
// test "Terminal: print single very long line" {
//     var t = try init(testing.allocator, 5, 5);
//     defer t.deinit(testing.allocator);
//
//     // This would crash for issue 1400. So the assertion here is
//     // that we simply do not crash.
//     for (0..500) |_| try t.print('x');
// }