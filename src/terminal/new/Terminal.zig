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

const size = @import("size.zig");
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
rows: size.CellCountInt,
cols: size.CellCountInt,

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
    top: size.CellCountInt,
    bottom: size.CellCountInt,

    // Left/right scroll regions.
    // Precondition: right > left
    // Precondition: right <= cols - 1
    left: size.CellCountInt,
    right: size.CellCountInt,
};

/// Initialize a new terminal.
pub fn init(alloc: Allocator, cols: size.CellCountInt, rows: size.CellCountInt) !Terminal {
    return Terminal{
        .cols = cols,
        .rows = rows,
        .active_screen = .primary,
        // TODO: configurable scrollback
        .screen = try Screen.init(alloc, cols, rows, 10000),
        // No scrollback for the alternate screen
        .secondary_screen = try Screen.init(alloc, cols, rows, 0),
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

/// Print UTF-8 encoded string to the terminal.
pub fn printString(self: *Terminal, str: []const u8) !void {
    const view = try std.unicode.Utf8View.init(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\n' => {
                self.carriageReturn();
                try self.linefeed();
            },

            else => try self.print(cp),
        }
    }
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
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screen.cursor.x > 0)
    grapheme: {
        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme. Otherwise, we can stay in this cell.
        const Prev = struct { cell: *Cell, left: size.CellCountInt };
        const prev: Prev = prev: {
            const left: size.CellCountInt = left: {
                // If we have wraparound, then we always use the prev col
                if (self.modes.get(.wraparound)) break :left 1;

                // If we do not have wraparound, the logic is trickier. If
                // we're not on the last column, then we just use the previous
                // column. Otherwise, we need to check if there is text to
                // figure out if we're attaching to the prev or current.
                if (self.screen.cursor.x != right_limit - 1) break :left 1;
                break :left @intFromBool(!self.screen.cursor.page_cell.hasText());
            };

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            const immediate = self.screen.cursorCellLeft(left);
            break :prev switch (immediate.wide) {
                else => .{ .cell = immediate, .left = left },
                .spacer_tail => .{
                    .cell = self.screen.cursorCellLeft(left + 1),
                    .left = left + 1,
                },
            };
        };

        // If our cell has no content, then this is a new cell and
        // necessarily a grapheme break.
        if (!prev.cell.hasText()) break :grapheme;

        const grapheme_break = brk: {
            var state: unicode.GraphemeBreakState = .{};
            var cp1: u21 = prev.cell.content.codepoint;
            if (prev.cell.hasGrapheme()) {
                const cps = self.screen.cursor.page_offset.page.data.lookupGrapheme(prev.cell).?;
                for (cps) |cp2| {
                    // log.debug("cp1={x} cp2={x}", .{ cp1, cp2 });
                    assert(!unicode.graphemeBreak(cp1, cp2, &state));
                    cp1 = cp2;
                }
            }

            // log.debug("cp1={x} cp2={x} end", .{ cp1, c });
            break :brk unicode.graphemeBreak(cp1, c, &state);
        };

        // If we can NOT break, this means that "c" is part of a grapheme
        // with the previous char.
        if (!grapheme_break) {
            // If this is an emoji variation selector then we need to modify
            // the cell width accordingly. VS16 makes the character wide and
            // VS15 makes it narrow.
            if (c == 0xFE0F or c == 0xFE0E) {
                // This only applies to emoji
                const prev_props = unicode.getProperties(prev.cell.content.codepoint);
                const emoji = prev_props.grapheme_boundary_class == .extended_pictographic;
                if (!emoji) return;

                switch (c) {
                    0xFE0F => wide: {
                        if (prev.cell.wide == .wide) break :wide;

                        // Move our cursor back to the previous. We'll move
                        // the cursor within this block to the proper location.
                        self.screen.cursorLeft(prev.left);

                        // If we don't have space for the wide char, we need
                        // to insert spacers and wrap. Then we just print the wide
                        // char as normal.
                        if (self.screen.cursor.x == right_limit - 1) {
                            if (!self.modes.get(.wraparound)) return;
                            self.printCell(' ', .spacer_head);
                            try self.printWrap();
                        }

                        self.printCell(prev.cell.content.codepoint, .wide);

                        // Write our spacer
                        self.screen.cursorRight(1);
                        self.printCell(' ', .spacer_tail);

                        // Move the cursor again so we're beyond our spacer
                        if (self.screen.cursor.x == right_limit - 1) {
                            self.screen.cursor.pending_wrap = true;
                        } else {
                            self.screen.cursorRight(1);
                        }
                    },

                    0xFE0E => narrow: {
                        // Prev cell is no longer wide
                        if (prev.cell.wide != .wide) break :narrow;
                        prev.cell.wide = .narrow;

                        // Remove the wide spacer tail
                        const cell = self.screen.cursorCellLeft(prev.left - 1);
                        cell.wide = .narrow;

                        break :narrow;
                    },

                    else => unreachable,
                }
            }

            log.debug("c={x} grapheme attach to left={}", .{ c, prev.left });
            try self.screen.cursor.page_offset.page.data.appendGrapheme(
                self.screen.cursor.page_row,
                prev.cell,
                c,
            );
            return;
        }
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

        // Find our previous cell
        const prev = prev: {
            const immediate = self.screen.cursorCellLeft(1);
            if (immediate.wide != .spacer_tail) break :prev immediate;
            break :prev self.screen.cursorCellLeft(2);
        };

        // If our previous cell has no text, just ignore the zero-width character
        if (!prev.hasText()) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // If this is a emoji variation selector, prev must be an emoji
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_props = unicode.getProperties(prev.content.codepoint);
            const emoji = prev_props.grapheme_boundary_class == .extended_pictographic;
            if (!emoji) return;
        }

        try self.screen.cursor.page_offset.page.data.appendGrapheme(
            self.screen.cursor.page_row,
            prev,
            c,
        );
        return;
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
        1 => @call(.always_inline, printCell, .{ self, c, .narrow }),

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => if ((right_limit - self.scrolling_region.left) > 1) {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screen.cursor.x == right_limit - 1) {
                // If we don't have wraparound enabled then we don't print
                // this character at all and don't move the cursor. This is
                // how xterm behaves.
                if (!self.modes.get(.wraparound)) return;

                self.printCell(' ', .spacer_head);
                try self.printWrap();
            }

            self.printCell(c, .wide);
            self.screen.cursorRight(1);
            self.printCell(' ', .spacer_tail);
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We sould prevent this downstream.
            self.printCell(' ', .narrow);
        },

        else => unreachable,
    }

    // If we're at the column limit, then we need to wrap the next time.
    // In this case, we don't move the cursor.
    if (self.screen.cursor.x == right_limit - 1) {
        self.screen.cursor.pending_wrap = true;
        return;
    }

    // Move the cursor
    self.screen.cursorRight(1);
}

fn printCell(
    self: *Terminal,
    unmapped_c: u21,
    wide: Cell.Wide,
) void {
    // TODO: charsets
    const c: u21 = unmapped_c;

    // TODO: prev cell overwriting style, dec refs, etc.
    const cell = self.screen.cursor.page_cell;

    // If the wide property of this cell is the same, then we don't
    // need to do the special handling here because the structure will
    // be the same. If it is NOT the same, then we may need to clear some
    // cells.
    if (cell.wide != wide) {
        switch (cell.wide) {
            // Previous cell was narrow. Do nothing.
            .narrow => {},

            // Previous cell was wide. We need to clear the tail and head.
            .wide => wide: {
                if (self.screen.cursor.x >= self.cols - 1) break :wide;

                const spacer_cell = self.screen.cursorCellRight(1);
                spacer_cell.* = .{ .style_id = self.screen.cursor.style_id };
                if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
                    const head_cell = self.screen.cursorCellEndOfPrev();
                    head_cell.wide = .narrow;
                }
            },

            .spacer_tail => {
                assert(self.screen.cursor.x > 0);

                const wide_cell = self.screen.cursorCellLeft(1);
                wide_cell.* = .{ .style_id = self.screen.cursor.style_id };
                if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
                    const head_cell = self.screen.cursorCellEndOfPrev();
                    head_cell.wide = .narrow;
                }
            },

            // TODO: this case was not handled in the old terminal implementation
            // but it feels like we should do something. investigate other
            // terminals (xterm mainly) and see whats up.
            .spacer_head => {},
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.hasGrapheme()) {
        self.screen.cursor.page_offset.page.data.clearGrapheme(
            self.screen.cursor.page_row,
            cell,
        );
    }

    // Write
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = c },
        .style_id = self.screen.cursor.style_id,
        .wide = wide,
    };

    // If we have non-default style then we need to update the ref count.
    if (self.screen.cursor.style_ref) |ref| {
        ref.* += 1;
    }
}

fn printWrap(self: *Terminal) !void {
    self.screen.cursor.page_row.wrap = true;

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
    self.screen.cursor.page_row.wrap_continuation = true;
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    // Always reset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screen.cursorHorizontalAbsolute(if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screen.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0);
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    try self.index();
    if (self.modes.get(.linefeed)) self.carriageReturn();
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    self.cursorLeft(1);
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
pub fn cursorLeft(self: *Terminal, count_req: usize) void {
    // Wrapping behavior depends on various terminal modes
    const WrapMode = enum { none, reverse, reverse_extended };
    const wrap_mode: WrapMode = wrap_mode: {
        if (!self.modes.get(.wraparound)) break :wrap_mode .none;
        if (self.modes.get(.reverse_wrap_extended)) break :wrap_mode .reverse_extended;
        if (self.modes.get(.reverse_wrap)) break :wrap_mode .reverse;
        break :wrap_mode .none;
    };

    var count: size.CellCountInt = @intCast(@max(count_req, 1));

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screen.cursorLeft(count);
        self.screen.cursor.pending_wrap = false;
        return;
    }

    // If we have a pending wrap state and we are in either reverse wrap
    // modes then we decrement the amount we move by one to match xterm.
    if (self.screen.cursor.pending_wrap) {
        count -= 1;
        self.screen.cursor.pending_wrap = false;
    }

    // The margins we can move to.
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;
    const right_margin = self.scrolling_region.right;
    const left_margin = if (self.screen.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Handle some edge cases when our cursor is already on the left margin.
    if (self.screen.cursor.x == left_margin) {
        switch (wrap_mode) {
            // In reverse mode, if we're already before the top margin
            // then we just set our cursor to the top-left and we're done.
            .reverse => if (self.screen.cursor.y <= top) {
                self.screen.cursorAbsolute(left_margin, top);
                return;
            },

            // Handled in while loop
            .reverse_extended => {},

            // Handled above
            .none => unreachable,
        }
    }

    while (true) {
        // We can move at most to the left margin.
        const max = self.screen.cursor.x - left_margin;

        // We want to move at most the number of columns we have left
        // or our remaining count. Do the move.
        const amount = @min(max, count);
        count -= amount;
        self.screen.cursorLeft(amount);

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screen.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screen.cursorAbsolute(right_margin, bottom);
            count -= 1;
            continue;
        }

        // UNDEFINED TERMINAL BEHAVIOR. This situation is not handled in xterm
        // and currently results in a crash in xterm. Given no other known
        // terminal [to me] implements XTREVWRAP2, I decided to just mimick
        // the behavior of xterm up and not including the crash by wrapping
        // up to the (0, 0) and stopping there. My reasoning is that for an
        // appropriately sized value of "count" this is the behavior that xterm
        // would have. This is unit tested.
        if (self.screen.cursor.y == 0) {
            assert(self.screen.cursor.x == left_margin);
            break;
        }

        // If our previous line is not wrapped then we are done.
        if (wrap_mode != .reverse_extended) {
            if (!self.screen.cursor.page_row.wrap) break;
        }

        self.screen.cursorAbsolute(right_margin, self.screen.cursor.y - 1);
        count -= 1;
    }
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) !void {
    while (self.screen.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screen.cursorRight(1);

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screen.cursor.x)) return;
    }
}

// Same as horizontalTab but moves to the previous tabstop instead of the next.
pub fn horizontalTabBack(self: *Terminal) !void {
    // With origin mode enabled, our leftmost limit is the left margin.
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;

    while (true) {
        // If we're already at the edge of the screen, then we're done.
        if (self.screen.cursor.x <= left_limit) return;

        // Move the cursor left
        self.screen.cursorLeft(1);
        if (self.tabstops.get(self.screen.cursor.x)) return;
    }
}

/// Clear tab stops.
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screen.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screen.cursor.x);
}

/// TODO: test
pub fn tabReset(self: *Terminal) void {
    self.tabstops.reset(TABSTOP_INTERVAL);
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
            try self.screen.cursorDownScroll();
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

// Set Cursor Position. Move cursor to the position indicated
// by row and column (1-indexed). If column is 0, it is adjusted to 1.
// If column is greater than the right-most column it is adjusted to
// the right-most column. If row is 0, it is adjusted to 1. If row is
// greater than the bottom-most row it is adjusted to the bottom-most
// row.
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: size.CellCountInt = 0,
        y_offset: size.CellCountInt = 0,
        x_max: size.CellCountInt,
        y_max: size.CellCountInt,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1, // We need this 1-indexed
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Calculate our new x/y
    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    const x = @min(params.x_max, col + params.x_offset) -| 1;
    const y = @min(params.y_max, row + params.y_offset) -| 1;

    // If the y is unchanged then this is fast pointer math
    if (y == self.screen.cursor.y) {
        if (x > self.screen.cursor.x) {
            self.screen.cursorRight(x - self.screen.cursor.x);
        } else {
            self.screen.cursorLeft(self.screen.cursor.x - x);
        }

        return;
    }

    // If everything changed we do an absolute change which is slightly slower
    self.screen.cursorAbsolute(x, y);
    // log.info("set cursor position: col={} row={}", .{ self.screen.cursor.x, self.screen.cursor.y });
}

/// Set Top and Bottom Margins If bottom is not specified, 0 or bigger than
/// the number of the bottom-most row, it is adjusted to the number of the
/// bottom most row.
///
/// If top < bottom set the top and bottom row of the scroll region according
/// to top and bottom and move the cursor to the top-left cell of the display
/// (when in cursor origin mode is set to the top-left cell of the scroll region).
///
/// Otherwise: Set the top and bottom row of the scroll region to the top-most
/// and bottom-most line of the screen.
///
/// Top and bottom are 1-indexed.
pub fn setTopAndBottomMargin(self: *Terminal, top_req: usize, bottom_req: usize) void {
    const top = @max(1, top_req);
    const bottom = @min(self.rows, if (bottom_req == 0) self.rows else bottom_req);
    if (top >= bottom) return;

    self.scrolling_region.top = @intCast(top - 1);
    self.scrolling_region.bottom = @intCast(bottom - 1);
    self.setCursorPos(1, 1);
}

/// DECSLRM
pub fn setLeftAndRightMargin(self: *Terminal, left_req: usize, right_req: usize) void {
    // We must have this mode enabled to do anything
    if (!self.modes.get(.enable_left_and_right_margin)) return;

    const left = @max(1, left_req);
    const right = @min(self.cols, if (right_req == 0) self.cols else right_req);
    if (left >= right) return;

    self.scrolling_region.left = @intCast(left - 1);
    self.scrolling_region.right = @intCast(right - 1);
    self.setCursorPos(1, 1);
}

/// Scroll the text down by one row.
pub fn scrollDown(self: *Terminal, count: usize) void {
    // Preserve our x/y to restore.
    const old_x = self.screen.cursor.x;
    const old_y = self.screen.cursor.y;
    const old_wrap = self.screen.cursor.pending_wrap;
    defer {
        self.screen.cursorAbsolute(old_x, old_y);
        self.screen.cursor.pending_wrap = old_wrap;
    }

    // Move to the top of the scroll region
    self.screen.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.insertLines(count);
}

/// Insert amount lines at the current cursor row. The contents of the line
/// at the current cursor row and below (to the bottom-most line in the
/// scrolling region) are shifted down by amount lines. The contents of the
/// amount bottom-most lines in the scroll region are lost.
///
/// This unsets the pending wrap state without wrapping. If the current cursor
/// position is outside of the current scroll region it does nothing.
///
/// If amount is greater than the remaining number of lines in the scrolling
/// region it is adjusted down (still allowing for scrolling out every remaining
/// line in the scrolling region)
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// All cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn insertLines(self: *Terminal, count: usize) void {
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom or
        self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // TODO
    if (self.scrolling_region.left > 0 or self.scrolling_region.right < self.cols - 1) {
        @panic("TODO: left and right margin mode");
    }

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);

    // top is just the cursor position. insertLines starts at the cursor
    // so this is our top. We want to shift lines down, down to the bottom
    // of the scroll region.
    const top: [*]Row = @ptrCast(self.screen.cursor.page_row);

    // This is the amount of space at the bottom of the scroll region
    // that will NOT be blank, so we need to shift the correct lines down.
    // "scroll_amount" is the number of such lines.
    const scroll_amount = rem - adjusted_count;
    if (scroll_amount > 0) {
        var y: [*]Row = top + (scroll_amount - 1);

        // TODO: detect active area split across multiple pages

        // We work backwards so we don't overwrite data.
        while (@intFromPtr(y) >= @intFromPtr(top)) : (y -= 1) {
            const src: *Row = @ptrCast(y);
            const dst: *Row = @ptrCast(y + adjusted_count);

            // Swap the src/dst cells. This ensures that our dst gets the proper
            // shifted rows and src gets non-garbage cell data that we can clear.
            const dst_row = dst.*;
            dst.* = src.*;
            src.* = dst_row;
        }
    }

    for (0..adjusted_count) |i| {
        const row: *Row = @ptrCast(top + i);

        // Clear the src row.
        var page = self.screen.cursor.page_offset.page.data;
        const cells = page.getCells(row);

        // If this row has graphemes, then we need go through a slow path
        // and delete the cell graphemes.
        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme()) page.clearGrapheme(row, cell);
            }
            assert(!row.grapheme);
        }

        // TODO: cells should keep bg style of pen
        @memset(cells, .{});
    }

    // Move the cursor to the left margin. But importantly this also
    // forces screen.cursor.page_cell to reload because the rows above
    // shifted cell ofsets so this will ensure the cursor is pointing
    // to the correct cell.
    self.screen.cursorAbsolute(
        self.scrolling_region.left,
        self.screen.cursor.y,
    );

    // Always unset pending wrap
    self.screen.cursor.pending_wrap = false;
}

pub fn eraseChars(self: *Terminal, count_req: usize) void {
    const count = @max(count_req, 1);

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const end = end: {
        const remaining = self.cols - self.screen.cursor.x;
        var end = @min(remaining, count);

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != remaining) {
            const last = self.screen.cursorCellRight(end - 1);
            if (last.wide == .wide) end += 1;
        }

        break :end end;
    };

    // Clear the cells
    // TODO: clear with current bg color
    const cells: [*]Cell = @ptrCast(self.screen.cursor.page_cell);
    @memset(cells[0..end], .{});

    // This resets the soft-wrap of this line
    self.screen.cursor.page_row.wrap = false;

    // This resets the pending wrap state
    self.screen.cursor.pending_wrap = false;

    // TODO: protected mode, see below for old logic
    //
    // const pen: Screen.Cell = .{
    //     .bg = self.screen.cursor.pen.bg,
    // };
    //
    // // If we never had a protection mode, then we can assume no cells
    // // are protected and go with the fast path. If the last protection
    // // mode was not ISO we also always ignore protection attributes.
    // if (self.screen.protected_mode != .iso) {
    //     row.fillSlice(pen, self.screen.cursor.x, end);
    // }
    //
    // // We had a protection mode at some point. We must go through each
    // // cell and check its protection attribute.
    // for (self.screen.cursor.x..end) |x| {
    //     const cell = row.getCellPtr(x);
    //     if (cell.attrs.protected) continue;
    //     cell.* = pen;
    // }
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

test "Terminal: input that forces scroll" {
    const alloc = testing.allocator;
    var t = try init(alloc, 1, 5);
    defer t.deinit(alloc);

    // Basic grid writing
    for ("abcdef") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 4), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("b\nc\nd\ne\nf", str);
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
test "Terminal: print single very long line" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // This would crash for issue 1400. So the assertion here is
    // that we simply do not crash.
    for (0..1000) |_| try t.print('x');
}

test "Terminal: print wide char" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print wide char in single-width terminal" {
    var t = try init(testing.allocator, 1, 80);
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expect(t.screen.cursor.pending_wrap);

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, ' '), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    t.setCursorPos(0, 0);
    try t.print('A'); // Smiley face

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.x);

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print over wide spacer tail" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    try t.print('橋');
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'X'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }
}

test "Terminal: print multicodepoint grapheme, disabled mode 2027" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 6 cells taken up
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 6), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, ' '), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.page.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F469), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, ' '), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.page.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F467), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(list_cell.page.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, ' '), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.page.data.lookupGrapheme(cell) == null);
    }
}

test "Terminal: VS16 doesn't make character with 2027 disabled" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS16 non-grapheme" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
    }
}

test "Terminal: print multicodepoint grapheme, mode 2027" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 4), cps.len);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, ' '), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS15 to make narrow character" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain
    try t.print(0xFE0E); // VS15 to make narrow

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("⛈︎", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x26C8), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS16 to make wide character with mode 2027" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS16 repeated with mode 2027" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide
    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️❤️", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS16 grapheme" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print invalid VS16 with second char" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);
    try t.print('y');

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'y'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: overwrite grapheme should clear grapheme data" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain
    try t.print(0xFE0E); // VS15 to make narrow
    t.setCursorPos(1, 1);
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.allocator, 5, 2);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.setCursorPos(0, 0);

    // Make newlines so we create scrollback
    // 3 pushes hello off the screen
    try t.index();
    try t.index();
    try t.index();
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to the top
    t.screen.scroll(.{ .top = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    t.screen.scroll(.{ .active = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: soft wrap" {
    var t = try init(testing.allocator, 3, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}

test "Terminal: disabled wraparound with wide char and one space" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screen.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA", str);
    }

    // Make sure we printed nothing
    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: disabled wraparound with wide char and no space" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAAA");
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screen.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAA", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: disabled wraparound with wide grapheme and half space" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screen.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA❤", str);
    }

    {
        const list_cell = t.screen.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '❤'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print right margin wrap" {
    var t = try init(testing.allocator, 10, 5);
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }
}

test "Terminal: print right margin outside" {
    var t = try init(testing.allocator, 10, 5);
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 6);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("12345XY89", str);
    }
}

test "Terminal: print right margin outside wrap" {
    var t = try init(testing.allocator, 10, 5);
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 10);
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456789X\n  Y", str);
    }
}

test "Terminal: linefeed and carriage return" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}

test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    try t.linefeed();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

test "Terminal: linefeed mode automatic carriage return" {
    var t = try init(testing.allocator, 10, 10);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    t.modes.set(.linefeed, true);
    try t.printString("123456");
    try t.linefeed();
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456\nX", str);
    }
}

test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.modes.set(.origin, true);
    t.screen.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

test "Terminal: backspace" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // BS
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}

test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    // HT
    try t.print('1');
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 8), t.screen.cursor.x);

    // HT
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screen.cursor.x);

    // HT at the end
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
}

test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.setCursorPos(t.screen.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y, 9);
    try t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}

test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(t.screen.cursor.y, 1);
    try t.print('X');
    try t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}

test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    // Edge of screen
    t.setCursorPos(t.screen.cursor.y, 20);

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 16), t.screen.cursor.x);

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 8), t.screen.cursor.x);

    // HT
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.setCursorPos(t.screen.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y, 9);
    try t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}

test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(1, 2);
    try t.print('X');
    try t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}

test "Terminal: cursorPos resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.setCursorPos(1, 1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE", str);
    }
}

test "Terminal: cursorPos off the screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(500, 500);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\n    X", str);
    }
}

test "Terminal: cursorPos relative to origin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}

test "Terminal: cursorPos relative to origin with left/right" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n  X", str);
    }
}

test "Terminal: cursorPos limits with full scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.top = 2;
    t.scrolling_region.bottom = 3;
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.modes.set(.origin, true);
    t.setCursorPos(500, 500);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n    X", str);
    }
}

// Probably outdated, but dates back to the original terminal implementation.
test "Terminal: setCursorPos (original test)" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Setting it to 0 should keep it zero (1 based)
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Should clamp to size
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    // Should reset pending wrap
    t.setCursorPos(0, 80);
    try t.print('c');
    try testing.expect(t.screen.cursor.pending_wrap);
    t.setCursorPos(0, 80);
    try testing.expect(!t.screen.cursor.pending_wrap);

    // Origin mode
    t.modes.set(.origin, true);

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    // Set the scroll region
    // TODO
    // t.setTopAndBottomMargin(10, t.rows);
    // t.setCursorPos(0, 0);
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);
    //
    // t.setCursorPos(1, 1);
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);
    //
    // t.setCursorPos(100, 0);
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);
    //
    // t.setTopAndBottomMargin(10, 11);
    // t.setCursorPos(2, 0);
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 10), t.screen.cursor.y);
}

test "Terminal: setTopAndBottomMargin simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(0, 0);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top only" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 0);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top and bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(1, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top equal to bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(0, 0);
    t.eraseChars(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" BC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines (legacy test)" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert two lines
    t.insertLines(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

test "Terminal: insertLines zero" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    t.insertLines(0);
}

test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.carriageReturn();
    try t.linefeed();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    try t.print('E');

    // Move to row 2
    t.setCursorPos(2, 1);

    // Insert a bunch of  lines
    t.insertLines(20);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.insertLines(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}

test "Terminal: insertLines multi-codepoint graphemes" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\n👨‍👩‍👧\nGHI", str);
    }
}

test "Terminal: scrollDown simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    const cursor = t.screen.cursor;
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screen.cursor.x);
    try testing.expectEqual(cursor.y, t.screen.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: scrollDown outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(3, 4);
    t.setCursorPos(2, 2);
    const cursor = t.screen.cursor;
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screen.cursor.x);
    try testing.expectEqual(cursor.y, t.screen.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\n\nGHI", str);
    }
}

test "Terminal: scrollDown preserves pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 10);
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    t.scrollDown(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    A\n    B\nX   C", str);
    }
}

test "Terminal: eraseChars simple operation" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X C", str);
    }
}

test "Terminal: eraseChars minimum one" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(0);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC", str);
    }
}

test "Terminal: eraseChars beyond screen edge" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseChars(10);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: eraseChars wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('橋');
    for ("BC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X BC", str);
    }
}
