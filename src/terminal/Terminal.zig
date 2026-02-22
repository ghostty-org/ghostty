//! The primary terminal emulation structure. This represents a single
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/main.zig");
const uucode = @import("uucode");

const ansi = @import("ansi.zig");
const modespkg = @import("modes.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const osc = @import("osc.zig");
const point = @import("point.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const color = @import("color.zig");
const mouse_shape_pkg = @import("mouse_shape.zig");
const ReadonlyHandler = @import("stream_readonly.zig").Handler;
const ReadonlyStream = @import("stream_readonly.zig").Stream;

const size = @import("size.zig");
const pagepkg = @import("page.zig");
const style = @import("style.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Page = pagepkg.Page;
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// The set of screens behind this terminal (e.g. primary vs alternate).
screens: ScreenSet,

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

/// The color state for this terminal.
colors: Colors,

/// The previous printed character. This is used for the repeat previous
/// char CSI (ESC [ <n> b).
previous_char: ?u21 = null,

/// The modes that this terminal currently has active.
modes: modespkg.ModeState = .{},

/// The most recently set mouse shape for the terminal.
mouse_shape: mouse_shape_pkg.MouseShape = .text,

/// These are just a packed set of flags we may set on the terminal.
flags: packed struct {
    // This supports a Kitty extension where programs using semantic
    // prompts (OSC133) can annotate their new prompts with `redraw=0` to
    // disable clearing the prompt on resize.
    shell_redraws_prompt: osc.semantic_prompt.Redraw = .true,

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
    mouse_shift_capture: enum(u2) { null, false, true } = .null,

    /// True if the window is focused.
    focused: bool = true,

    /// True if the terminal is in a password entry mode. This is set
    /// to true based on termios state. This is set
    /// to true based on termios state.
    password_input: bool = false,

    /// True if the terminal should perform selection scrolling.
    selection_scroll: bool = false,

    /// Dirty flag used only by the search thread. The renderer is expected
    /// to set this to true if the viewport was dirty as it was rendering.
    /// This is used by the search thread to more efficiently re-search the
    /// viewport and active area.
    ///
    /// Since the renderer is going to inspect the viewport/active area ANYWAYS,
    /// this lets our search thread do less work and hold the lock less time,
    /// resulting in more throughput for everything.
    search_viewport_dirty: bool = false,

    /// Dirty flags for the renderer.
    dirty: Dirty = .{},
} = .{},

/// The various color configurations a terminal maintains and that can
/// be set dynamically via OSC, with defaults usually coming from a
/// configuration.
pub const Colors = struct {
    background: color.DynamicRGB,
    foreground: color.DynamicRGB,
    cursor: color.DynamicRGB,
    palette: color.DynamicPalette,

    pub const default: Colors = .{
        .background = .unset,
        .foreground = .unset,
        .cursor = .unset,
        .palette = .default,
    };
};

/// This is a set of dirty flags the renderer can use to determine
/// what parts of the screen need to be redrawn. It is up to the renderer
/// to clear these flags.
///
/// This only contains dirty flags for terminal state, not for the screen
/// state. The screen state has its own dirty flags.
pub const Dirty = packed struct {
    /// Set when the color palette is modified in any way.
    palette: bool = false,

    /// Set when the reverse colors mode is modified.
    reverse_colors: bool = false,

    /// Screen clear of some kind. This can be due to a screen change,
    /// erase display, etc.
    clear: bool = false,

    /// Set when the pre-edit is modified.
    preedit: bool = false,
};

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

pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize = 10_000,
    colors: Colors = .default,

    /// The default mode state. When the terminal gets a reset, it
    /// will revert back to this state.
    default_modes: modespkg.ModePacked = .{},
};

/// Initialize a new terminal.
pub fn init(
    alloc: Allocator,
    opts: Options,
) !Terminal {
    const cols = opts.cols;
    const rows = opts.rows;

    var screen_set: ScreenSet = try .init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer screen_set.deinit(alloc);

    return .{
        .cols = cols,
        .rows = rows,
        .screens = screen_set,
        .tabstops = try .init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = .empty,
        .colors = opts.colors,
        .modes = .{
            .values = opts.default_modes,
            .default = opts.default_modes,
        },
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screens.deinit(alloc);
    self.pwd.deinit(alloc);
    self.* = undefined;
}

/// Return a terminal.Stream that can process VT streams and update this
/// terminal state. The streams will only process read-only data that
/// modifies terminal state. Sequences that query or otherwise require
/// output will be ignored.
pub fn vtStream(self: *Terminal) ReadonlyStream {
    return .initAlloc(self.gpa(), self.vtHandler());
}

/// This is the handler-side only for vtStream.
pub fn vtHandler(self: *Terminal) ReadonlyHandler {
    return .init(self);
}

/// The general allocator we should use for this terminal.
fn gpa(self: *Terminal) Allocator {
    return self.screens.active.alloc;
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

/// Print the previous printed character a repeated amount of times.
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    if (self.previous_char) |c| {
        const count = @max(count_req, 1);
        for (0..count) |_| try self.print(c);
    }
}

pub fn print(self: *Terminal, c: u21) !void {
    // log.debug("print={x} y={} x={}", .{ c, self.screens.active.cursor.y, self.screens.active.cursor.x });

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) {
        @branchHint(.cold);
        return;
    }

    // After doing any printing, wrapping, scrolling, etc. we want to ensure
    // that our screen remains in a consistent state.
    defer self.screens.active.assertIntegrity();

    // Our right margin depends where our cursor is now.
    const right_limit = if (self.screens.active.cursor.x > self.scrolling_region.right)
        self.cols
    else
        self.scrolling_region.right + 1;

    // Perform grapheme clustering if grapheme support is enabled (mode 2027).
    // This is MUCH slower than the normal path so the conditional below is
    // purposely ordered in least-likely to most-likely so we can drop out
    // as quickly as possible.
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screens.active.cursor.x > 0)
    grapheme: {
        @branchHint(.unlikely);
        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme, and will be appending to prev.cell. Otherwise, we are
        // in a new cell.
        const Prev = struct { cell: *Cell, left: size.CellCountInt };
        var prev: Prev = prev: {
            const left: size.CellCountInt = left: {
                // If we have wraparound, then we use the prev col unless
                // there's a pending wrap, in which case we use the current.
                if (self.modes.get(.wraparound)) {
                    break :left @intFromBool(!self.screens.active.cursor.pending_wrap);
                }

                // If we do not have wraparound, the logic is trickier. If
                // we're not on the last column, then we just use the previous
                // column. Otherwise, we need to check if there is text to
                // figure out if we're attaching to the prev or current.
                if (self.screens.active.cursor.x != right_limit - 1) break :left 1;
                break :left @intFromBool(self.screens.active.cursor.page_cell.codepoint() == 0);
            };

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            const immediate = self.screens.active.cursorCellLeft(left);
            break :prev switch (immediate.wide) {
                else => .{ .cell = immediate, .left = left },
                .spacer_tail => .{
                    .cell = self.screens.active.cursorCellLeft(left + 1),
                    .left = left + 1,
                },
            };
        };

        // If our cell has no content, then this is a new cell and
        // necessarily a grapheme break.
        if (prev.cell.codepoint() == 0) break :grapheme;

        const grapheme_break = brk: {
            var state: uucode.grapheme.BreakState = .default;
            var cp1: u21 = prev.cell.content.codepoint;
            if (prev.cell.hasGrapheme()) {
                const cps = self.screens.active.cursor.page_pin.node.data.lookupGrapheme(prev.cell).?;
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
            var desired_wide: enum { no_change, wide, narrow } = .no_change;

            // If this is an emoji variation selector then we need to modify
            // the cell width accordingly. VS16 makes the character wide and
            // VS15 makes it narrow.
            if (c == 0xFE0F or c == 0xFE0E) {
                const prev_props = unicode.table.get(prev.cell.content.codepoint);
                // Check if it is a valid variation sequence in
                // emoji-variation-sequences.txt, and if not, ignore the char.
                if (!prev_props.emoji_vs_base) return;

                switch (c) {
                    0xFE0F => desired_wide = .wide,
                    0xFE0E => desired_wide = .narrow,
                    else => unreachable,
                }
            } else if (!unicode.table.get(c).width_zero_in_grapheme) {
                // If we have a code point that contributes to the width of a
                // grapheme, it necessarily means that we're at least at width
                // 2, since the first code point must be at least width 1 to
                // start. (Note that Prepend code points could effectively mean
                // the first code point should be width 0, but we don't handle
                // that yet.)
                desired_wide = .wide;
            }

            switch (desired_wide) {
                .wide => wide: {
                    if (prev.cell.wide == .wide) break :wide;

                    // Move our cursor back to the previous. We'll move
                    // the cursor within this block to the proper location.
                    self.screens.active.cursorLeft(prev.left);

                    // If we don't have space for the wide char, we need to
                    // insert spacers and wrap. We need special handling if the
                    // previous cell has grapheme data.
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        if (!self.modes.get(.wraparound)) return;

                        const prev_cp = prev.cell.content.codepoint;

                        if (prev.cell.hasGrapheme()) {
                            // This is like printCell but without clearing the
                            // grapheme data from the cell, so we can move it
                            // later.
                            prev.cell.wide = if (right_limit == self.cols) .spacer_head else .narrow;
                            prev.cell.content.codepoint = 0;

                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            const new_pin = self.screens.active.cursor.page_pin.*;
                            const new_rac = new_pin.rowAndCell();

                            transfer_graphemes: {
                                var old_pin = self.screens.active.cursor.page_pin.up(1) orelse break :transfer_graphemes;
                                old_pin.x = right_limit - 1;
                                const old_rac = old_pin.rowAndCell();

                                if (new_pin.node == old_pin.node) {
                                    new_pin.node.data.moveGrapheme(prev.cell, new_rac.cell);
                                    prev.cell.content_tag = .codepoint;
                                    new_rac.cell.content_tag = .codepoint_grapheme;
                                    new_rac.row.grapheme = true;
                                } else {
                                    const cps = old_pin.node.data.lookupGrapheme(old_rac.cell).?;
                                    for (cps) |cp| {
                                        try self.screens.active.appendGrapheme(new_rac.cell, cp);
                                    }
                                    old_pin.node.data.clearGrapheme(old_rac.cell);
                                }

                                old_pin.node.data.updateRowGraphemeFlag(old_rac.row);
                            }

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = new_rac.cell;
                        } else {
                            self.printCell(
                                0,
                                if (right_limit == self.cols) .spacer_head else .narrow,
                            );
                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = self.screens.active.cursor.page_cell;
                        }
                    } else {
                        prev.cell.wide = .wide;
                    }

                    // Write our spacer, since prev.cell is now wide
                    self.screens.active.cursorRight(1);
                    self.printCell(0, .spacer_tail);

                    // Move the cursor again so we're beyond our spacer
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        self.screens.active.cursor.pending_wrap = true;
                    } else {
                        self.screens.active.cursorRight(1);
                    }
                },

                .narrow => narrow: {
                    // Prev cell is no longer wide
                    if (prev.cell.wide != .wide) break :narrow;
                    prev.cell.wide = .narrow;

                    // Remove the wide spacer tail
                    const cell = self.screens.active.cursorCellLeft(prev.left - 1);
                    cell.wide = .narrow;

                    // Back track the cursor so that we don't end up with
                    // an extra space after the character. Since xterm is
                    // not VS aware, it cannot be used as a reference for
                    // this behavior; but it does follow the principle of
                    // least surprise, and also matches the behavior that
                    // can be observed in Kitty, which is one of the only
                    // other VS aware terminals.
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        // If we're already at the right edge, we stay
                        // here and set the pending wrap to false since
                        // when we pend a wrap, we only move our cursor once
                        // even for wide chars (tests verify).
                        self.screens.active.cursor.pending_wrap = false;
                    } else {
                        // Otherwise, move back.
                        self.screens.active.cursorLeft(1);
                    }

                    break :narrow;
                },

                else => {},
            }

            log.debug("c={X} grapheme attach to left={} primary_cp={X}", .{
                c,
                prev.left,
                prev.cell.codepoint(),
            });
            self.screens.active.cursorMarkDirty();
            try self.screens.active.appendGrapheme(prev.cell, c);
            return;
        }
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly. We have a fast-path for
    // byte-sized characters since they're so common. We can ignore
    // control characters because they're always filtered prior.
    const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);

    // Note: it is possible to have a width of "3" and a width of "-1" from
    // uucode.x's wcwidth. We should look into those cases and handle them
    // appropriately.
    assert(width <= 2);
    // log.debug("c={x} width={}", .{ c, width });

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        @branchHint(.unlikely);
        // If we have grapheme clustering enabled, we don't blindly attach
        // any zero width character to our cells and we instead just ignore
        // it.
        if (self.modes.get(.grapheme_cluster)) return;

        // If we're at cell zero, then this is malformed data and we don't
        // print anything or even store this. Zero-width characters are ALWAYS
        // attached to some other non-zero-width character at the time of
        // writing.
        if (self.screens.active.cursor.x == 0) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // Find our previous cell
        const prev = prev: {
            const immediate = self.screens.active.cursorCellLeft(1);
            if (immediate.wide != .spacer_tail) break :prev immediate;
            break :prev self.screens.active.cursorCellLeft(2);
        };

        // If our previous cell has no text, just ignore the zero-width character
        if (!prev.hasText()) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // If this is a emoji variation selector, prev must be an emoji
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_props = unicode.table.get(prev.content.codepoint);
            const emoji = prev_props.grapheme_break == .extended_pictographic;
            if (!emoji) return;
        }

        try self.screens.active.appendGrapheme(prev, c);
        return;
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screens.active.cursor.pending_wrap and self.modes.get(.wraparound)) {
        try self.printWrap();
    }

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screens.active.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => {
            @branchHint(.likely);
            self.screens.active.cursorMarkDirty();
            @call(.always_inline, printCell, .{ self, c, .narrow });
        },

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => if ((right_limit - self.scrolling_region.left) > 1) {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screens.active.cursor.x == right_limit - 1) {
                // If we don't have wraparound enabled then we don't print
                // this character at all and don't move the cursor. This is
                // how xterm behaves.
                if (!self.modes.get(.wraparound)) return;

                // We only create a spacer head if we're at the real edge
                // of the screen. Otherwise, we clear the space with a narrow.
                // This allows soft wrapping to work correctly.
                self.printCell(0, if (right_limit == self.cols) .spacer_head else .narrow);
                try self.printWrap();
            }

            self.screens.active.cursorMarkDirty();
            self.printCell(c, .wide);
            self.screens.active.cursorRight(1);
            self.printCell(0, .spacer_tail);
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We should prevent this downstream.
            self.screens.active.cursorMarkDirty();
            self.printCell(0, .narrow);
        },

        else => unreachable,
    }

    // If we're at the column limit, then we need to wrap the next time.
    // In this case, we don't move the cursor.
    if (self.screens.active.cursor.x == right_limit - 1) {
        self.screens.active.cursor.pending_wrap = true;
        return;
    }

    // Move the cursor
    self.screens.active.cursorRight(1);
}

fn printCell(
    self: *Terminal,
    unmapped_c: u21,
    wide: Cell.Wide,
) void {
    defer self.screens.active.assertIntegrity();

    // TODO: spacers should use a bgcolor only cell

    const c: u21 = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.screens.active.charset.single_shift) |key_once| blk: {
            self.screens.active.charset.single_shift = null;
            break :blk key_once;
        } else self.screens.active.charset.gl;

        const set = self.screens.active.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) {
            @branchHint(.likely);
            break :c unmapped_c;
        }

        // If we're outside of ASCII range this is an invalid value in
        // this table so we just return space.
        if (unmapped_c > std.math.maxInt(u8)) break :c ' ';

        // Get our lookup table and map it
        const table = charsets.table(set);
        break :c @intCast(table[@intCast(unmapped_c)]);
    };

    const cell = self.screens.active.cursor.page_cell;

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
                if (self.screens.active.cursor.x >= self.cols - 1) break :wide;

                const spacer_cell = self.screens.active.cursorCellRight(1);
                self.screens.active.clearCells(
                    &self.screens.active.cursor.page_pin.node.data,
                    self.screens.active.cursor.page_row,
                    spacer_cell[0..1],
                );
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    head_cell.wide = .narrow;
                }
            },

            .spacer_tail => {
                assert(self.screens.active.cursor.x > 0);

                // So integrity checks pass. We fix this up later so we don't
                // need to do this without safety checks.
                if (comptime std.debug.runtime_safety) {
                    cell.wide = .narrow;
                }

                const wide_cell = self.screens.active.cursorCellLeft(1);
                self.screens.active.clearCells(
                    &self.screens.active.cursor.page_pin.node.data,
                    self.screens.active.cursor.page_row,
                    wide_cell[0..1],
                );
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    head_cell.wide = .narrow;
                }
            },

            // TODO: this case was not handled in the old terminal implementation
            // but it feels like we should do something. investigate other
            // terminals (xterm mainly) and see what's up.
            .spacer_head => {},
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.hasGrapheme()) {
        const page = &self.screens.active.cursor.page_pin.node.data;
        page.clearGrapheme(cell);
        page.updateRowGraphemeFlag(self.screens.active.cursor.page_row);
    }

    // We don't need to update the style refs unless the
    // cell's new style will be different after writing.
    const style_changed = cell.style_id != self.screens.active.cursor.style_id;
    if (style_changed) {
        var page = &self.screens.active.cursor.page_pin.node.data;

        // Release the old style.
        if (cell.style_id != style.default_id) {
            assert(self.screens.active.cursor.page_row.styled);
            page.styles.release(page.memory, cell.style_id);
        }
    }

    // Keep track if we had a hyperlink so we can unset it.
    const had_hyperlink = cell.hyperlink;

    // Write
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = c },
        .style_id = self.screens.active.cursor.style_id,
        .wide = wide,
        .protected = self.screens.active.cursor.protected,
        .semantic_content = self.screens.active.cursor.semantic_content,
    };

    if (style_changed) {
        var page = &self.screens.active.cursor.page_pin.node.data;

        // Use the new style.
        if (cell.style_id != style.default_id) {
            page.styles.use(page.memory, cell.style_id);
            self.screens.active.cursor.page_row.styled = true;
        }
    }

    // If this is a Kitty unicode placeholder then we need to mark the
    // row so that the renderer can lookup rows with these much faster.
    if (comptime build_options.kitty_graphics) {
        if (c == kitty.graphics.unicode.placeholder) {
            @branchHint(.unlikely);
            self.screens.active.cursor.page_row.kitty_virtual_placeholder = true;
        }
    }

    // We check for an active hyperlink first because setHyperlink
    // handles clearing the old hyperlink and an optimization if we're
    // overwriting the same hyperlink.
    if (self.screens.active.cursor.hyperlink_id > 0) {
        self.screens.active.cursorSetHyperlink() catch |err| {
            @branchHint(.unlikely);
            log.warn("error reallocating for more hyperlink space, ignoring hyperlink err={}", .{err});
            assert(!cell.hyperlink);
        };
    } else if (had_hyperlink) {
        // If the previous cell had a hyperlink then we need to clear it.
        var page = &self.screens.active.cursor.page_pin.node.data;
        page.clearHyperlink(cell);
        page.updateRowHyperlinkFlag(self.screens.active.cursor.page_row);
    }
}

fn printWrap(self: *Terminal) !void {
    // We only mark that we soft-wrapped if we're at the edge of our
    // full screen. We don't mark the row as wrapped if we're in the
    // middle due to a right margin.
    const cursor: *Screen.Cursor = &self.screens.active.cursor;
    const mark_wrap = cursor.x == self.cols - 1;
    if (mark_wrap) cursor.page_row.wrap = true;

    // Get the old semantic prompt so we can extend it to the next
    // line. We need to do this before we index() because we may
    // modify memory.
    const old_semantic = cursor.semantic_content;
    const old_semantic_clear = cursor.semantic_content_clear_eol;

    // Move to the next line
    try self.index();
    self.screens.active.cursorHorizontalAbsolute(self.scrolling_region.left);

    // Our pointer should never move
    assert(cursor == &self.screens.active.cursor);

    // We always reset our semantic prompt state
    cursor.semantic_content = old_semantic;
    cursor.semantic_content_clear_eol = old_semantic_clear;
    switch (old_semantic) {
        .output, .input => {},
        .prompt => cursor.page_row.semantic_prompt = .prompt_continuation,
    }

    if (mark_wrap) {
        const row = self.screens.active.cursor.page_row;
        // Always mark the row as a continuation
        row.wrap_continuation = true;
    }

    // Assure that our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screens.active.charset.charsets.set(slot, set);
}

/// Invoke the charset in slot into the active slot. If single is true,
/// then this will only be invoked for a single character.
pub fn invokeCharset(
    self: *Terminal,
    active: charsets.ActiveSlot,
    slot: charsets.Slots,
    single: bool,
) void {
    if (single) {
        assert(active == .GL);
        self.screens.active.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.screens.active.charset.gl = slot,
        .GR => self.screens.active.charset.gr = slot,
    }
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    // Always reset pending wrap state
    self.screens.active.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screens.active.cursorHorizontalAbsolute(if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screens.active.cursor.x >= self.scrolling_region.left)
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

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The maximum amount the cursor can move up depends on scrolling regions
    const max = if (self.screens.active.cursor.y >= self.scrolling_region.top)
        self.screens.active.cursor.y - self.scrolling_region.top
    else
        self.screens.active.cursor.y;
    const count = @min(max, @max(count_req, 1));

    // We can safely intCast below because of the min/max clamping we did above.
    self.screens.active.cursorUp(@intCast(count));
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom - self.screens.active.cursor.y
    else
        self.rows - self.screens.active.cursor.y - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorDown(@intCast(count));
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right - self.screens.active.cursor.x
    else
        self.cols - self.screens.active.cursor.x - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorRight(@intCast(count));
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

    var count = @max(count_req, 1);

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screens.active.cursorLeft(@min(count, self.screens.active.cursor.x));
        self.screens.active.cursor.pending_wrap = false;
        return;
    }

    // If we have a pending wrap state and we are in either reverse wrap
    // modes then we decrement the amount we move by one to match xterm.
    if (self.screens.active.cursor.pending_wrap) {
        count -= 1;
        self.screens.active.cursor.pending_wrap = false;
    }

    // The margins we can move to.
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;
    const right_margin = self.scrolling_region.right;
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Handle some edge cases when our cursor is already on the left margin.
    if (self.screens.active.cursor.x == left_margin) {
        switch (wrap_mode) {
            // In reverse mode, if we're already before the top margin
            // then we just set our cursor to the top-left and we're done.
            .reverse => if (self.screens.active.cursor.y <= top) {
                self.screens.active.cursorAbsolute(left_margin, top);
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
        const max = self.screens.active.cursor.x - left_margin;

        // We want to move at most the number of columns we have left
        // or our remaining count. Do the move.
        const amount = @min(max, count);
        count -= amount;
        self.screens.active.cursorLeft(amount);

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screens.active.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screens.active.cursorAbsolute(right_margin, bottom);
            count -= 1;
            continue;
        }

        // UNDEFINED TERMINAL BEHAVIOR. This situation is not handled in xterm
        // and currently results in a crash in xterm. Given no other known
        // terminal [to me] implements XTREVWRAP2, I decided to just mimic
        // the behavior of xterm up and not including the crash by wrapping
        // up to the (0, 0) and stopping there. My reasoning is that for an
        // appropriately sized value of "count" this is the behavior that xterm
        // would have. This is unit tested.
        if (self.screens.active.cursor.y == 0) {
            assert(self.screens.active.cursor.x == left_margin);
            break;
        }

        // If our previous line is not wrapped then we are done.
        if (wrap_mode != .reverse_extended) {
            const prev_row = self.screens.active.cursorRowUp(1);
            if (!prev_row.wrap) break;
        }

        self.screens.active.cursorAbsolute(right_margin, self.screens.active.cursor.y - 1);
        count -= 1;
    }
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.screens.active.saved_cursor = .{
        .x = self.screens.active.cursor.x,
        .y = self.screens.active.cursor.y,
        .style = self.screens.active.cursor.style,
        .protected = self.screens.active.cursor.protected,
        .pending_wrap = self.screens.active.cursor.pending_wrap,
        .origin = self.modes.get(.origin),
        .charset = self.screens.active.charset,
    };
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    const saved: Screen.SavedCursor = self.screens.active.saved_cursor orelse .{
        .x = 0,
        .y = 0,
        .style = .{},
        .protected = false,
        .pending_wrap = false,
        .origin = false,
        .charset = .{},
    };

    // Set the style first because it can fail
    self.screens.active.cursor.style = saved.style;
    self.screens.active.manualStyleUpdate() catch |err| {
        // Regardless of the error here, we revert back to an unstyled
        // cursor. It is more important that the restore succeeds in
        // other attributes because terminals have no way to communicate
        // failure back.
        log.warn("restoreCursor error updating style err={}", .{err});
        const screen: *Screen = self.screens.active;
        screen.cursor.style = .{};
        self.screens.active.manualStyleUpdate() catch unreachable;
    };

    self.screens.active.charset = saved.charset;
    self.modes.set(.origin, saved.origin);
    self.screens.active.cursor.pending_wrap = saved.pending_wrap;
    self.screens.active.cursor.protected = saved.protected;
    self.screens.active.cursorAbsolute(
        @min(saved.x, self.cols - 1),
        @min(saved.y, self.rows - 1),
    );

    // Ensure our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the character protection mode for the terminal.
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screens.active.cursor.protected = false;

            // screen.protected_mode is NEVER reset to ".off" because
            // logic such as eraseChars depends on knowing what the
            // _most recent_ mode was.
        },

        .iso => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .iso;
        },

        .dec => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .dec;
        },
    }
}

/// Perform a semantic prompt command.
///
/// If there is an error, we do our best to get the terminal into
/// some coherent state, since callers typically can't handle errors
/// (since they're sending sequences via the pty).
pub fn semanticPrompt(
    self: *Terminal,
    cmd: osc.Command.SemanticPrompt,
) !void {
    switch (cmd.action) {
        .fresh_line => try self.semanticPromptFreshLine(),

        .fresh_line_new_prompt => {
            // "First do a fresh-line."
            try self.semanticPromptFreshLine();

            const screen: *Screen = self.screens.active;

            // "Subsequent text (until a OSC "133;B" or OSC "133;I" command)
            // is a prompt string (as if followed by OSC 133;P;k=i\007)."
            screen.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });

            // This is a kitty-specific flag that notes that the shell
            // is NOT capable of redraw. Redraw defaults to true so this
            // usually just disables it, but either is possible.
            if (cmd.readOption(.redraw)) |v| {
                self.flags.shell_redraws_prompt = v;
            }

            click: {
                // Handle click_events as a priority over cl. click_events
                // is another Kitty-specific extension that converts clicks
                // within a prompt area to SGR mouse events and defers to the
                // shell to handle them.
                if (cmd.readOption(.click_events)) |v| {
                    if (v) {
                        screen.semantic_prompt.click = .click_events;
                        break :click;
                    }
                }

                // If click_events was not set or disabled, fallback to `cl`.
                if (cmd.readOption(.cl)) |v| {
                    screen.semantic_prompt.click = .{ .cl = v };
                }
            }

            // The "aid" and "cl" options are also valid for this
            // command but we don't yet handle these in any meaningful way.
        },

        .new_command => {
            // Spec:
            // Same as OSC "133;A" but may first implicitly terminate a
            // previous command: if the options specify an aid and there
            // is an active (open) command with matching aid, finish the
            // innermost such command (as well as any other commands
            // nested more deeply). If no aid is specified, treat as an
            // aid whose value is the empty string.

            // Ghostty:
            // We don't currently do explicit command tracking in any way
            // so there is no need to terminate prior commands. We just
            // perform the `A` action.
            try self.semanticPrompt(.{
                .action = .fresh_line_new_prompt,
                .options_unvalidated = cmd.options_unvalidated,
            });
        },

        .prompt_start => {
            // Explicit start of prompt. Optional after an A or N command.
            // The k (kind) option specifies the type of prompt:
            // regular primary prompt (k=i or default),
            // right-side prompts (k=r), or prompts for continuation lines (k=c or k=s).
            self.screens.active.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });
        },

        .end_prompt_start_input => {
            // End of prompt and start of user input, terminated by a OSC
            // "133;C" or another prompt (OSC "133;P").
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_explicit,
            });
        },

        .end_prompt_start_input_terminate_eol => {
            // End of prompt and start of user input, terminated by end-of-line.
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_eol,
            });
        },

        .end_input_start_output => {
            // "End of input, and start of output."
            self.screens.active.cursorSetSemanticContent(.output);

            // If our current row is marked as a prompt and we're
            // at column zero then we assume we're un-prompting. This
            // is a heuristic to deal with fish, mostly. The issue that
            // fish brings up is that it has no PS2 equivalent and its
            // builtin OSC133 marking doesn't output continuation lines
            // as k=s. So, we assume when we get a newline with a prompt
            // cursor that the new line is also a prompt. But fish changes
            // to output on the newline. So if we're at col 0 we just assume
            // we're overwriting the prompt.
            if (self.screens.active.cursor.page_row.semantic_prompt != .none and
                self.screens.active.cursor.x == 0)
            {
                self.screens.active.cursor.page_row.semantic_prompt = .none;
            }
        },

        .end_command => {
            // From a terminal state perspective, this doesn't really do
            // anything. Other terminals appear to do nothing here. I think
            // its reasonable at this point to reset our semantic content
            // state but the spec doesn't really say what to do.
            self.screens.active.cursorSetSemanticContent(.output);
        },
    }
}

// OSC 133;L
fn semanticPromptFreshLine(self: *Terminal) !void {
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Spec: "If the cursor is the initial column (left, assuming
    // left-to-right writing), do nothing" This specification is very under
    // specified. We are taking the liberty to assume that in a left/right
    // margin context, if the cursor is outside of the left margin, we treat
    // it as being at the left margin for the purposes of this command.
    // This is arbitrary. If someone has a better reasonable idea we can
    // apply it.
    if (self.screens.active.cursor.x == left_margin) return;

    self.carriageReturn();
    try self.index();
}

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

/// Returns true if the cursor is currently at a prompt. Another way to look
/// at this is it returns false if the shell is currently outputting something.
/// This requires shell integration (semantic prompt integration).
///
/// If the shell integration doesn't exist, this will always return false.
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    // If we're on the secondary screen, we're never at a prompt.
    if (self.screens.active_key == .alternate) return false;

    // If our page row is a prompt then we're always at a prompt
    const cursor: *const Screen.Cursor = &self.screens.active.cursor;
    if (cursor.page_row.semantic_prompt != .none) return true;

    // Otherwise, determine our cursor state
    return switch (cursor.semantic_content) {
        .input, .prompt => true,
        .output => false,
    };
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) void {
    while (self.screens.active.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screens.active.cursorRight(1);

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

// Same as horizontalTab but moves to the previous tabstop instead of the next.
pub fn horizontalTabBack(self: *Terminal) void {
    // With origin mode enabled, our leftmost limit is the left margin.
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;

    while (true) {
        // If we're already at the edge of the screen, then we're done.
        if (self.screens.active.cursor.x <= left_limit) return;

        // Move the cursor left
        self.screens.active.cursorLeft(1);
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

/// Clear tab stops.
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screens.active.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screens.active.cursor.x);
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
    const screen: *Screen = self.screens.active;

    // Unset pending wrap state
    screen.cursor.pending_wrap = false;

    // We handle our cursor semantic prompt state AFTER doing the
    // scrolling, because we may need to apply to new rows.
    defer if (screen.cursor.semantic_content != .output) {
        @branchHint(.unlikely);

        // Always reset any semantic content clear-eol state.
        //
        // The specification is not clear what "end-of-line" means. If we
        // discover that there are more scenarios we should be unsetting
        // this we should document and test it.
        if (screen.cursor.semantic_content_clear_eol) {
            screen.cursor.semantic_content = .output;
            screen.cursor.semantic_content_clear_eol = false;
        } else {
            // If we aren't clearing our state at EOL and we're not output,
            // then we mark the new row as a prompt continuation. This is
            // to work around shells that don't send OSC 133 k=s sequences
            // for continuations.
            //
            // This can be a false positive if the shell changes content
            // type later and outputs something. We handle that in the
            // semanticPrompt function.
            screen.cursor.page_row.semantic_prompt = .prompt_continuation;
        }
    } else {
        // This should never be set in the output mode.
        assert(!screen.cursor.semantic_content_clear_eol);
    };

    // Outside of the scroll region we move the cursor one line down.
    if (screen.cursor.y < self.scrolling_region.top or
        screen.cursor.y > self.scrolling_region.bottom)
    {
        // We only move down if we're not already at the bottom of
        // the screen.
        if (screen.cursor.y < self.rows - 1) {
            screen.cursorDown(1);
        }

        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (screen.cursor.y == self.scrolling_region.bottom and
        screen.cursor.x >= self.scrolling_region.left and
        screen.cursor.x <= self.scrolling_region.right)
    {
        if (comptime build_options.kitty_graphics) {
            // Scrolling dirties the images because it updates their placements pins.
            screen.kitty_images.dirty = true;
        }

        // If our scrolling region is at the top, we create scrollback.
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1)
        {
            try screen.cursorScrollAbove();
            return;
        }

        // Slow path for left and right scrolling region margins.
        if (self.scrolling_region.left != 0 or
            self.scrolling_region.right != self.cols - 1 or

            // PERF(mitchellh): If we have an SGR background set then
            // we need to preserve that background in our erased rows.
            // scrollUp does that but eraseRowBounded below does not.
            // However, scrollUp is WAY slower. We should optimize this
            // case to work in the eraseRowBounded codepath and remove
            // this check.
            !screen.blankCell().isZero())
        {
            try self.scrollUp(1);
            return;
        }

        // Otherwise use a fast path function from PageList to efficiently
        // scroll the contents of the scrolling region.

        // Preserve old cursor just for assertions
        const old_cursor = screen.cursor;

        try screen.pages.eraseRowBounded(
            .{ .active = .{ .y = self.scrolling_region.top } },
            self.scrolling_region.bottom - self.scrolling_region.top,
        );

        // eraseRow and eraseRowBounded will end up moving the cursor pin
        // up by 1, so we need to move it back down. A `cursorReload`
        // would be better option but this is more efficient and this is
        // a super hot path so we do this instead.
        assert(screen.cursor.x == old_cursor.x);
        assert(screen.cursor.y == old_cursor.y);
        screen.cursor.y -= 1;
        screen.cursorDown(1);

        // The operations above can prune our cursor style so we need to
        // update. This should never fail because the above can only FREE
        // memory.
        screen.manualStyleUpdate() catch |err| {
            std.log.warn("deleteLines manualStyleUpdate err={}", .{err});
            screen.cursor.style = .{};
            screen.manualStyleUpdate() catch unreachable;
        };

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    if (screen.cursor.y < self.scrolling_region.bottom) {
        screen.cursorDown(1);
    }
}

/// Move the cursor to the previous line in the scrolling region, possibly
/// scrolling.
///
/// If the cursor is outside of the scrolling region, move the cursor one
/// line up if it is not on the top-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///
///   * If the cursor is on the top-most line of the scrolling region:
///     invoke scroll down with amount=1
///   * If the cursor is not on the top-most line of the scrolling region:
///     move the cursor one line up
pub fn reverseIndex(self: *Terminal) void {
    if (self.screens.active.cursor.y != self.scrolling_region.top or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right)
    {
        self.cursorUp(1);
        return;
    }

    self.scrollDown(1);
}

/// Set Cursor Position. Move cursor to the position indicated
/// by row and column (1-indexed). If column is 0, it is adjusted to 1.
/// If column is greater than the right-most column it is adjusted to
/// the right-most column. If row is 0, it is adjusted to 1. If row is
/// greater than the bottom-most row it is adjusted to the bottom-most
/// row.
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
    self.screens.active.cursor.pending_wrap = false;

    // Calculate our new x/y
    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    const x = @min(params.x_max, col + params.x_offset) -| 1;
    const y = @min(params.y_max, row + params.y_offset) -| 1;

    // If the y is unchanged then this is fast pointer math
    if (y == self.screens.active.cursor.y) {
        if (x > self.screens.active.cursor.x) {
            self.screens.active.cursorRight(x - self.screens.active.cursor.x);
        } else {
            self.screens.active.cursorLeft(self.screens.active.cursor.x - x);
        }

        return;
    }

    // If everything changed we do an absolute change which is slightly slower
    self.screens.active.cursorAbsolute(x, y);
    // log.info("set cursor position: col={} row={}", .{ self.screens.active.cursor.x, self.screens.active.cursor.y });
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
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
pub fn scrollUp(self: *Terminal, count: usize) !void {
    // Preserve our x/y to restore.
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // If our scroll region is at the top and we have no left/right
    // margins then we move the scrolled out text into the scrollback.
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1)
    {
        // Scrolling dirties the images because it updates their placements pins.
        if (comptime build_options.kitty_graphics) {
            self.screens.active.kitty_images.dirty = true;
        }

        // Clamp count to the scroll region height.
        const region_height = self.scrolling_region.bottom + 1;
        const adjusted_count = @min(count, region_height);

        // TODO: Create an optimized version that can scroll N times
        // This isn't critical because in most cases, scrollUp is used
        // with count=1, but it's still a big optimization opportunity.

        // Move our cursor to the bottom of the scroll region so we can
        // use the cursorScrollAbove function to create scrollback
        self.screens.active.cursorAbsolute(0, self.scrolling_region.bottom);
        for (0..adjusted_count) |_| try self.screens.active.cursorScrollAbove();
        return;
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.deleteLines(count);
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(enum) {
    /// Scroll to the top of the scrollback
    top,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom,

    /// Scroll by some delta amount, up is negative.
    delta: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) void {
    self.screens.active.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .active = {} },
        .delta => |delta| .{ .delta_row = delta },
    });
}

/// To be called before shifting a row (as in insertLines and deleteLines)
///
/// Takes care of boundary conditions such as potentially split wide chars
/// across scrolling region boundaries and orphaned spacer heads at line
/// ends.
fn rowWillBeShifted(
    self: *Terminal,
    page: *Page,
    row: *Row,
) void {
    const cells = row.cells.ptr(page.memory.ptr);

    // If our scrolling region includes the rightmost column then we
    // need to turn any spacer heads in to normal empty cells, since
    // once we move them they no longer correspond with soft-wrapped
    // wide characters.
    //
    // If it contains either of the 2 leftmost columns, then the wide
    // characters in the first column which may be associated with a
    // spacer head will be either moved or cleared, so we also need
    // to turn the spacer heads in to empty cells in that case.
    if (self.scrolling_region.right == self.cols - 1 or
        self.scrolling_region.left < 2)
    {
        const end_cell: *Cell = &cells[page.size.cols - 1];
        if (end_cell.wide == .spacer_head) {
            end_cell.wide = .narrow;
        }
    }

    // If the leftmost or rightmost cells of our scrolling region
    // are parts of wide chars, we need to clear the cells' contents
    // since they'd be split by the move.
    const left_cell: *Cell = &cells[self.scrolling_region.left];
    const right_cell: *Cell = &cells[self.scrolling_region.right];

    if (left_cell.wide == .spacer_tail) {
        const wide_cell: *Cell = &cells[self.scrolling_region.left - 1];
        if (wide_cell.hasGrapheme()) {
            page.clearGrapheme(wide_cell);
            page.updateRowGraphemeFlag(row);
        }
        wide_cell.content.codepoint = 0;
        wide_cell.wide = .narrow;
        left_cell.wide = .narrow;
    }

    if (right_cell.wide == .wide) {
        const tail_cell: *Cell = &cells[self.scrolling_region.right + 1];
        if (right_cell.hasGrapheme()) {
            page.clearGrapheme(right_cell);
            page.updateRowGraphemeFlag(row);
        }
        right_cell.content.codepoint = 0;
        right_cell.wide = .narrow;
        tail_cell.wide = .narrow;
    }
}

// TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical,
// the majority of their logic can (and should) be abstracted in to
// a single shared helper function, probably on `Screen` not here.
// I'm just too lazy to do that rn :p

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
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    if (comptime build_options.kitty_graphics) {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);

        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.down(rem - 1).?,
    ) catch |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});

        // This error scenario means that our GPA is OOM. This is not a
        // situation we can gracefully handle. We can't just ignore insertLines
        // because it'll result in a corrupted screen. Ideally in the future
        // we flag the state as broken and show an error message to the user.
        // For now, we panic.
        log.err("insertLines trackPin error err={}", .{err});
        @panic("insertLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Our current y position relative to the cursor
    var y: usize = rem;

    // Traverse from the bottom up
    while (y > 0) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y > adjusted_count) {
            const off_p = cur_p.up(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            self.rowWillBeShifted(&off_p.node.data, off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                dst_p.node.data.clonePartialRowFrom(
                    &src_p.node.data,
                    dst_row,
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                ) catch |err| {
                    // Adjust our page capacity to make
                    // room for we didn't have space for
                    _ = self.screens.active.increaseCapacity(
                        dst_p.node,
                        switch (err) {
                            // Rehash the sets
                            error.StyleSetNeedsRehash,
                            error.HyperlinkSetNeedsRehash,
                            => null,

                            // Increase style memory
                            error.StyleSetOutOfMemory,
                            => .styles,

                            // Increase string memory
                            error.StringAllocOutOfMemory,
                            => .string_bytes,

                            // Increase hyperlink memory
                            error.HyperlinkSetOutOfMemory,
                            error.HyperlinkMapOutOfMemory,
                            => .hyperlink_bytes,

                            // Increase grapheme memory
                            error.GraphemeMapOutOfMemory,
                            error.GraphemeAllocOutOfMemory,
                            => .grapheme_bytes,
                        },
                    ) catch |e| switch (e) {
                        // System OOM. We have no way to recover from this
                        // currently. We should probably change insertLines
                        // to raise an error here.
                        error.OutOfMemory,
                        => @panic("increaseCapacity system allocator OOM"),

                        // The page can't accommodate the managed memory required
                        // for this operation. We previously just corrupted
                        // memory here so a crash is better. The right long
                        // term solution is to allocate a new page here
                        // move this row to the new page, and start over.
                        error.OutOfSpace,
                        => @panic("increaseCapacity OutOfSpace"),
                    };

                    // Continue the loop to try handling this row again.
                    continue;
                };
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.data.assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = &cur_p.node.data;
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it has been shifted.
            const page = &cur_p.node.data;
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y -= 1;
        // Move our pin up to the next row.
        if (cur_p.up(1)) |p| cur_p.* = p;
    }
}

/// Removes amount lines from the current cursor row down. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up is
/// filled with empty lines.
///
/// If the current cursor position is outside of the current scroll region it
/// does nothing. If amount is greater than the remaining number of lines in the
/// scrolling region it is adjusted down.
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// If the cell movement splits a multi cell character that character cleared,
/// by replacing it by spaces, keeping its current attributes. All other
/// cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn deleteLines(self: *Terminal, count: usize) void {
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    if (comptime build_options.kitty_graphics) {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);
        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.*,
    ) catch |err| {
        // See insertLines
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        log.err("deleteLines trackPin error err={}", .{err});
        @panic("deleteLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Our current y position relative to the cursor
    var y: usize = 0;

    // Traverse from the top down
    while (y < rem) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y < rem - adjusted_count) {
            const off_p = cur_p.down(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            self.rowWillBeShifted(&off_p.node.data, off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                dst_p.node.data.clonePartialRowFrom(
                    &src_p.node.data,
                    dst_row,
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                ) catch |err| {
                    // Adjust our page capacity to make
                    // room for we didn't have space for
                    _ = self.screens.active.increaseCapacity(
                        dst_p.node,
                        switch (err) {
                            // Rehash the sets
                            error.StyleSetNeedsRehash,
                            error.HyperlinkSetNeedsRehash,
                            => null,

                            // Increase style memory
                            error.StyleSetOutOfMemory,
                            => .styles,

                            // Increase string memory
                            error.StringAllocOutOfMemory,
                            => .string_bytes,

                            // Increase hyperlink memory
                            error.HyperlinkSetOutOfMemory,
                            error.HyperlinkMapOutOfMemory,
                            => .hyperlink_bytes,

                            // Increase grapheme memory
                            error.GraphemeMapOutOfMemory,
                            error.GraphemeAllocOutOfMemory,
                            => .grapheme_bytes,
                        },
                    ) catch |e| switch (e) {
                        // See insertLines
                        error.OutOfMemory,
                        => @panic("increaseCapacity system allocator OOM"),

                        error.OutOfSpace,
                        => @panic("increaseCapacity OutOfSpace"),
                    };

                    // Continue the loop to try handling this row again.
                    continue;
                };
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.data.assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = &cur_p.node.data;
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it's from out of bounds.
            const page = &cur_p.node.data;
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y += 1;
        // Move our pin down to the next row.
        if (cur_p.down(1)) |p| cur_p.* = p;
    }
}

/// Inserts spaces at current cursor position moving existing cell contents
/// to the right. The contents of the count right-most columns in the scroll
/// region are lost. The cursor position is not changed.
///
/// This unsets the pending wrap state without wrapping.
///
/// The inserted cells are colored according to the current SGR state.
pub fn insertBlanks(self: *Terminal, count: usize) void {
    // Unset pending wrap state without wrapping. Note: this purposely
    // happens BEFORE the scroll region check below, because that's what
    // xterm does.
    self.screens.active.cursor.pending_wrap = false;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // If our count is larger than the remaining amount, we just erase right.
    // We only do this if we can erase the entire line (no right margin).
    // if (right_limit == self.cols and
    //     count > right_limit - self.screens.active.cursor.x)
    // {
    //     self.eraseLine(.right, false);
    //     return;
    // }

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = &self.screens.active.cursor.page_pin.node.data;

    // If our X is a wide spacer tail then we need to erase the
    // previous cell too so we don't split a multi-cell character.
    if (self.screens.active.cursor.page_cell.wide == .spacer_tail) {
        assert(self.screens.active.cursor.x > 0);
        self.screens.active.clearCells(page, self.screens.active.cursor.page_row, (left - 1)[0..2]);
    }

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // We can only insert blanks up to our remaining cols
    const adjusted_count = @min(count, rem);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - adjusted_count;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        var x: [*]Cell = left + (scroll_amount - 1);

        // If our last cell we're shifting is wide, then we need to clear
        // it to be empty so we don't split the multi-cell char.
        const end: *Cell = @ptrCast(x);
        if (end.wide == .wide) {
            const end_multi: [*]Cell = @ptrCast(end);
            assert(end_multi[1].wide == .spacer_tail);
            self.screens.active.clearCells(
                page,
                self.screens.active.cursor.page_row,
                end_multi[0..2],
            );
        }

        // We work backwards so we don't overwrite data.
        while (@intFromPtr(x) >= @intFromPtr(left)) : (x -= 1) {
            const src: *Cell = @ptrCast(x);
            const dst: *Cell = @ptrCast(x + adjusted_count);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, left[0..adjusted_count]);

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
pub fn deleteChars(self: *Terminal, count_req: usize) void {
    if (count_req == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = &self.screens.active.cursor.page_pin.node.data;

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // We can only insert blanks up to our remaining cols
    const count = @min(count_req, rem);

    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);
    self.screens.active.splitCellBoundary(self.scrolling_region.right + 1);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - count;
    var x: [*]Cell = left;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        const right: [*]Cell = left + (scroll_amount - 1);

        while (@intFromPtr(x) <= @intFromPtr(right)) : (x += 1) {
            const src: *Cell = @ptrCast(x + count);
            const dst: *Cell = @ptrCast(x);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, x[0 .. rem - scroll_amount]);

    // Our row's soft-wrap is always reset.
    self.screens.active.cursorResetWrap();

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

pub fn eraseChars(self: *Terminal, count_req: usize) void {
    const count = end: {
        const remaining = self.cols - self.screens.active.cursor.x;
        var end = @min(remaining, @max(count_req, 1));

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != remaining) {
            const last = self.screens.active.cursorCellRight(end - 1);
            if (last.wide == .wide) end += 1;
        }

        break :end end;
    };

    // Handle any boundary conditions on the edges of the erased area.
    //
    // TODO(qwerasd): This isn't actually correct if you take in to account
    // protected modes. We need to figure out how to make `clearCells` or at
    // least `clearUnprotectedCells` handle boundary conditions...
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);

    // Reset our row's soft-wrap.
    self.screens.active.cursorResetWrap();

    // Mark our cursor row as dirty
    self.screens.active.cursorMarkDirty();

    // Clear the cells
    const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);

    // If we never had a protection mode, then we can assume no cells
    // are protected and go with the fast path. If the last protection
    // mode was not ISO we also always ignore protection attributes.
    if (self.screens.active.protected_mode != .iso) {
        self.screens.active.clearCells(
            &self.screens.active.cursor.page_pin.node.data,
            self.screens.active.cursor.page_row,
            cells[0..count],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        &self.screens.active.cursor.page_pin.node.data,
        self.screens.active.cursor.page_row,
        cells[0..count],
    );
}

/// Erase the line.
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    // Get our start/end positions depending on mode.
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screens.active.cursor.x;

            // If our X is a wide spacer tail then we need to erase the
            // previous cell too so we don't split a multi-cell character.
            if (x > 0 and self.screens.active.cursor.page_cell.wide == .spacer_tail) {
                x -= 1;
            }

            // Reset our row's soft-wrap.
            self.screens.active.cursorResetWrap();

            break :right .{ x, self.cols };
        },

        .left => left: {
            var x = self.screens.active.cursor.x;

            // If our x is a wide char we need to delete the tail too.
            if (self.screens.active.cursor.page_cell.wide == .wide) {
                x += 1;
            }

            break :left .{ 0, x + 1 };
        },

        // Note that it seems like complete should reset the soft-wrap
        // state of the line but in xterm it does not.
        .complete => .{ 0, self.cols },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };

    // All modes will clear the pending wrap state and we know we have
    // a valid mode at this point.
    self.screens.active.cursor.pending_wrap = false;

    // We always mark our row as dirty
    self.screens.active.cursorMarkDirty();

    // Start of our cells
    const cells: [*]Cell = cells: {
        const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
        break :cells cells - self.screens.active.cursor.x;
    };

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    // If we're not respecting protected attributes, we can use a fast-path
    // to fill the entire line.
    if (!protected) {
        self.screens.active.clearCells(
            &self.screens.active.cursor.page_pin.node.data,
            self.screens.active.cursor.page_row,
            cells[start..end],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        &self.screens.active.cursor.page_pin.node.data,
        self.screens.active.cursor.page_row,
        cells[start..end],
    );
}

/// Erase the display.
pub fn eraseDisplay(
    self: *Terminal,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    switch (mode) {
        .scroll_complete => {
            self.screens.active.scrollClear() catch |err| {
                log.warn("scroll clear failed, doing a normal clear err={}", .{err});
                self.eraseDisplay(.complete, protected_req);
                return;
            };

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            if (comptime build_options.kitty_graphics) {
                // Clear all Kitty graphics state for this screen
                self.screens.active.kitty_images.delete(
                    self.screens.active.alloc,
                    self,
                    .{ .all = true },
                );
            }
        },

        .complete => {
            // If we're on the primary screen and our last non-empty row is
            // a prompt, then we do a scroll_complete instead. This is a
            // heuristic to get the generally desirable behavior that ^L
            // at a prompt scrolls the screen contents prior to clearing.
            // Most shells send `ESC [ H ESC [ 2 J` so we can't just check
            // our current cursor position. See #905
            if (self.screens.active_key == .primary) at_prompt: {
                // Go from the bottom of the active up and see if we're
                // at a prompt.
                const active_br = self.screens.active.pages.getBottomRight(
                    .active,
                ) orelse break :at_prompt;
                var it = active_br.rowIterator(
                    .left_up,
                    self.screens.active.pages.getTopLeft(.active),
                );
                while (it.next()) |p| {
                    const row = p.rowAndCell().row;
                    switch (row.semantic_prompt) {
                        // If we're at a prompt or input area, then we are at a prompt.
                        .prompt,
                        .prompt_continuation,
                        => break,

                        // If we have command output, then we're most certainly not
                        // at a prompt.
                        .none => break :at_prompt,
                    }
                } else break :at_prompt;

                self.screens.active.scrollClear() catch {
                    // If we fail, we just fall back to doing a normal clear
                    // so we don't worry about the error.
                };
            }

            // All active area
            self.screens.active.clearRows(
                .{ .active = .{} },
                null,
                protected,
            );

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            if (comptime build_options.kitty_graphics) {
                // Clear all Kitty graphics state for this screen
                self.screens.active.kitty_images.delete(
                    self.screens.active.alloc,
                    self,
                    .{ .all = true },
                );
            }

            // Cleared screen dirty bit
            self.flags.dirty.clear = true;
        },

        .below => {
            // All lines to the right (including the cursor)
            self.eraseLine(.right, protected_req);

            // All lines below
            if (self.screens.active.cursor.y + 1 < self.rows) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = self.screens.active.cursor.y + 1 } },
                    null,
                    protected,
                );
            }

            // Unsets pending wrap state. Should be done by eraseLine.
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .above => {
            // Erase to the left (including the cursor)
            self.eraseLine(.left, protected_req);

            // All lines above
            if (self.screens.active.cursor.y > 0) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = 0 } },
                    .{ .active = .{ .y = self.screens.active.cursor.y - 1 } },
                    protected,
                );
            }

            // Unsets pending wrap state
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .scrollback => self.screens.active.eraseRows(.{ .history = .{} }, null),
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
    // Clear our stylistic attributes. This is the only thing that can
    // fail so we do it first so we can undo it.
    const old_style = self.screens.active.cursor.style;
    self.screens.active.cursor.style = .{
        .bg_color = self.screens.active.cursor.style.bg_color,
        .fg_color = self.screens.active.cursor.style.fg_color,
    };
    errdefer self.screens.active.cursor.style = old_style;
    try self.screens.active.manualStyleUpdate();

    // Reset margins, also sets cursor to top-left
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };

    // Origin mode is disabled
    self.modes.set(.origin, false);

    // Move our cursor to the top-left
    self.setCursorPos(1, 1);

    // Use clearRows instead of eraseDisplay because we must NOT respect
    // protected attributes here.
    self.screens.active.clearRows(
        .{ .active = .{} },
        null,
        false,
    );

    // Fill with Es by moving the cursor but reset it after.
    while (true) {
        const page = &self.screens.active.cursor.page_pin.node.data;
        const row = self.screens.active.cursor.page_row;
        const cells_multi: [*]Cell = row.cells.ptr(page.memory);
        const cells = cells_multi[0..page.size.cols];
        @memset(cells, .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'E' },
            .style_id = self.screens.active.cursor.style_id,

            // DECALN does not respect protected state. Verified with xterm.
            .protected = false,
        });

        // If we have a ref-counted style, increase
        if (self.screens.active.cursor.style_id != style.default_id) {
            page.styles.useMultiple(
                page.memory,
                self.screens.active.cursor.style_id,
                @intCast(cells.len),
            );
            row.styled = true;
        }

        // We messed with the page so assert its integrity here.
        page.assertIntegrity();

        self.screens.active.cursorMarkDirty();
        if (self.screens.active.cursor.y == self.rows - 1) break;
        self.screens.active.cursorDown(1);
    }

    // Reset the cursor to the top-left
    self.setCursorPos(1, 1);
}

/// Execute a kitty graphics command. The buf is used to populate with
/// the response that should be sent as an APC sequence. The response will
/// be a full, valid APC sequence.
///
/// If an error occurs, the caller should response to the pty that a
/// an error occurred otherwise the behavior of the graphics protocol is
/// undefined.
pub fn kittyGraphics(
    self: *Terminal,
    alloc: Allocator,
    cmd: *kitty.graphics.Command,
) ?kitty.graphics.Response {
    return kitty.graphics.execute(alloc, self, cmd);
}

/// Set a style attribute.
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    try self.screens.active.setAttribute(attr);
}

/// Print the active attributes as a string. This is used to respond to DECRQSS
/// requests.
///
/// Boolean attributes are printed first, followed by foreground color, then
/// background color. Each attribute is separated by a semicolon.
pub fn printAttributes(self: *Terminal, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    // The SGR response always starts with a 0. See https://vt100.net/docs/vt510-rm/DECRPSS
    try writer.writeByte('0');

    const pen = self.screens.active.cursor.style;
    var attrs: [8]u8 = @splat(0);
    var i: usize = 0;

    if (pen.flags.bold) {
        attrs[i] = '1';
        i += 1;
    }

    if (pen.flags.faint) {
        attrs[i] = '2';
        i += 1;
    }

    if (pen.flags.italic) {
        attrs[i] = '3';
        i += 1;
    }

    if (pen.flags.underline != .none) {
        attrs[i] = '4';
        i += 1;
    }

    if (pen.flags.blink) {
        attrs[i] = '5';
        i += 1;
    }

    if (pen.flags.inverse) {
        attrs[i] = '7';
        i += 1;
    }

    if (pen.flags.invisible) {
        attrs[i] = '8';
        i += 1;
    }

    if (pen.flags.strikethrough) {
        attrs[i] = '9';
        i += 1;
    }

    for (attrs[0..i]) |c| {
        try writer.print(";{c}", .{c});
    }

    switch (pen.fg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";38:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";9{}", .{idx - 8})
        else
            try writer.print(";3{}", .{idx}),
        .rgb => |rgb| try writer.print(";38:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    switch (pen.bg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";48:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";10{}", .{idx - 8})
        else
            try writer.print(";4{}", .{idx}),
        .rgb => |rgb| try writer.print(";48:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    return stream.getWritten();
}

/// The modes for DECCOLM.
pub const DeccolmMode = enum(u1) {
    @"80_cols" = 0,
    @"132_cols" = 1,
};

/// DECCOLM changes the terminal width between 80 and 132 columns. This
/// function call will do NOTHING unless `setDeccolmSupported` has been
/// called with "true".
///
/// This breaks the expectation around modern terminals that they resize
/// with the window. This will fix the grid at either 80 or 132 columns.
/// The rows will continue to be variable.
pub fn deccolm(self: *Terminal, alloc: Allocator, mode: DeccolmMode) !void {
    // If DEC mode 40 isn't enabled, then this is ignored. We also make
    // sure that we don't have deccolm set because we want to fully ignore
    // set mode.
    if (!self.modes.get(.enable_mode_3)) {
        self.modes.set(.@"132_column", false);
        return;
    }

    // Enable it
    self.modes.set(.@"132_column", mode == .@"132_cols");

    // Resize to the requested size
    try self.resize(
        alloc,
        switch (mode) {
            .@"132_cols" => 132,
            .@"80_cols" => 80,
        },
        self.rows,
    );

    // Erase our display and move our cursor.
    self.eraseDisplay(.complete, false);
    self.setCursorPos(1, 1);
}

/// Resize the underlying terminal.
pub fn resize(
    self: *Terminal,
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    // If our cols/rows didn't change then we're done
    if (self.cols == cols and self.rows == rows) return;

    // Resize our tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try .init(alloc, cols, 8);
    }

    // Resize primary screen, which supports reflow
    const primary = self.screens.get(.primary).?;
    try primary.resize(.{
        .cols = cols,
        .rows = rows,
        .reflow = self.modes.get(.wraparound),
        .prompt_redraw = self.flags.shell_redraws_prompt,
    });

    // Alternate screen, if it exists, doesn't reflow
    if (self.screens.get(.alternate)) |alt| try alt.resize(.{
        .cols = cols,
        .rows = rows,
        .reflow = false,
    });

    // Whenever we resize we just mark it as a screen clear
    self.flags.dirty.clear = true;

    // Set our size
    self.cols = cols;
    self.rows = rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = rows - 1,
        .left = 0,
        .right = cols - 1,
    };
}

/// Set the pwd for the terminal.
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    self.pwd.clearRetainingCapacity();
    try self.pwd.appendSlice(self.gpa(), pwd);
}

/// Returns the pwd for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setPwd.
pub fn getPwd(self: *const Terminal) ?[]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items;
}

/// Switch to the given screen type (alternate or primary).
///
/// This does NOT handle behaviors such as clearing the screen,
/// copying the cursor, etc. This should be handled by downstream
/// callers.
///
/// After calling this function, the `self.screen` field will point
/// to the current screen, and the returned value will be the previous
/// screen. If the return value is null, then the screen was not
/// switched because it was already the active screen.
///
/// Note: This is written in a generic way so that we can support
/// more than two screens in the future if needed. There isn't
/// currently a spec for this, but it is something I think might
/// be useful in the future.
pub fn switchScreen(self: *Terminal, key: ScreenSet.Key) !?*Screen {
    // If we're already on the requested screen we do nothing.
    if (self.screens.active_key == key) return null;
    const old = self.screens.active;

    // We always end hyperlink state when switching screens.
    // We need to do this on the original screen.
    old.endHyperlink();

    // Switch the screens/
    const new = self.screens.get(key) orelse new: {
        const primary = self.screens.get(.primary).?;
        break :new try self.screens.getInit(
            old.alloc,
            key,
            .{
                .cols = self.cols,
                .rows = self.rows,
                .max_scrollback = switch (key) {
                    .primary => primary.pages.explicit_max_size,
                    .alternate => 0,
                },

                // Inherit our Kitty image storage limit from the primary
                // screen if we have to initialize.
                .kitty_image_storage_limit = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.total_limit
                else
                    0,
            },
        );
    };

    // The new screen should not have any hyperlinks set
    assert(new.cursor.hyperlink_id == 0);

    // Bring our charset state with us
    new.charset = old.charset;

    // Clear our selection
    new.clearSelection();

    if (comptime build_options.kitty_graphics) {
        // Mark kitty images as dirty so they redraw. Without this set
        // the images will remain where they were (the dirty bit on
        // the screen only tracks the terminal grid, not the images).
        new.kitty_images.dirty = true;
    }

    // Mark our terminal as dirty to redraw the grid.
    self.flags.dirty.clear = true;

    // Finalize the switch
    self.screens.switchTo(key);

    return old;
}

/// Switch screen via a mode switch (e.g. mode 47, 1047, 1049).
/// This is a much more opinionated operation than `switchScreen`
/// since it also handles the behaviors of the specific mode,
/// such as clearing the screen, saving/restoring the cursor,
/// etc.
///
/// This should be used for legacy compatibility with VT protocols,
/// but more modern usage should use `switchScreen` instead and handle
/// details like clearing the screen, cursor saving, etc. manually.
pub fn switchScreenMode(
    self: *Terminal,
    mode: SwitchScreenMode,
    enabled: bool,
) !void {
    // The behavior in this function is completely based on reading
    // the xterm source, specifically "charproc.c" for
    // `srm_ALTBUF`, `srm_OPT_ALTBUF`, and `srm_OPT_ALTBUF_CURSOR`.
    // We shouldn't touch anything in here without adding a unit
    // test AND verifying the behavior with xterm.

    switch (mode) {
        .@"47" => {},

        // If we're disabling 1047 and we're on alt screen then
        // we clear the screen.
        .@"1047" => if (!enabled and self.screens.active_key == .alternate) {
            self.eraseDisplay(.complete, false);
        },

        // 1049 unconditionally saves the cursor on enabling, even
        // if we're already on the alternate screen.
        .@"1049" => if (enabled) self.saveCursor(),
    }

    // Switch screens first to whatever we're going to.
    const to: ScreenSet.Key = if (enabled) .alternate else .primary;
    const old_ = try self.switchScreen(to);

    switch (mode) {
        // For these modes, we need to copy the cursor. We only copy
        // the cursor if the screen actually changed, otherwise the
        // cursor is already copied. The cursor is copied regardless
        // of destination screen.
        .@"47", .@"1047" => if (old_) |old| {
            self.screens.active.cursorCopy(old.cursor, .{
                .hyperlink = false,
            }) catch |err| {
                log.warn(
                    "cursor copy failed entering alt screen err={}",
                    .{err},
                );
            };
        },

        // Mode 1049 restores cursor on the primary screen when
        // we disable it.
        .@"1049" => if (enabled) {
            assert(self.screens.active_key == .alternate);
            self.eraseDisplay(.complete, false);

            // When we enter alt screen with 1049, we always copy the
            // cursor from the primary screen (if we weren't already
            // on it).
            if (old_) |old| {
                self.screens.active.cursorCopy(old.cursor, .{
                    .hyperlink = false,
                }) catch |err| {
                    log.warn(
                        "cursor copy failed entering alt screen err={}",
                        .{err},
                    );
                };
            }
        } else {
            assert(self.screens.active_key == .primary);
            self.restoreCursor();
        },
    }
}

/// Modal screen changes. These map to the literal terminal
/// modes to enable or disable alternate screen modes. They each
/// have subtle behaviors so we define them as an enum here.
pub const SwitchScreenMode = enum {
    /// Legacy alternate screen mode. This goes to the alternate
    /// screen or primary screen and only copies the cursor. The
    /// screen is not erased.
    @"47",

    /// Alternate screen mode where the alternate screen is cleared
    /// on exit. The primary screen is never cleared. The cursor is
    /// copied.
    @"1047",

    /// Save primary screen cursor, switch to alternate screen,
    /// and clear the alternate screen on entry. On exit,
    /// do not clear the screen, and restore the cursor on the
    /// primary screen.
    @"1049",
};

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
}

/// Same as plainString, but respects row wrap state when building the string.
pub fn plainStringUnwrapped(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAllocUnwrapped(alloc, .{ .viewport = .{} });
}

/// Full reset.
///
/// This will attempt to free the existing screen memory but if that fails
/// this will reuse the existing memory. In the latter case, memory may
/// be wasted (since its unused) but it isn't leaked.
pub fn fullReset(self: *Terminal) void {
    // Ensure we're back on primary screen
    self.screens.switchTo(.primary);
    self.screens.remove(
        self.screens.active.alloc,
        .alternate,
    );

    // Reset our screens
    self.screens.active.reset();

    // Rest our basic state
    self.modes.reset();
    self.flags = .{};
    self.tabstops.reset(TABSTOP_INTERVAL);
    self.previous_char = null;
    self.pwd.clearRetainingCapacity();
    self.status_display = .main;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };

    // Always mark dirty so we redraw everything
    self.flags.dirty.clear = true;
}

/// Returns true if the point is dirty, used for testing.
fn isDirty(t: *const Terminal, pt: point.Point) bool {
    return t.screens.active.pages.getCell(pt).?.isDirty();
}

/// Clear all dirty bits. Testing only.
fn clearDirty(t: *Terminal) void {
    t.screens.active.pages.clearDirty();
}

test "Terminal: input with no control characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 40, .rows = 40 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // The first row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 5, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 5, .y = 1 } }));
}

test "Terminal: input with basic wraparound" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("helloworldabc12") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\nabc12", str);
    }
}

test "Terminal: input with basic wraparound dirty" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 40 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    t.clearDirty();
    try t.print('w');

    // Old row is dirty because cursor moved from there
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: input that forces scroll" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 1, .rows = 5 });
    defer t.deinit(alloc);

    // Basic grid writing
    for ("abcdef") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("b\nc\nd\ne\nf", str);
    }
}

test "Terminal: input unique style per cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    for (0..t.rows) |y| {
        for (0..t.cols) |x| {
            t.setCursorPos(y, x);
            try t.setAttribute(.{ .direct_color_bg = .{
                .r = @intCast(x),
                .g = @intCast(y),
                .b = 0,
            } });
            try t.print('x');
        }
    }
}

test "Terminal: input glitch text" {
    const glitch = @embedFile("res/glitch.txt");
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    // Get our initial grapheme capacity.
    const grapheme_cap = cap: {
        const page = t.screens.active.pages.pages.first.?;
        break :cap page.data.capacity.grapheme_bytes;
    };

    // Print glitch text until our capacity changes
    while (true) {
        const page = t.screens.active.pages.pages.first.?;
        if (page.data.capacity.grapheme_bytes != grapheme_cap) break;
        try t.printString(glitch);
    }

    // We're testing to make sure that grapheme capacity gets increased.
    const page = t.screens.active.pages.pages.first.?;
    try testing.expect(page.data.capacity.grapheme_bytes > grapheme_cap);
}

test "Terminal: zero-width character at start" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // This used to crash the terminal. This is not allowed so we should
    // just ignore it.
    try t.print(0x200D);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    // Should not be dirty since we changed nothing.
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

// https://github.com/mitchellh/ghostty/issues/1400
test "Terminal: print single very long line" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // This would crash for issue 1400. So the assertion here is
    // that we simply do not crash.
    for (0..1000) |_| try t.print('x');
}

test "Terminal: print wide char" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print wide char at edge creates spacer head" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.setCursorPos(1, 10);
    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 9, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    // Our first row just had a spacer head added which does not affect
    // rendering so only the place where the wide char was printed
    // should be marked.
    // BUT old row is dirty because cursor moved from there
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: print wide char with 1-column width" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 1, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('😀'); // 0x1F600

    // This prints a space so we should be dirty.
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print wide char in single-width terminal" {
    var t = try init(testing.allocator, .{ .cols = 1, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    t.setCursorPos(0, 0);
    try t.print('A');

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
}

test "Terminal: print over wide spacer tail" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    try t.print('橋');
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'X'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char with bold" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .bold = {} });
    try t.print(0x1F600); // Smiley face
    // verify we have styles in our style map
    {
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }

    // Go back and overwrite with no style
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A'); // Smiley face

    // verify our style is gone
    {
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over wide char with bg color" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.print(0x1F600); // Smiley face
    // verify we have styles in our style map
    {
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
    }

    // Go back and overwrite with no style
    t.setCursorPos(0, 0);
    try t.setAttribute(.{ .unset = {} });
    try t.print('A'); // Smiley face

    // verify our style is gone
    {
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 0), page.styles.count());
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print multicodepoint grapheme, disabled mode 2027" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have 6 cells taken up
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 6), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F469), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F467), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expect(list_cell.node.data.lookupGrapheme(cell) == null);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
        try testing.expect(list_cell.node.data.lookupGrapheme(cell) == null);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: VS16 doesn't make character with 2027 disabled" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
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
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: ignored VS16 doesn't mark dirty" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print(0x2764); // Heart
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    t.clearDirty();
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print invalid VS16 non-grapheme" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);

    // We should have 1 narrow cell.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
    }
}

test "Terminal: invalid VS16 doesn't mark dirty" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    try t.print('x');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    t.clearDirty();
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print multicodepoint grapheme, mode 2027" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
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
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 4), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: keypad sequence VS15" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "#︎" (number sign with text presentation selector)
    try t.print(0x23); // # Number sign (valid base)
    try t.print(0xFE0E); // VS15 (text presentation selector)

    // VS15 should combine with the base character into a single grapheme cluster,
    // taking 1 cell (narrow character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: keypad sequence VS16" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "#️" (number sign with emoji presentation selector)
    try t.print(0x23); // # Number sign (valid base)
    try t.print(0xFE0F); // VS16 (emoji presentation selector)

    // VS16 should combine with the base character into a single grapheme cluster,
    // taking 2 cells (wide character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x23), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}

test "Terminal: Fitzpatrick skin tone next valid base" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "👋🏿" (waving hand with dark skin tone)
    try t.print(0x1F44B); // 👋 Waving hand (valid base)
    try t.print(0x1F3FF); // 🏿 Dark skin tone modifier

    // The skin tone should combine with the base emoji into a single grapheme cluster,
    // taking 2 cells (wide character).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // The base emoji should be in cell 0 with the skin tone as a grapheme
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F44B), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
}

test "Terminal: Fitzpatrick skin tone next to non-base" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // This is: "🏿" (which may not render correctly in your editor!)
    try t.print(0x22); // "
    try t.print(0x1F3FF); // Dark skin tone
    try t.print(0x22); // "

    // We should have 4 cells taken up. Importantly, the skin tone
    // should not join with the quotes.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    // Row should be dirty
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F3FF), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x22), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: multicodepoint grapheme marks dirty on every codepoint" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/289
    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x200D);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x1F469);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x200D);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0x1F467);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: VS15 to make narrow character" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2614); // Umbrella with rain drops, width=2
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    // VS15 should send us back a cell since our char is no longer wide.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("☔︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS15 on already narrow emoji" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain, width=1
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    // Character takes up one cell
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("⛈︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x26C8), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS15 following emoji is wide" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('\u{1F9E0}'); // 🧠
    try t.print(0xFE0E); // not valid with U+1F9E0 as base

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F9E0}'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print invalid VS15 in emoji ZWJ sequence" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('\u{1F469}'); // 👩
    try t.print(0xFE0E); // not valid with U+1F469 as base
    try t.print('\u{200D}'); // ZWJ
    try t.print('\u{1F466}'); // 👦

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '\u{1F469}'), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ '\u{200D}', '\u{1F466}' }, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS15 to make narrow character with pending wrap" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 4 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try testing.expect(t.modes.get(.wraparound));

    try t.print(0x1F34B); // Lemon, width=2
    try t.print(0x2614); // Umbrella with rain drops, width=2
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    // We only move to the end of the line because we're in a pending wrap
    // state.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    // VS15 should clear the pending wrap state
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("🍋☔︎", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2614), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }

    // VS15 should not affect the previous grapheme
    {
        const lemon_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0x1F34B), lemon_cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, lemon_cell.wide);
        const spacer_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?.cell;
        try testing.expectEqual(@as(u21, 0), spacer_cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.spacer_tail, spacer_cell.wide);
    }
}

test "Terminal: VS16 to make wide character on next line" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(2);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 0 } }));
    t.clearDirty();

    try t.print(0xFE0F); // VS16 to make wide

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 0 } }));
    t.clearDirty();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // '#' cell is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        // spacer_tail
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS16 to make wide character with pending wrap" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(1);
    try t.print('#');
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    try t.print(0xFE0F); // VS16 to make wide

    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        // '#' cell is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '#'), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0xFE0F}, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        // spacer_tail
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: VS16 to make wide character with mode 2027" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: VS16 repeated with mode 2027" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide
    try t.print(0x2764); // Heart
    try t.print(0xFE0F); // VS16 to make wide

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("❤️❤️", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x2764), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = list_cell.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }
}

test "Terminal: print invalid VS16 grapheme" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F); // invalid VS16

    // We should have 1 cells taken up, and narrow.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print invalid VS16 with second char" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('x');
    try t.print(0xFE0F);
    try t.print('y');

    // We should have 2 cells taken up, from two separate narrow characters.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'x'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'y'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print grapheme ò (o with nonspacing mark) should be narrow" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print('o');
    try t.print(0x0300); // combining grave accent

    // We should have 1 cell taken up.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'o'), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0300}, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide on next line" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 3 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorRight(2);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    // This one increases the width to wide
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // Devanagari grapheme is wide
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print Devanagari grapheme should be wide on next page" {
    const rows = pagepkg.std_capacity.rows;
    const cols = pagepkg.std_capacity.cols;
    var t = try init(testing.allocator, .{ .rows = rows, .cols = cols });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    t.cursorDown(rows - 1);

    for (rows..t.screens.active.pages.pages.first.?.data.capacity.rows) |_| {
        try t.index();
    }

    t.cursorRight(cols - 1);

    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);

    // क्‍ष
    try t.print(0x0915);
    try t.print(0x094D);
    try t.print(0x200D);
    try testing.expectEqual(cols - 1, t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    // This one increases the width to wide
    try t.print(0x0937);

    // We should have 2 cells taken up. It is one character but "wide".
    try testing.expectEqual(rows - 1, t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    {
        // Previous cell turns into spacer_head
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = cols - 1, .y = rows - 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        // Devanagari grapheme is wide
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0915), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x094D, 0x200D, 0x0937 }, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = rows - 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print invalid VS16 with second char (combining)" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    // https://github.com/mitchellh/ghostty/issues/1482
    try t.print('n');
    try t.print(0xFE0F); // invalid VS16
    try t.print(0x0303); // combining tilde

    // We should have 1 cells taken up, and narrow.
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'n'), cell.content.codepoint);
        try testing.expect(cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{'\u{0303}'}, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: overwrite grapheme should clear grapheme data" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.print(0x26C8); // Thunder cloud and rain
    try t.print(0xFE0E); // VS15 to make narrow
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    t.clearDirty();

    t.setCursorPos(1, 1);
    try t.print('A');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: overwrite multicodepoint grapheme clears grapheme data" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
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
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // We should have one cell with graphemes
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Move back and overwrite wide
    t.setCursorPos(1, 1);
    t.clearDirty();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: overwrite multicodepoint grapheme tail clears grapheme data" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
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
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // We should have one cell with graphemes
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Move back and overwrite wide
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}

test "Terminal: print breaks valid grapheme cluster with Prepend + ASCII for speed" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.modes.set(.grapheme_cluster, true);

    // Make sure we're not at cursor.x == 0 for the next char.
    try t.print('_');

    // U+0600 ARABIC NUMBER SIGN (Prepend)
    try t.print(0x0600);
    try t.print('1');

    // We should have 3 cells taken up, each narrow. Note that this is
    // **incorrect** grapheme break behavior, since a Prepend code point should
    // not break with the one following it per UAX #29 GB9b. However, as an
    // optimization we assume a grapheme break when c <= 255, and note that
    // this deviation only affects these very uncommon scenarios (e.g. the
    // Arabic number sign should precede Arabic-script digits).
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 3), t.screens.active.cursor.x);
    // This is what we'd expect if we did break correctly:
    //try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);

    // Assert various properties about our screen to verify
    // we have all expected cells.
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x0600), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        // This is what we'd expect if we did break correctly:
        //try testing.expect(cell.hasGrapheme());
        //try testing.expectEqualSlices(u21, &.{'1'}, list_cell.node.data.lookupGrapheme(cell).?);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint);
        // This is what we'd expect if we did break correctly:
        //try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expect(!cell.hasGrapheme());
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 2 });
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
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    t.screens.active.scroll(.{ .active = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }

    try testing.expect(t.isDirty(.{ .active = .{
        .x = t.screens.active.cursor.x,
        .y = t.screens.active.cursor.y,
    } }));
}

test "Terminal: print charset" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // No dirty to configure charset
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // Basic grid writing
    try t.print('`');
    t.configureCharset(.G0, .utf8);
    try t.print('`');
    t.configureCharset(.G0, .ascii);
    try t.print('`');
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print charset outside of ASCII" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // No dirty to configure charset
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // Basic grid writing
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆ ", str);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print invoke charset" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    try t.print('`');

    // Invokecharset but should not mark dirty on its own
    t.clearDirty();
    t.invokeCharset(.GL, .G1, false);
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try t.print('`');
    t.invokeCharset(.GL, .G0, false);
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}

test "Terminal: print invoke charset single" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, true);
    try t.print('`');
    try t.print('`');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
    }
}

test "Terminal: print kitty unicode placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    try t.print(kitty.graphics.unicode.placeholder);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.x);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, kitty.graphics.unicode.placeholder), cell.content.codepoint);
        try testing.expect(list_cell.row.kitty_virtual_placeholder);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: soft wrap" {
    var t = try init(testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}

test "Terminal: soft wrap with semantic prompt" {
    var t = try init(testing.allocator, .{ .cols = 3, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Mark our prompt.
    try t.semanticPrompt(.init(.prompt_start));
    // Should not make anything dirty on its own.
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    // Write and wrap
    for ("hello") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

test "Terminal: disabled wraparound with wide char and one space" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    t.clearDirty();
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA", str);
    }

    // Make sure we printed nothing
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: disabled wraparound with wide char and no space" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAAA");
    t.clearDirty();
    try t.print(0x1F6A8); // Police car light
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAA", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: disabled wraparound with wide grapheme and half space" {
    var t = try init(testing.allocator, .{ .rows = 5, .cols = 5 });
    defer t.deinit(testing.allocator);

    t.modes.set(.grapheme_cluster, true);
    t.modes.set(.wraparound, false);

    // This puts our cursor at the end and there is NO SPACE for a
    // wide character.
    try t.printString("AAAA");
    try t.print(0x2764); // Heart
    t.clearDirty();
    try t.print(0xFE0F); // VS16 to make wide
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAA❤", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '❤'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }

    // Should not be dirty since we didn't modify anything
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print right margin wrap" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 5 });
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

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: print right margin wrap dirty tracking" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);

    // Writing our X on the first line should mark only that line dirty.
    t.clearDirty();
    try t.print('X');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 2, .y = 1 } }));

    // Writing our Y should wrap. It marks both rows dirty because the
    // cursor moved.
    t.clearDirty();
    try t.print('Y');
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 2, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1234X6789\n  Y", str);
    }
}

test "Terminal: print right margin outside" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    try t.printString("123456789");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 6);
    t.clearDirty();
    try t.printString("XY");

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("12345XY89", str);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 5, .y = 0 } }));
}

test "Terminal: print right margin outside wrap" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 5 });
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

test "Terminal: print wide char at right margin does not create spacer head" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 5);
    try t.print(0x1F600); // Smiley face
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.x);

    // Both rows dirty because the cursor moved
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 4, .y = 1 } }));

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);

        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x1F600), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: print with hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");

    // Verify all our cells have a hyperlink
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print over cell with same hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123456");
    t.setCursorPos(1, 1);
    try t.printString("123456");

    // Verify all our cells have a hyperlink
    for (0..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print and end hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("123");
    t.screens.active.endHyperlink();
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: print and change hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    try t.screens.active.startHyperlink("http://two.example.com", null);
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (3..6) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 2), id);
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: overwrite hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Setup our hyperlink and print
    try t.screens.active.startHyperlink("http://one.example.com", null);
    try t.printString("123");
    t.setCursorPos(1, 1);
    t.screens.active.endHyperlink();
    try t.printString("456");

    // Verify all our cells have a hyperlink
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const page = &list_cell.node.data;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        try testing.expect(page.lookupHyperlink(cell) == null);
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
}

test "Terminal: linefeed and carriage return" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Print and CR.
    for ("hello") |c| try t.print(c);
    t.clearDirty();
    t.carriageReturn();

    // CR should not mark row dirty because it doesn't change rendering.
    try testing.expect(!t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    try t.linefeed();

    // LF marks row dirty due to cursor movement
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));

    for ("world") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nworld", str);
    }
}

test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    t.clearDirty();
    try t.linefeed();
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .screen = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}

test "Terminal: linefeed mode automatic carriage return" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
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
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screens.active.cursor.pending_wrap == false);
}

test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.modes.set(.origin, true);
    t.screens.active.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.screens.active.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.allocator, .{ .cols = 5, .rows = 80 });
    defer t.deinit(testing.allocator);

    t.screens.active.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "Terminal: backspace" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // BS
    for ("hello") |c| try t.print(c);
    t.backspace();
    try t.print('y');
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("helly", str);
    }
}

test "Terminal: horizontal tabs" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    // HT
    try t.print('1');
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);

    // HT
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);

    // HT at the end
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screens.active.cursor.x);
}

test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}

test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(t.screens.active.cursor.y, 1);
    try t.print('X');
    t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}

test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    // Edge of screen
    t.setCursorPos(t.screens.active.cursor.y, 20);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 8), t.screens.active.cursor.x);

    // HT
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    t.horizontalTabBack();
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(t.screens.active.cursor.y, 9);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y, 9);
    t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}

test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.setCursorPos(1, 2);
    try t.print('X');
    t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}

test "Terminal: horizontal tab back with cursor before left margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 0);
    t.restoreCursor();
    t.horizontalTabBack();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: cursorPos resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(1, 1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE", str);
    }
}

test "Terminal: cursorPos off the screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Setting it to 0 should keep it zero (1 based)
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Should clamp to size
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    // Should reset pending wrap
    t.setCursorPos(0, 80);
    try t.print('c');
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.setCursorPos(0, 80);
    try testing.expect(!t.screens.active.cursor.pending_wrap);

    // Origin mode
    t.modes.set(.origin, true);

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    // Set the scroll region
    t.setTopAndBottomMargin(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screens.active.cursor.y);

    t.setTopAndBottomMargin(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screens.active.cursor.y);
}

test "Terminal: setTopAndBottomMargin simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(0, 0);

    t.clearDirty();
    t.scrollDown(1);

    // Mark the rows we moved as dirty.
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top only" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 0);

    t.clearDirty();
    t.scrollDown(1);

    // This is dirty because the cursor moves from this row
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top and bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(1, 2);

    t.clearDirty();
    t.scrollDown(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nGHI", str);
    }
}

test "Terminal: setTopAndBottomMargin top equal to bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 2);

    t.clearDirty();
    t.scrollDown(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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

    t.clearDirty();
    t.eraseChars(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" BC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin left only" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 0);
    try testing.expectEqual(@as(usize, 1), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, t.cols - 1), t.scrolling_region.right);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

test "Terminal: setLeftAndRightMargin left and right" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C\nABF\nDEI\nGH", str);
    }
}

test "Terminal: setLeftAndRightMargin left equal right" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 2);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: setLeftAndRightMargin mode 69 unset" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, false);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines colors with bg color" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }

    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: insertLines handles style refs" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();

    // For the line being deleted, create a refcounted style
    try t.setAttribute(.{ .bold = {} });
    try t.printString("GHI");
    try t.setAttribute(.{ .unset = {} });

    // verify we have styles in our style map
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    t.setCursorPos(2, 2);
    t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF", str);
    }

    // verify we have no styles in our style map
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: insertLines outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: insertLines top/bottom scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("123");
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\n123", str);
    }
}

test "Terminal: insertLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 10, .max_scrollback = 1024 });
    defer t.deinit(alloc);

    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.data.capacity.rows;

    // Fill up the first page minus 3 rows
    for (0..first_page_nrows - 3) |_| try t.linefeed();

    // Add content that will cross a page boundary
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");

    // Verify we now have a second page
    try testing.expect(first_page.next != null);

    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n1AAAA\n2BBBB\n3CCCC\n4DDDD", str);
    }
}

test "Terminal: insertLines (legacy test)" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
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
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    t.insertLines(0);
}

test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 6 });
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

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}

test "Terminal: insertLines more than remaining" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
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
    t.clearDirty();
    t.insertLines(20);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: insertLines resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.insertLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}

test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertLines(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n1\nABC", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: insertLines multi-codepoint graphemes" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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

test "Terminal: insertLines left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.insertLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollUp simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    const viewport_before = t.screens.active.pages.getTopLeft(.viewport);
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    // Viewport should have moved. Our entire page should've scrolled!
    // The viewport moving will cause our render state to make the full
    // frame as dirty.
    const viewport_after = t.screens.active.pages.getTopLeft(.viewport);
    try testing.expect(!viewport_before.eql(viewport_after));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
}

test "Terminal: scrollUp moves hyperlink" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = &list_cell.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: scrollUp clears hyperlink" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: scrollUp top/bottom scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);

    t.clearDirty();
    try t.scrollUp(1);

    // This is dirty because the cursor moves from this row
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

test "Terminal: scrollUp left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    t.clearDirty();
    try t.scrollUp(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

test "Terminal: scrollUp left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("DEF456");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }

    // First row gets some hyperlinks
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }

    // Second row preserves hyperlink where we didn't scroll
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }
}

test "Terminal: scrollUp preserves pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.setCursorPos(2, 5);
    try t.print('B');
    t.setCursorPos(3, 5);
    try t.print('C');
    try t.scrollUp(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B\n    C\n\nX", str);
    }
}

test "Terminal: scrollUp full top/bottom region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.setTopAndBottomMargin(2, 5);

    t.clearDirty();
    try t.scrollUp(4);

    // This is dirty because the cursor moves from this row
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top", str);
    }
}

test "Terminal: scrollUp full top/bottomleft/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 5);
    t.setLeftAndRightMargin(2, 4);

    t.clearDirty();
    try t.scrollUp(4);

    // This is dirty because the cursor moves from this row
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..5) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top\n\n\n\nA   E", str);
    }
}

test "Terminal: scrollUp creates scrollback in primary screen" {
    // When in primary screen with full-width scroll region at top,
    // scrollUp (CSI S) should push lines into scrollback like xterm.
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5, .max_scrollback = 10 });
    defer t.deinit(alloc);

    // Fill the screen with content
    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEE");

    t.clearDirty();

    // Scroll up by 1, which should push "AAAAA" into scrollback
    try t.scrollUp(1);

    // The cursor row (new empty row) should be dirty
    try testing.expect(t.screens.active.cursor.page_row.dirty);

    // The active screen should now show BBBBB through EEEEE plus one blank line
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }

    // Now scroll to the top to see scrollback - AAAAA should be there
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // Should see AAAAA in scrollback
        try testing.expectEqualStrings("AAAAA\nBBBBB\nCCCCC\nDDDDD\nEEEEE", str);
    }
}

test "Terminal: scrollUp with max_scrollback zero" {
    // When max_scrollback is 0, scrollUp should still work but not retain history
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5, .max_scrollback = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");

    try t.scrollUp(1);

    // Active screen should show scrolled content
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }

    // Scroll to top - should be same as active since no scrollback
    t.screens.active.scroll(.{ .top = {} });
    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        try testing.expectEqualStrings("BBBBB\nCCCCC", str);
    }
}

test "Terminal: scrollUp with max_scrollback zero and top margin" {
    // When max_scrollback is 0 and top margin is set, should use deleteLines path
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5, .max_scrollback = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("BBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DDDDD");

    // Set top margin (not at row 0)
    t.setTopAndBottomMargin(2, 5);

    try t.scrollUp(1);

    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // First row preserved, rest scrolled
        try testing.expectEqualStrings("AAAAA\nCCCCC\nDDDDD", str);
    }
}

test "Terminal: scrollUp with max_scrollback zero and left/right margin" {
    // When max_scrollback is 0 with left/right margins, uses deleteLines path
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 10, .max_scrollback = 0 });
    defer t.deinit(alloc);

    try t.printString("AAAAABBBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("CCCCCDDDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("EEEEEFFFFF");

    // Set left/right margins (columns 2-6, 1-indexed = indices 1-5)
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 6);

    try t.scrollUp(1);

    {
        const str = try t.plainString(alloc);
        defer alloc.free(str);
        // cols 1-5 scroll, col 0 and cols 6+ preserved
        try testing.expectEqualStrings("ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF", str);
    }
}

test "Terminal: scrollDown simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..5) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

test "Terminal: scrollDown hyperlink moves" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
        const page = &list_cell.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: scrollDown outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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

    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    // This is dirty because the cursor moves from this row
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\n\nGHI", str);
    }
}

test "Terminal: scrollDown left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..4) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollDown left/right scroll region hyperlink" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC123");
    t.screens.active.endHyperlink();
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }

    // First row preserves hyperlink where we didn't scroll
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
    }

    // Second row gets some hyperlinks
    {
        for (0..1) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
        for (1..4) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const row = list_cell.row;
            try testing.expect(row.hyperlink);
            const cell = list_cell.cell;
            try testing.expect(cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell).?;
            try testing.expectEqual(@as(hyperlink.Id, 1), id);
            const page = &list_cell.node.data;
            try testing.expectEqual(1, page.hyperlink_set.count());
        }
        for (4..6) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            const cell = list_cell.cell;
            try testing.expect(!cell.hyperlink);
            const id = list_cell.node.data.lookupHyperlink(cell);
            try testing.expect(id == null);
        }
    }
}

test "Terminal: scrollDown outside of left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 1);

    const cursor = t.screens.active.cursor;
    t.clearDirty();
    t.scrollDown(1);
    try testing.expectEqual(cursor.x, t.screens.active.cursor.x);
    try testing.expectEqual(cursor.y, t.screens.active.cursor.y);

    for (0..4) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

test "Terminal: scrollDown preserves pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 10 });
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
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseChars(2);
    try t.print('X');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X C", str);
    }
}

test "Terminal: eraseChars minimum one" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseChars(0);
    try t.print('X');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC", str);
    }
}

test "Terminal: eraseChars beyond screen edge" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
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

test "Terminal: eraseChars resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: eraseChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }

    t.setCursorPos(1, 1);
    t.eraseChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE\n123", str);
    }
}

test "Terminal: eraseChars preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseChars handles refcounted styles" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.print('B');
    try t.setAttribute(.{ .unset = {} });
    try t.print('C');

    // verify we have styles in our style map
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    t.setCursorPos(1, 1);
    t.eraseChars(2);

    // verify we have no styles in our style map
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: eraseChars protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseChars protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseChars wide char boundary conditions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);

    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }

    t.setCursorPos(1, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     b😀", str);
    }
}

test "Terminal: eraseChars wide char splits proper cell boundaries" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 1, .cols = 30 });
    defer t.deinit(alloc);

    // This is a test for a bug: https://github.com/ghostty-org/ghostty/issues/2817
    // To explain the setup:
    // (1) We need our wide characters starting on an even (1-based) column.
    // (2) We need our cursor to be in the middle somewhere.
    // (3) We need our count to be less than our cursor X and on a split cell.
    // The bug was that we split the wrong cell boundaries.

    try t.printString("x食べて下さい");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べて下さい", str);
    }

    t.setCursorPos(1, 6); // At: て
    t.eraseChars(4); // Delete: て下
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("x食べ    さい", str);
    }
}

test "Terminal: eraseChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }

    t.setCursorPos(2, 2);
    t.eraseChars(3);
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n    cde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......     cde\n😀......", unwrapped);
    }
}

test "Terminal: reverseIndex" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    try t.print('C');
    t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('D');

    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

test "Terminal: reverseIndex top of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 10 });
    defer t.deinit(alloc);

    // Initial value
    t.setCursorPos(2, 1);
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

    // Set our scroll region
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nX\nA\nB\nC", str);
    }
}

test "Terminal: reverseIndex top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(1, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nB\nC", str);
    }
}

test "Terminal: reverseIndex not top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(2, 1);
    t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nB\nC", str);
    }
}

test "Terminal: reverseIndex top/bottom margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\nB", str);
    }
}

test "Terminal: reverseIndex outside top/bottom margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC", str);
    }
}

test "Terminal: reverseIndex left/right margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 2);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

test "Terminal: reverseIndex outside left/right margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 1);
    t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: index" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try t.index();
    try t.print('A');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.cursorLeft(1); // undo moving right from 'A'

    t.clearDirty();
    try t.index();
    try t.print('B');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

test "Terminal: index scrolling with hyperlink" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    t.cursorLeft(1); // undo moving right from 'A'
    try t.index();
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 3,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 4,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    t.setTopAndBottomMargin(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}

test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('B');
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

test "Terminal: index no scroll region, top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of primary screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\n X", str);
    }
}

test "Terminal: index bottom of primary screen background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 4,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: index inside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

test "Terminal: index bottom of scroll region with hyperlinks" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 2);
    try t.print('A');
    try t.index();
    t.carriageReturn();
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('B');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('C');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nC", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = 1,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: index bottom of scroll region clear hyperlinks" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5, .max_scrollback = 0 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    try t.screens.active.startHyperlink("http://example.com", null);
    try t.print('A');
    t.screens.active.endHyperlink();
    try t.index();
    t.carriageReturn();
    try t.print('B');
    try t.index();
    t.carriageReturn();
    try t.print('C');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nB\nC", str);
    }

    for (1..3) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .viewport = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
        const page = &list_cell.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Terminal: index bottom of scroll region with background SGR" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n\nB", str);
    }

    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: index bottom of primary screen with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(5, 1);
    t.clearDirty();
    try t.index();
    try t.index();
    try t.index();
    try t.print('X');

    for (0..4) |y| try testing.expect(!t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nA\n\nX", str);
    }
}

test "Terminal: index outside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    t.setCursorPos(3, 1);
    t.clearDirty();
    try t.index();
    try t.print('X');

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX A", str);
    }
}

test "Terminal: index inside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("AAAAAA");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(1, 3);
    t.setLeftAndRightMargin(1, 3);
    t.setCursorPos(3, 1);

    t.clearDirty();
    try t.index();

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAAA\nAAAAAA\n   AAA", str);
    }
}

test "Terminal: index bottom of scroll region creates scrollback" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.index();
    try t.print('Y');

    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\nY\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\nY\nX", str);
    }
}

test "Terminal: index bottom of scroll region no scrollback" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5, .max_scrollback = 0 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    t.clearDirty();
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n X\nB", str);
    }
}

test "Terminal: index bottom of scroll region blank line preserves SGR" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.printString("1\n2\n3");
    t.setCursorPos(4, 1);
    try t.print('X');
    t.setCursorPos(3, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    try t.index();

    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2\n3\n\nX", str);
    }
    {
        const str = try t.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1\n2\n3\n\nX", str);
    }
    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 2,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: cursorUp basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X\n\nA", str);
    }
}

test "Terminal: cursorUp below top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(2, 4);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.cursorUp(5);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n X\nA", str);
    }
}

test "Terminal: cursorUp above top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(3, 5);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(2, 1);
    t.cursorUp(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n\nA", str);
    }
}

test "Terminal: cursorUp resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorUp(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft no wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    t.cursorLeft(10);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCXE", str);
    }
}

test "Terminal: cursorLeft unsets pending wrap state with longer jump" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(3);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AXCDE", str);
    }
}

test "Terminal: cursorLeft reverse wrap with pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft reverse wrap extended with pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorLeft reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE1") |c| try t.print(c);
    t.cursorLeft(2);
    try t.print('X');
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft reverse wrap with no soft wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\nX", str);
    }
}

test "Terminal: cursorLeft reverse wrap before left margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.setTopAndBottomMargin(3, 0);
    t.cursorLeft(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap bottom wraparound" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap is priority if both set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    try t.print('1');
    t.cursorLeft(1 + t.cols + 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n1\n    X", str);
    }
}

test "Terminal: cursorLeft extended reverse wrap above top scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(2, 1);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "Terminal: cursorLeft reverse wrap on first row" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(1, 2);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "Terminal: cursorDown basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\n X", str);
    }
}

test "Terminal: cursorDown above bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n X", str);
    }
}

test "Terminal: cursorDown below bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    t.setCursorPos(4, 1);
    t.cursorDown(10);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\n\nX", str);
    }
}

test "Terminal: cursorDown resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorDown(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n    X", str);
    }
}

test "Terminal: cursorRight resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.cursorRight(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: cursorRight to the edge of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: cursorRight left of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

test "Terminal: cursorRight right of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.setCursorPos(1, 4);
    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: deleteLines simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.deleteLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

test "Terminal: deleteLines colors with bg color" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI");
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }

    for (0..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 4,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: deleteLines across page boundary marks all shifted rows dirty" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 10, .max_scrollback = 1024 });
    defer t.deinit(alloc);

    const first_page = t.screens.active.pages.pages.first.?;
    const first_page_nrows = first_page.data.capacity.rows;

    // Fill up the first page minus 3 rows
    for (0..first_page_nrows - 3) |_| try t.linefeed();

    // Add content that will cross a page boundary
    try t.printString("1AAAA");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("2BBBB");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("3CCCC");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("4DDDD");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("5EEEE");

    // Verify we now have a second page
    try testing.expect(first_page.next != null);

    t.setCursorPos(1, 1);
    t.clearDirty();
    t.deleteLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("2BBBB\n3CCCC\n4DDDD\n5EEEE", str);
    }
}

test "Terminal: deleteLines (legacy)" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 80, .rows = 80 });
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

    t.cursorUp(2);
    t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 80, .rows = 80 });
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.deleteLines(1);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, large count" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 80, .rows = 80 });
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.deleteLines(5);

    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\n\n\nD", str);
    }
}

test "Terminal: deleteLines with scroll region, cursor outside of region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 80, .rows = 80 });
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);

    t.clearDirty();
    t.deleteLines(1);

    for (0..4) |y| try testing.expect(!t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC\nD", str);
    }
}

test "Terminal: deleteLines resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteLines(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B", str);
    }
}

test "Terminal: deleteLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    try t.print('1');
    t.carriageReturn();
    try t.linefeed();
    for ("ABCDEF") |c| try t.print(c);

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);
    t.deleteLines(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBC\n\nDEF", str);
    }

    for (0..t.rows) |y| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }
}

test "Terminal: deleteLines left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.deleteLines(1);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nDHI756\nG   89", str);
    }
}

test "Terminal: deleteLines left/right scroll region from top" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteLines(1);

    for (0..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

test "Terminal: deleteLines left/right scroll region high count" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DEF456");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GHI789");
    t.scrolling_region.left = 1;
    t.scrolling_region.right = 3;
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.deleteLines(100);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    for (1..3) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nG   89", str);
    }
}

test "Terminal: deleteLines wide character spacer head" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    // Delete the top line
    // +-----+
    // |BBBB | < Non-wrapped
    // |WWCCC| < Non-wrapped
    // |     | < Non-wrapped
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, and un-set wrap.
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", str);
        try testing.expectEqualStrings("BBBB\n\u{1F600}CCC", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.left = 2;

    // Delete the top line
    //    ###  <- scrolling region
    // +-----+
    // |AABB | < Wrapped
    // |BBCCC| < Wrapped     (continued)
    // |WW   | < Non-wrapped (continued)
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, but due to the
    // left scrolling margin, wrap state should
    // remain.
    t.setCursorPos(1, 3);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABB\nBBCCC\n\u{1F600}", str);
        try testing.expectEqualStrings("AABB BBCCC\u{1F600}", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head right scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;

    // Delete the top line
    //  ####   <- scrolling region
    // +-----+
    // |BBBBA| < Wrapped
    // |WWCC | < Wrapped     (continued)
    // |    C| < Non-wrapped (continued)
    // +-----+
    // This should convert the spacer head to
    // a regular empty cell, but due to the
    // right scrolling margin, wrap state should
    // remain.
    t.setCursorPos(1, 1);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("BBBBA\n\u{1F600}CC\n    C", str);
        try testing.expectEqualStrings("BBBBA\u{1F600}CC     C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left and right scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 2;

    // Delete the top line
    //    ##   <- scrolling region
    // +-----+
    // |AABBA| < Wrapped
    // |BBCC*| < Wrapped     (continued)
    // |WW  C| < Non-wrapped (continued)
    // +-----+
    // Because there is both a left scrolling
    // margin > 1 and a right scrolling margin
    // the spacer head should remain, and the
    // wrap state should be untouched.
    t.setCursorPos(1, 3);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("AABBA\nBBCC\n\u{1F600}  C", str);
        try testing.expectEqualStrings("AABBABBCC\u{1F600}  C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide character spacer head left (< 2) and right scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA| < Wrapped
    // |BBBB*| < Wrapped     (continued)
    // |WWCCC| < Non-wrapped (continued)
    // +-----+
    // where * represents a spacer head cell
    // and WW is the wide character.
    try t.printString("AAAAABBBB\u{1F600}CCC");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;

    // Delete the top line
    //   ###   <- scrolling region
    // +-----+
    // |ABBBA| < Wrapped
    // |B CC | < Wrapped     (continued)
    // |    C| < Non-wrapped (continued)
    // +-----+
    // Because the left margin is 1, the wide
    // char is split, and therefore removed,
    // along with the spacer head - however,
    // wrap state should be untouched.
    t.setCursorPos(1, 2);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        const unwrapped_str = try t.plainStringUnwrapped(testing.allocator);
        defer testing.allocator.free(unwrapped_str);
        try testing.expectEqualStrings("ABBBA\nB CC\n    C", str);
        try testing.expectEqualStrings("ABBBAB CC     C", unwrapped_str);
    }
}

test "Terminal: deleteLines wide characters split by left/right scroll region boundaries" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    // Initial value
    // +-----+
    // |AAAAA|
    // |WWBWW|
    // +-----+
    // where WW represents a wide character
    try t.printString("AAAAA\n\u{1F600}B\u{1F600}");

    t.scrolling_region.right = 3;
    t.scrolling_region.left = 1;

    // Delete the top line
    //   ###   <- scrolling region
    // +-----+
    // |A B A|
    // |     |
    // +-----+
    // The two wide chars, because they're
    // split by the edge of the scrolling
    // region, get removed.
    t.setCursorPos(1, 2);
    t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A B A", str);
    }
}

test "Terminal: deleteLines zero" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 5 });
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    t.deleteLines(0);
}

test "Terminal: default style is empty" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.print('A');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expectEqual(@as(style.Id, 0), cell.style_id);
    }
}

test "Terminal: bold style" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'A'), cell.content.codepoint);
        try testing.expect(cell.style_id != 0);
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 1);
    }
}

test "Terminal: garbage collect overwritten" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint);
        try testing.expect(cell.style_id == 0);
    }

    // verify we have no styles in our style map
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Terminal: do not garbage collect old styles in use" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 'B'), cell.content.codepoint);
        try testing.expect(cell.style_id == 0);
    }

    // verify we have no styles in our style map
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}

test "Terminal: print with style marks the row as styled" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    try t.print('A');
    try t.setAttribute(.{ .unset = {} });
    try t.print('B');

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.styled);
    }
}

test "Terminal: DECALN" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);

    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}

test "Terminal: decaln reset margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }
}

test "Terminal: decaln preserves color" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Initial value
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: DECALN resets graphemes with protected mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    // Add protected mode. A previous version of DECALN accidentally preserved
    // protected mode which left dangling managed memory.
    t.setProtectedMode(.iso);

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    t.modes.set(.grapheme_cluster, true);
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(t.screens.active.cursor.protected);
    try testing.expect(t.screens.active.protected_mode == .iso);

    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EEE\nEEE\nEEE", str);
    }
}

test "Terminal: insertBlanks" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks pushes off end" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: insertBlanks more than size" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.insertBlanks(5);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: insertBlanks no scroll region, fits" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);

    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: insertBlanks shift off screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

test "Terminal: insertBlanks split multi-cell character" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    for ("123") |c| try t.print(c);
    try t.print('橋');
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" 123", str);
    }
}

test "Terminal: insertBlanks inside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);

    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

test "Terminal: insertBlanks outside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 4);
    for ("ABC") |c| try t.print(c);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.insertBlanks(2);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   ABX", str);
    }
}

test "Terminal: insertBlanks left/right scroll region large count" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(140);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

test "Terminal: insertBlanks deleting graphemes" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("ABC");

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have one cell with graphemes
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(4);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A", str);
    }

    // We should have no graphemes
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());
}

test "Terminal: insertBlanks shift graphemes" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    try t.printString("A");

    // This is: 👨‍👩‍👧 (which may or may not render correctly)
    try t.print(0x1F468);
    try t.print(0x200D);
    try t.print(0x1F469);
    try t.print(0x200D);
    try t.print(0x1F467);

    // We should have one cell with graphemes
    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    t.setCursorPos(1, 1);
    t.clearDirty();
    t.insertBlanks(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" A👨‍👩‍👧", str);
    }

    // We should have no graphemes
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());
}

test "Terminal: insertBlanks split multi-cell character from tail" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("橋123");
    t.setCursorPos(1, 2);
    t.insertBlanks(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   12", str);
    }
}

test "Terminal: insertBlanks shifts hyperlinks" {
    // osc "8;;http://example.com"
    // printf "link"
    // printf "\r"
    // csi "3@"
    // echo
    //
    // link should be preserved, blanks should not be linked

    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }

    // Verify all our cells have a hyperlink
    for (2..5) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell).?;
        try testing.expectEqual(@as(hyperlink.Id, 1), id);
    }
    for (0..2) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: insertBlanks pushes hyperlink off end completely" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    try t.printString("ABC");
    t.setCursorPos(1, 1);
    t.insertBlanks(3);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    for (0..3) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        const row = list_cell.row;
        try testing.expect(!row.hyperlink);
        const cell = list_cell.cell;
        try testing.expect(!cell.hyperlink);
        const id = list_cell.node.data.lookupHyperlink(cell);
        try testing.expect(id == null);
    }
}

test "Terminal: insert mode with space" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXello", str);
    }
}

test "Terminal: insert mode doesn't wrap pushed characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hXell", str);
    }
}

test "Terminal: insert mode does nothing at the end of the line" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello\nX", str);
    }
}

test "Terminal: insert mode with wide characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("hello") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("h😀el", str);
    }
}

test "Terminal: insert mode with wide characters at end" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("well") |c| try t.print(c);
    t.modes.set(.insert, true);
    try t.print('😀'); // 0x1F600

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("well\n😀", str);
    }
}

test "Terminal: insert mode pushing off wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 2 });
    defer t.deinit(alloc);

    for ("123") |c| try t.print(c);
    try t.print('😀'); // 0x1F600
    t.modes.set(.insert, true);
    t.setCursorPos(1, 1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X123", str);
    }
}

test "Terminal: deleteChars" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ADE", str);
    }
}

test "Terminal: deleteChars zero count" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteChars(0);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE", str);
    }
}

test "Terminal: deleteChars more than half" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteChars(3);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AE", str);
    }
}

test "Terminal: deleteChars more than line width" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteChars(10);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: deleteChars should shift left" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    t.clearDirty();
    t.deleteChars(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ACDE", str);
    }
}

test "Terminal: deleteChars resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.deleteChars(1);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

test "Terminal: deleteChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(row.wrap);
    }
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = list_cell.row;
        try testing.expect(!row.wrap);
    }

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XCDE\n123", str);
    }
}

test "Terminal: deleteChars simple operation" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.setCursorPos(1, 3);

    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
}

test "Terminal: deleteChars preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);

    for ("ABC123") |c| try t.print(c);
    t.setCursorPos(1, 3);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.deleteChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
    for (t.cols - 2..t.cols) |x| {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = @intCast(x),
            .y = 0,
        } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: deleteChars outside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.deleteChars(2);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.screens.active.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123", str);
    }
}

test "Terminal: deleteChars inside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 4);

    t.clearDirty();
    t.deleteChars(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC2 3", str);
    }
}

test "Terminal: deleteChars split wide character from spacer tail" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("A橋123");
    t.setCursorPos(1, 3);
    t.deleteChars(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A 123", str);
    }
}

test "Terminal: deleteChars split wide character from wide" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, '1'), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: deleteChars split wide character from end" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 6, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("A橋123");
    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0x6A4B), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Terminal: deleteChars with a spacer head at the end" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 5, .rows = 10 });
    defer t.deinit(alloc);

    try t.printString("0123橋123");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?;
        const row = list_cell.row;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(row.wrap);
    }

    t.setCursorPos(1, 1);
    t.deleteChars(1);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Terminal: deleteChars split wide character tail" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, t.cols - 1);
    try t.print(0x6A4B); // 橋
    t.carriageReturn();
    t.deleteChars(t.cols - 1);
    try t.print('0');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("0", str);
    }
}

test "Terminal: deleteChars wide char boundary conditions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 1, .cols = 8 });
    defer t.deinit(alloc);

    // EXPLANATION(qwerasd):
    //
    // There are 3 or 4 boundaries to be concerned with in deleteChars,
    // depending on how you count them. Consider the following terminal:
    //
    //   +--------+
    // 0 |.ABCDEF.|
    //   : ^      : (^ = cursor)
    //   +--------+
    //
    // if we DCH 3 we get
    //
    //   +--------+
    // 0 |.DEF....|
    //   +--------+
    //
    // The boundaries exist at the following points then:
    //
    //   +--------+
    // 0 |.ABCDEF.|
    //   :11 22 33:
    //   +--------+
    //
    // I'm counting 2 for double since it's both the end of the deleted
    // content and the start of the content that is shifted in to place.
    //
    // Now consider wide characters (represented as `WW`) at these boundaries:
    //
    //   +--------+
    // 0 |WWaWWbWW|
    //   : ^      : (^ = cursor)
    //   : ^^^    : (^ = deleted by DCH 3)
    //   +--------+
    //
    // -> DCH 3
    // -> The first 2 wide characters are split & destroyed (verified in xterm)
    //
    //   +--------+
    // 0 |..bWW...|
    //   +--------+

    try t.printString("😀a😀b😀");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("😀a😀b😀", str);
    }

    t.setCursorPos(1, 2);
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  b😀", str);
    }
}

test "Terminal: deleteChars wide char wrap boundary conditions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    // EXPLANATION(qwerasd):
    // (cont. from "Terminal: deleteChars wide char boundary conditions")
    //
    // Additionally consider soft-wrapped wide chars (`H` = spacer head):
    //
    //   +--------+
    // 0 |.......H…
    // 1 …WWabcdeH…
    //   : ^      : (^ = cursor)
    //   : ^^^    : (^ = deleted by DCH 3)
    // 2 …WW......|
    //   +--------+
    //
    // -> DCH 3
    // -> First wide character split and destroyed, including spacer head,
    //    second spacer head removed (verified in xterm).
    // -> Wrap state of row reset
    //
    //   +--------+
    // 0 |........|
    // 1 |.cde....|
    // 2 |WW......|
    //   +--------+
    //

    try t.printString(".......😀abcde😀......");
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n😀abcde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......😀abcde😀......", unwrapped);
    }

    t.setCursorPos(2, 2);
    t.deleteChars(3);
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(".......\n cde\n😀......", str);

        const unwrapped = try t.plainStringUnwrapped(alloc);
        defer testing.allocator.free(unwrapped);
        try testing.expectEqualStrings(".......  cde\n😀......", unwrapped);
    }
}

test "Terminal: deleteChars wide char across right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 3, .cols = 8 });
    defer t.deinit(alloc);

    // scroll region
    //    VVVVVV
    //  +-######-+
    //  |.abcdeWW|
    //  : ^      : (^ = cursor)
    //  +--------+
    //
    // DCH 1

    try t.printString("123456橋");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 7);

    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123456橋", str);
    }

    t.setCursorPos(1, 2);
    t.deleteChars(1);
    t.screens.active.cursor.page_pin.node.data.assertIntegrity();

    // NOTE: This behavior is slightly inconsistent with xterm. xterm
    // _visually_ splits the wide character (half the wide character shows
    // up in col 6 and half in col 8). In all other wide char split scenarios,
    // xterm clears the cell. Therefore, we've chosen to clear the cell here.
    // Given we have space, we also could actually preserve it, but I haven't
    // yet found a terminal that behaves that way. We should be open to
    // revisiting this behavior but for now we're going with the simpler
    // impl.
    {
        const str = try t.plainString(alloc);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("13456", str);
    }
}

test "Terminal: saveCursor" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .bold = {} });
    t.screens.active.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.saveCursor();
    t.screens.active.charset.gr = .G0;
    try t.setAttribute(.{ .unset = {} });
    t.modes.set(.origin, false);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.style.flags.bold);
    try testing.expect(t.screens.active.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

test "Terminal: saveCursor position" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   AX", str);
    }
}

test "Terminal: saveCursor pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 5);
    try t.print('A');
    t.saveCursor();
    t.setCursorPos(1, 1);
    try t.print('B');
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B   A\nX", str);
    }
}

test "Terminal: saveCursor origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setTopAndBottomMargin(2, 4);
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

test "Terminal: saveCursor resize" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(1, 10);
    t.saveCursor();
    try t.resize(alloc, 5, 5);
    t.restoreCursor();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

test "Terminal: saveCursor protected pen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setCursorPos(1, 10);
    t.saveCursor();
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.restoreCursor();
    try testing.expect(t.screens.active.cursor.protected);
}

test "Terminal: saveCursor doesn't modify hyperlink state" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.screens.active.startHyperlink("http://example.com", null);
    const id = t.screens.active.cursor.hyperlink_id;
    t.saveCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
    t.restoreCursor();
    try testing.expectEqual(id, t.screens.active.cursor.hyperlink_id);
}

test "Terminal: restoreCursor uses default style on OutOfSpace" {
    // Tests that restoreCursor falls back to default style when
    // manualStyleUpdate fails with OutOfSpace (can't split a 1-row page
    // and styles are at max capacity).
    const alloc = testing.allocator;

    // Use a single row so the page can't be split
    var t = try init(alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // Set a style and save the cursor
    try t.setAttribute(.{ .bold = {} });
    t.saveCursor();

    // Clear the style
    try t.setAttribute(.{ .unset = {} });
    try testing.expect(!t.screens.active.cursor.style.flags.bold);

    // Fill the style map to max capacity
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (t.screens.active.cursor.page_pin.node.data.capacity.styles < max_styles) {
        _ = t.screens.active.increaseCapacity(
            t.screens.active.cursor.page_pin.node,
            .styles,
        ) catch break;
    }

    const page = &t.screens.active.cursor.page_pin.node.data;
    try testing.expectEqual(max_styles, page.capacity.styles);

    // Fill all style slots using the StyleSet's layout capacity which accounts
    // for the load factor. The capacity in the layout is the actual max number
    // of items that can be stored.
    {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);
        defer page.assertIntegrity();

        const max_items = page.styles.layout.cap;
        var n: usize = 1;
        while (n < max_items) : (n += 1) {
            _ = page.styles.add(
                page.memory,
                .{ .bg_color = .{ .rgb = @bitCast(@as(u24, @intCast(n))) } },
            ) catch break;
        }
    }

    // Restore cursor - should fall back to default style since page
    // can't be split (1 row) and styles are at max capacity
    t.restoreCursor();

    // The style should be reset to default because OutOfSpace occurred
    try testing.expect(!t.screens.active.cursor.style.flags.bold);
    try testing.expectEqual(style.default_id, t.screens.active.cursor.style_id);
}

test "Terminal: setProtectedMode" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
    t.setProtectedMode(.iso);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.dec);
    try testing.expect(t.screens.active.cursor.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screens.active.cursor.protected);
}

test "Terminal: eraseLine simple erase right" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.eraseLine(.right, false);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDB", str);
    }
}

test "Terminal: eraseLine resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.wrap);
    }

    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(!list_cell.row.wrap);
    }
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}

test "Terminal: eraseLine right preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine right wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

test "Terminal: eraseLine right protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.right, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: eraseLine right protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("12345678") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.clearDirty();
    t.eraseLine(.right, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123  X", str);
    }
}

test "Terminal: eraseLine simple erase left" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   DE", str);
    }
}

test "Terminal: eraseLine left resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!t.screens.active.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B", str);
    }
}

test "Terminal: eraseLine left preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  CDE", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine left wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    DE", str);
    }
}

test "Terminal: eraseLine left protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.left, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

test "Terminal: eraseLine left protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.clearDirty();
    t.eraseLine(.left, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X  9", str);
    }
}

test "Terminal: eraseLine complete preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
        for (0..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 0,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseLine complete protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.clearDirty();
    t.eraseLine(.complete, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseLine complete protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.clearDirty();
    t.eraseLine(.complete, true);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X", str);
    }
}

test "Terminal: tabClear single" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);

    t.horizontalTab();
    t.tabClear(.current);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screens.active.cursor.x);
}

test "Terminal: tabClear all" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 5 });
    defer t.deinit(alloc);

    t.tabClear(.all);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    t.setCursorPos(1, 1);
    t.horizontalTab();
    try testing.expectEqual(@as(usize, 29), t.screens.active.cursor.x);
}

test "Terminal: printRepeat simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("A");
    try t.printRepeat(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AA", str);
    }
}

test "Terminal: printRepeat wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("    A");
    try t.printRepeat(1);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A\nA", str);
    }
}

test "Terminal: printRepeat no previous character" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printRepeat(1);
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: printAttributes" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var storage: [64]u8 = undefined;

    {
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;38:2::1:2:3", buf);
    }

    {
        try t.setAttribute(.bold);
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;48:2::1:2:3", buf);
    }

    {
        try t.setAttribute(.bold);
        try t.setAttribute(.faint);
        try t.setAttribute(.italic);
        try t.setAttribute(.{ .underline = .single });
        try t.setAttribute(.blink);
        try t.setAttribute(.inverse);
        try t.setAttribute(.invisible);
        try t.setAttribute(.strikethrough);
        try t.setAttribute(.{ .direct_color_fg = .{ .r = 100, .g = 200, .b = 255 } });
        try t.setAttribute(.{ .direct_color_bg = .{ .r = 101, .g = 102, .b = 103 } });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;1;2;3;4;5;7;8;9;38:2::100:200:255;48:2::101:102:103", buf);
    }

    {
        try t.setAttribute(.{ .underline = .single });
        defer t.setAttribute(.unset) catch unreachable;
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0;4", buf);
    }

    {
        const buf = try t.printAttributes(&storage);
        try testing.expectEqualStrings("0", buf);
    }
}

test "Terminal: eraseDisplay simple erase below" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.eraseDisplay(.below, false);

    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay erase below preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
        for (1..5) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseDisplay below split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 4);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB橋C\nDE", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay below protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

test "Terminal: eraseDisplay below protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay simple erase above" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    t.clearDirty();
    t.eraseDisplay(.above, false);
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(t.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(!t.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay erase above preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
        for (0..2) |x| {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{
                .x = @intCast(x),
                .y = 1,
            } }).?;
            try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
            try testing.expectEqual(Cell.RGB{
                .r = 0xFF,
                .g = 0,
                .b = 0,
            }, list_cell.cell.content.color_rgb);
        }
    }
}

test "Terminal: eraseDisplay above split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 3);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    F\nGH橋I", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

test "Terminal: eraseDisplay above protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(.above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

test "Terminal: eraseDisplay protected complete" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);

    t.clearDirty();
    t.eraseDisplay(.complete, true);
    for (0..t.rows) |y| try testing.expect(t.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X", str);
    }
}

test "Terminal: eraseDisplay protected below" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 4);
    t.eraseDisplay(.below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n123  X", str);
    }
}

test "Terminal: eraseDisplay scroll complete" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    t.eraseDisplay(.scroll_complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: eraseDisplay protected above" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screens.active.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screens.active.cursor.y + 1, 8);
    t.eraseDisplay(.above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X  9", str);
    }
}

test "Terminal: eraseDisplay complete preserves cursor" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Set our cursur
    try t.setAttribute(.{ .bold = {} });
    try t.printString("AAAA");
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);

    // Erasing the display may detect that our style is no longer in use
    // and prune our style, which we don't want because its still our
    // active cursor.
    t.eraseDisplay(.complete, false);
    try testing.expect(t.screens.active.cursor.style_id != style.default_id);
}

test "Terminal: semantic prompt" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Prompt
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }

    // Start input but end it on EOL
    try t.semanticPrompt(.init(.end_prompt_start_input_terminate_eol));
    t.carriageReturn();
    try t.linefeed();

    // Write some output
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.output, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.none, row.semantic_prompt);
    }
}

test "Terminal: semantic prompt continuations" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Prompt
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt, row.semantic_prompt);
    }

    // Start input but end it on EOL
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });

    // Write some output
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    for ("world") |c| try t.print(c);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x - 1,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(.prompt, cell.semantic_content);

        const row = list_cell.row;
        try testing.expectEqual(.prompt_continuation, row.semantic_prompt);
    }
}

test "Terminal: index in prompt mode marks new row as prompt continuation" {
    // This tests the Fish shell workaround: when in prompt mode and we get
    // a newline, assume the new row is a prompt continuation (since Fish
    // doesn't emit OSC133 k=s markers for continuation lines).
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("hello") |c| try t.print(c);

    // Verify first row is marked as prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }

    // Now do a linefeed while still in prompt mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should automatically be marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // The cursor semantic content should still be prompt
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}

test "Terminal: index in input mode does not mark new row as prompt" {
    // Input mode should NOT trigger prompt continuation on newline
    // (only prompt mode does, not input mode)
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt then switch to input
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("echo \\") |c| try t.print(c);

    // Linefeed while in input mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should be marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Our cursor should still be in input
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
}

test "Terminal: index in output mode does not mark new row as prompt" {
    // Output mode should NOT trigger prompt continuation
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Complete prompt cycle: prompt -> input -> output
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_prompt_start_input));
    for ("ls") |c| try t.print(c);
    try t.semanticPrompt(.init(.end_input_start_output));

    // Linefeed while in output mode
    t.carriageReturn();
    try t.linefeed();

    // The new row should NOT be marked as a prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}

test "Terminal: OSC133C at x=0 on prompt row clears prompt mark" {
    // This tests the second Fish heuristic: when Fish emits a newline
    // then immediately sends OSC133C (start output) at column 0, we
    // should clear the prompt continuation mark we just set.
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ echo \\") |c| try t.print(c);

    // Simulate Fish behavior: newline first (which marks next row as prompt)
    t.carriageReturn();
    try t.linefeed();

    // Verify the new row is marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Now Fish sends OSC133C at column 0 (cursor is still at x=0)
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try t.semanticPrompt(.init(.end_input_start_output));

    // The prompt continuation should be cleared
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.none, list_cell.row.semantic_prompt);
    }
}

test "Terminal: OSC133C at x>0 on prompt row does not clear prompt mark" {
    // If we're not at column 0, we shouldn't clear the prompt mark
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt on a row
    try t.semanticPrompt(.init(.prompt_start));
    for ("$ ") |c| try t.print(c);

    // Move to a new line and mark it as prompt continuation manually
    t.carriageReturn();
    try t.linefeed();
    try t.semanticPrompt(.{
        .action = .prompt_start,
        .options_unvalidated = "k=c",
    });
    for ("> ") |c| try t.print(c);

    // Verify the row is marked as prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }

    // Now send OSC133C but cursor is NOT at column 0
    try testing.expect(t.screens.active.cursor.x > 0);
    try t.semanticPrompt(.init(.end_input_start_output));

    // The prompt continuation should NOT be cleared (we're not at x=0)
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

test "Terminal: multiple newlines in prompt mode marks all rows" {
    // Multiple newlines should each mark their row as prompt continuation
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Start a prompt
    try t.semanticPrompt(.init(.prompt_start));
    for ("line1") |c| try t.print(c);

    // Multiple newlines
    t.carriageReturn();
    try t.linefeed();
    for ("line2") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("line3") |c| try t.print(c);

    // First row should be prompt
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?;
        try testing.expectEqual(.prompt, list_cell.row.semantic_prompt);
    }

    // Second and third rows should be prompt continuation
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).?;
        try testing.expectEqual(.prompt_continuation, list_cell.row.semantic_prompt);
    }
}

test "Terminal: OSC133A click_events=1 sets click to click_events" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // Verify default state is none
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);

    // OSC 133;A with click_events=1
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1",
    });

    try testing.expectEqual(.click_events, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=0 does not set click_events" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with click_events=0
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0",
    });

    // Should remain none since click_events=0 doesn't activate anything
    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A cl option sets click to cl value" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with cl=m (multiple)
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=m",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .multiple }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A cl=line sets click to line" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "cl=line",
    });

    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .line }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=1 takes priority over cl" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with both click_events=1 and cl=m
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=1;cl=m",
    });

    // click_events should take priority
    try testing.expectEqual(.click_events, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A click_events=0 falls back to cl" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with click_events=0 and cl=v
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "click_events=0;cl=v",
    });

    // Should fall back to cl since click_events is disabled
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick{ .cl = .conservative_vertical }, t.screens.active.semantic_prompt.click);
}

test "Terminal: OSC133A no click options leaves click as none" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    // OSC 133;A with no click-related options
    try t.semanticPrompt(.{
        .action = .fresh_line_new_prompt,
        .options_unvalidated = "aid=123",
    });

    try testing.expectEqual(.none, t.screens.active.semantic_prompt.click);
}

test "Terminal: cursorIsAtPrompt" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
    for ("$ ") |c| try t.print(c);

    // Input is also a prompt
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(t.cursorIsAtPrompt());
    for ("ls") |c| try t.print(c);

    // But once we say we're starting output, we're not a prompt
    // (cursor is not at x=0, so the Fish heuristic doesn't trigger)
    try t.semanticPrompt(.init(.end_input_start_output));
    // Still a prompt because this line has a prompt
    try testing.expect(t.cursorIsAtPrompt());
    try t.linefeed();
    try testing.expect(!t.cursorIsAtPrompt());

    // Until we know we're at a prompt again
    try t.linefeed();
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());
}

test "Terminal: cursorIsAtPrompt alternate screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 2 });
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(t.cursorIsAtPrompt());

    // Secondary screen is never a prompt
    try t.switchScreenMode(.@"1049", true);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.semanticPrompt(.init(.prompt_start));
    try testing.expect(!t.cursorIsAtPrompt());
}

test "Terminal: fullReset with a non-empty pen" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.screens.active.cursor.semantic_content = .input;
    t.fullReset();

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }

    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}

test "Terminal: fullReset hyperlink" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.screens.active.startHyperlink("http://example.com", null);
    t.fullReset();
    try testing.expectEqual(0, t.screens.active.cursor.hyperlink_id);
}

test "Terminal: fullReset with a non-empty saved cursor" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    try t.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });
    t.saveCursor();
    t.fullReset();

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.style_id == 0);
    }

    try testing.expectEqual(@as(style.Id, 0), t.screens.active.cursor.style_id);
}

test "Terminal: fullReset origin mode" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.setCursorPos(3, 5);
    t.modes.set(.origin, true);
    t.fullReset();

    // Origin mode should be reset and the cursor should be moved
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expect(!t.modes.get(.origin));
}

test "Terminal: fullReset status display" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    t.status_display = .status_line;
    t.fullReset();
    try testing.expect(t.status_display == .main);
}

// https://github.com/mitchellh/ghostty/issues/1607
test "Terminal: fullReset clears alt screen kitty keyboard state" {
    var t = try init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    try t.switchScreenMode(.@"1049", true);
    t.screens.active.kitty_keyboard.push(.{
        .disambiguate = true,
        .report_events = false,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    });
    try t.switchScreenMode(.@"1049", false);

    t.fullReset();
    try testing.expect(t.screens.get(.alternate) == null);
}

test "Terminal: fullReset default modes" {
    var t = try init(testing.allocator, .{
        .cols = 10,
        .rows = 10,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer t.deinit(testing.allocator);
    try testing.expect(t.modes.get(.grapheme_cluster));
    t.fullReset();
    try testing.expect(t.modes.get(.grapheme_cluster));
}

test "Terminal: fullReset tracked pins" {
    var t = try init(testing.allocator, .{ .cols = 80, .rows = 80 });
    defer t.deinit(testing.allocator);

    // Create a tracked pin
    const p = try t.screens.active.pages.trackPin(t.screens.active.cursor.page_pin.*);
    t.fullReset();
    try testing.expect(t.screens.active.pages.pinIsValid(p.*));
}

// https://github.com/mitchellh/ghostty/issues/272
// This is also tested in depth in screen resize tests but I want to keep
// this test around to ensure we don't regress at multiple layers.
test "Terminal: resize less cols with wide char then print" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    try t.print('x');
    try t.print('😀'); // 0x1F600
    try t.resize(alloc, 2, 3);
    t.setCursorPos(1, 2);
    try t.print('😀'); // 0x1F600
}

// https://github.com/mitchellh/ghostty/issues/723
// This was found via fuzzing so its highly specific.
test "Terminal: resize with left and right margin set" {
    const alloc = testing.allocator;
    const cols = 70;
    const rows = 23;
    var t = try init(alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.enable_left_and_right_margin, true);
    try t.print('0');
    t.modes.set(.enable_mode_3, true);
    try t.resize(alloc, cols, rows);
    t.setLeftAndRightMargin(2, 0);
    try t.printRepeat(1850);
    _ = t.modes.restore(.enable_mode_3);
    try t.resize(alloc, cols, rows);
}

// https://github.com/mitchellh/ghostty/issues/1343
test "Terminal: resize with wraparound off" {
    const alloc = testing.allocator;
    const cols = 4;
    const rows = 2;
    var t = try init(alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, false);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, new_cols, rows);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01", str);
}

test "Terminal: resize with wraparound on" {
    const alloc = testing.allocator;
    const cols = 4;
    const rows = 2;
    var t = try init(alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    try t.print('0');
    try t.print('1');
    try t.print('2');
    try t.print('3');
    const new_cols = 2;
    try t.resize(alloc, new_cols, rows);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("01\n23", str);
}

test "Terminal: resize with high unique style per cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    for (0..t.rows) |y| {
        for (0..t.cols) |x| {
            t.setCursorPos(y, x);
            try t.setAttribute(.{ .direct_color_bg = .{
                .r = @intCast(x),
                .g = @intCast(y),
                .b = 0,
            } });
            try t.print('x');
        }
    }

    try t.resize(alloc, 60, 30);
}

test "Terminal: resize with high unique style per cell with wrapping" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 30, .rows = 30 });
    defer t.deinit(alloc);

    const cell_count: u16 = @intCast(t.rows * t.cols);
    for (0..cell_count) |i| {
        const r: u8 = @intCast(i >> 8);
        const g: u8 = @intCast(i & 0xFF);

        try t.setAttribute(.{ .direct_color_bg = .{
            .r = r,
            .g = g,
            .b = 0,
        } });
        try t.print('x');
    }

    try t.resize(alloc, 60, 30);
}

test "Terminal: resize with reflow and saved cursor" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    t.setCursorPos(2, 2);
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }

    t.saveCursor();
    try t.resize(alloc, 5, 3);
    t.restoreCursor();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }

    // Verify our cursor is still in the same place
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint);
    }
}

test "Terminal: resize with reflow and saved cursor pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .cols = 2, .rows = 3 });
    defer t.deinit(alloc);
    try t.printString("1A2B");
    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{
            .x = t.screens.active.cursor.x,
            .y = t.screens.active.cursor.y,
        } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u32, 'B'), cell.content.codepoint);
    }

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A\n2B", str);
    }

    t.saveCursor();
    try t.resize(alloc, 5, 3);
    t.restoreCursor();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2B", str);
    }

    // Pending wrap should be reset
    try t.print('X');
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A2BX", str);
    }
}

test "Terminal: DECCOLM without DEC mode 40" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.@"132_column", true);
    try t.deccolm(alloc, .@"132_cols");
    try testing.expectEqual(@as(usize, 5), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.modes.get(.@"132_column"));
}

test "Terminal: DECCOLM unset" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
}

test "Terminal: DECCOLM resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screens.active.cursor.pending_wrap);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.screens.active.cursor.pending_wrap);
}

test "Terminal: DECCOLM preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 0xFF,
        .g = 0,
        .b = 0,
    } });
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");

    {
        const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 0xFF,
            .g = 0,
            .b = 0,
        }, list_cell.cell.content.color_rgb);
    }
}

test "Terminal: DECCOLM resets scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 3);
    t.setLeftAndRightMargin(3, 5);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");

    try testing.expect(t.modes.get(.enable_left_and_right_margin));
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}

test "Terminal: mode 47 alt screen plain" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Go back to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should retain content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }
}

test "Terminal: mode 47 copies cursor both directions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Color our cursor red
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"47", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Verify that our style is set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }

    // Set a new style
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });

    // Go back to primary
    try t.switchScreenMode(.@"47", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Verify that our style is still set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}

test "Terminal: mode 1047 alt screen plain" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Go back to alt screen with mode 1047
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: mode 1047 copies cursor both directions" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Color our cursor red
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0xFF, .g = 0, .b = 0x7F } });

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1047", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Verify that our style is set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }

    // Set a new style
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 0, .g = 0xFF, .b = 0 } });

    // Go back to primary
    try t.switchScreenMode(.@"1047", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Verify that our style is still set
    {
        try testing.expect(t.screens.active.cursor.style_id != style.default_id);
        const page = &t.screens.active.cursor.page_pin.node.data;
        try testing.expectEqual(@as(usize, 1), page.styles.count());
        try testing.expect(page.styles.refCount(page.memory, t.screens.active.cursor.style_id) > 0);
    }
}

test "Terminal: mode 1049 alt screen plain" {
    const alloc = testing.allocator;
    var t = try init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Print on primary screen
    try t.printString("1A");

    // Go to alt screen with mode 47
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Print on alt screen. This should be off center because
    // we copy the cursor over from the primary screen
    try t.printString("2B");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  2B", str);
    }

    // Go back to primary
    try t.switchScreenMode(.@"1049", false);
    try testing.expectEqual(.primary, t.screens.active_key);

    // Primary screen should still have the original content
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1A", str);
    }

    // Write, our cursor should be restored back.
    try t.printString("C");
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("1AC", str);
    }

    // Go back to alt screen with mode 1049
    try t.switchScreenMode(.@"1049", true);
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Screen should be empty
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
