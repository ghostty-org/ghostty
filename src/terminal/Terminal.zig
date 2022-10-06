//! The primary terminal emulation structure. This represents a single
//!
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const utf8proc = @import("utf8proc");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const sgr = @import("sgr.zig");
const Selection = @import("Selection.zig");
const Tabstops = @import("Tabstops.zig");
const trace = @import("tracy").trace;
const color = @import("color.zig");
const Screen = @import("Screen.zig");

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// Screen type is an enum that tracks whether a screen is primary or alternate.
pub const ScreenType = enum {
    primary,
    alternate,
};

/// Screen is the current screen state. The "active_screen" field says what
/// the current screen is. The backup screen is the opposite of the active
/// screen.
active_screen: ScreenType,
screen: Screen,
secondary_screen: Screen,

/// The current selection (if any).
selection: ?Selection = null,

/// Whether we're currently writing to the status line (DECSASD and DECSSDT).
/// We don't support a status line currently so we just black hole this
/// data so that it doesn't mess up our main display.
status_display: ansi.StatusDisplay = .main,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: usize,
cols: usize,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The charset state
charset: CharsetState = .{},

/// Modes - This isn't exhaustive, since some modes (i.e. cursor origin)
/// are applied to the cursor and others aren't boolean yes/no.
modes: packed struct {
    const Self = @This();

    reverse_colors: bool = false, // 5,
    origin: bool = false, // 6
    autowrap: bool = true, // 7

    deccolm: bool = false, // 3,
    deccolm_supported: bool = false, // 40

    mouse_event: MouseEvents = .none,
    mouse_format: MouseFormat = .x10,

    test {
        // We have this here so that we explicitly fail when we change the
        // size of modes. The size of modes is NOT particularly important,
        // we just want to be mentally aware when it happens.
        try std.testing.expectEqual(2, @sizeOf(Self));
    }
} = .{},

/// State required for all charset operations.
const CharsetState = struct {
    /// The list of graphical charsets by slot
    charsets: CharsetArray = CharsetArray.initFill(charsets.Charset.utf8),

    /// GL is the slot to use when using a 7-bit printable char (up to 127)
    /// GR used for 8-bit printable chars.
    gl: charsets.Slots = .G0,
    gr: charsets.Slots = .G2,

    /// Single shift where a slot is used for exactly one char.
    single_shift: ?charsets.Slots = null,

    /// An array to map a charset slot to a lookup table.
    const CharsetArray = std.EnumArray(charsets.Slots, charsets.Charset);
};

/// The event types that can be reported for mouse-related activities.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseEvents = enum(u3) {
    none = 0,
    x10 = 1, // 9
    normal = 2, // 1000
    button = 3, // 1002
    any = 4, // 1003
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
/// occurs. Wen scrolling the screen, only this viewport is scrolled.
const ScrollingRegion = struct {
    // Top and bottom of the scroll region (0-indexed)
    // Precondition: top < bottom
    top: usize,
    bottom: usize,
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
        },
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screen.deinit();
    self.secondary_screen.deinit();
    self.* = undefined;
}

/// Options for switching to the alternate screen.
pub const AlternateScreenOptions = struct {
    cursor_save: bool = false,
    clear_on_enter: bool = false,
    clear_on_exit: bool = false,
};

/// Switch to the alternate screen buffer.
///
/// The alternate screen buffer:
///   * has its own grid
///   * has its own cursor state (included saved cursor)
///   * does not support scrollback
///
pub fn alternateScreen(self: *Terminal, options: AlternateScreenOptions) void {
    const tracy = trace(@src());
    defer tracy.end();

    //log.info("alt screen active={} options={} cursor={}", .{ self.active_screen, options, self.screen.cursor });

    // TODO: test
    // TODO(mitchellh): what happens if we enter alternate screen multiple times?
    // for now, we ignore...
    if (self.active_screen == .alternate) return;

    // If we requested cursor save, we save the cursor in the primary screen
    if (options.cursor_save) self.saveCursor();

    // Switch the screens
    const old = self.screen;
    self.screen = self.secondary_screen;
    self.secondary_screen = old;
    self.active_screen = .alternate;

    // Clear our selection
    self.selection = null;

    if (options.clear_on_enter) {
        self.eraseDisplay(.complete);
    }
}

/// Switch back to the primary screen (reset alternate screen mode).
pub fn primaryScreen(self: *Terminal, options: AlternateScreenOptions) void {
    const tracy = trace(@src());
    defer tracy.end();

    //log.info("primary screen active={} options={}", .{ self.active_screen, options });

    // TODO: test
    // TODO(mitchellh): what happens if we enter alternate screen multiple times?
    if (self.active_screen == .primary) return;

    if (options.clear_on_exit) self.eraseDisplay(.complete);

    // Switch the screens
    const old = self.screen;
    self.screen = self.secondary_screen;
    self.secondary_screen = old;
    self.active_screen = .primary;

    // Clear our selection
    self.selection = null;

    // Restore the cursor from the primary screen
    if (options.cursor_save) self.restoreCursor();
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
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: test

    // We need to support this. This corresponds to xterm's private mode 40
    // bit. If the mode "?40" is set, then "?3" (DECCOLM) is supported. This
    // doesn't exactly match VT100 semantics but modern terminals no longer
    // blindly accept mode 3 since its so weird in modern practice.
    if (!self.modes.deccolm_supported) return;

    // Enable it
    self.modes.deccolm = mode == .@"132_cols";

    // Resize -- we can set cols to 0 because deccolm will force it
    try self.resize(alloc, 0, self.rows);

    // TODO: do not clear screen flag mode
    self.eraseDisplay(.complete);
    self.setCursorPos(1, 1);

    // TODO: left/right margins
}

/// Allows or disallows deccolm.
pub fn setDeccolmSupported(self: *Terminal, v: bool) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.modes.deccolm_supported = v;
}

/// Resize the underlying terminal.
pub fn resize(self: *Terminal, alloc: Allocator, cols_req: usize, rows: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we have deccolm supported then we are fixed at either 80 or 132
    // columns depending on if mode 3 is set or not.
    // TODO: test
    const cols: usize = if (self.modes.deccolm_supported)
        @as(usize, if (self.modes.deccolm) 132 else 80)
    else
        cols_req;

    // Resize our tabstops
    // TODO: use resize, but it doesn't set new tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try Tabstops.init(alloc, cols, 8);
    }

    // If we're making the screen smaller, dealloc the unused items.
    if (self.active_screen == .primary) {
        try self.screen.resize(rows, cols);
        try self.secondary_screen.resizeWithoutReflow(rows, cols);
    } else {
        try self.screen.resizeWithoutReflow(rows, cols);
        try self.secondary_screen.resize(rows, cols);
    }

    // Set our size
    self.cols = cols;
    self.rows = rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = rows - 1,
    };
}

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screen.testString(alloc, .viewport);
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.screen.saved_cursor = self.screen.cursor;
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    self.screen.cursor = self.screen.saved_cursor;
}

/// TODO: test
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    const tracy = trace(@src());
    defer tracy.end();

    switch (attr) {
        .unset => {
            self.screen.cursor.pen.attrs.has_fg = false;
            self.screen.cursor.pen.attrs.has_bg = false;
            self.screen.cursor.pen.attrs = .{};
        },

        .bold => {
            self.screen.cursor.pen.attrs.bold = true;
        },

        .faint => {
            self.screen.cursor.pen.attrs.faint = true;
        },

        .underline => {
            self.screen.cursor.pen.attrs.underline = true;
        },

        .inverse => {
            self.screen.cursor.pen.attrs.inverse = true;
        },

        .reset_inverse => {
            self.screen.cursor.pen.attrs.inverse = false;
        },

        .strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = true;
        },

        .reset_strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .direct_color_bg => |rgb| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .@"8_fg" => |n| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = color.default[@enumToInt(n)];
        },

        .@"8_bg" => |n| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = color.default[@enumToInt(n)];
        },

        .reset_fg => self.screen.cursor.pen.attrs.has_fg = false,

        .reset_bg => self.screen.cursor.pen.attrs.has_bg = false,

        .@"8_bright_fg" => |n| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = color.default[@enumToInt(n)];
        },

        .@"8_bright_bg" => |n| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = color.default[@enumToInt(n)];
        },

        .@"256_fg" => |idx| {
            self.screen.cursor.pen.attrs.has_fg = true;
            self.screen.cursor.pen.fg = color.default[idx];
        },

        .@"256_bg" => |idx| {
            self.screen.cursor.pen.attrs.has_bg = true;
            self.screen.cursor.pen.bg = color.default[idx];
        },

        else => return error.InvalidAttribute,
    }
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.charset.charsets.set(slot, set);
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
        self.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.charset.gl = slot,
        .GR => self.charset.gr = slot,
    }
}

pub fn print(self: *Terminal, c: u21) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) return;

    // Get the previous cell so we can detect grapheme clusters. We only
    // do this if c is outside of Latin-1 because characters in the Latin-1
    // range cannot possibly be grapheme joiners. This helps keep non-graphemes
    // extremely fast and we take this much slower path for graphemes. No hate
    // on graphemes, I'd love to make them much faster, but I wanted to focus
    // on correctness first.
    //
    // NOTE: This is disabled because no shells handle this correctly. We'll
    // need to work with shells and other emulators to probably figure out
    // a way to support this. In the mean time, I'm going to keep all the
    // grapheme detection and keep it up to date so we're ready to go.
    if (false and c > 255 and self.screen.cursor.x > 0) {
        // TODO: test this!

        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
        const Prev = struct { cell: *Screen.Cell, x: usize };
        const prev: Prev = prev: {
            const x = self.screen.cursor.x - 1;
            const immediate = row.getCellPtr(x);
            if (!immediate.attrs.wide_spacer_tail) break :prev .{
                .cell = immediate,
                .x = x,
            };

            break :prev .{
                .cell = row.getCellPtr(x - 1),
                .x = x - 1,
            };
        };

        const grapheme_break = brk: {
            var state: i32 = 0;
            var cp1 = @intCast(u21, prev.cell.char);
            if (prev.cell.attrs.grapheme) {
                var it = row.codepointIterator(prev.x);
                while (it.next()) |cp2| {
                    assert(!utf8proc.graphemeBreakStateful(
                        cp1,
                        cp2,
                        &state,
                    ));

                    cp1 = cp2;
                }
            }

            break :brk utf8proc.graphemeBreakStateful(cp1, c, &state);
        };

        // If we can NOT break, this means that "c" is part of a grapheme
        // with the previous char.
        if (!grapheme_break) {
            log.debug("c={x} grapheme attach to x={}", .{ c, prev.x });
            try row.attachGrapheme(prev.x, c);
            return;
        }
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly.
    const width = utf8proc.charwidth(c);
    assert(width <= 2);

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        // Find our previous cell
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
        const prev: usize = prev: {
            const x = self.screen.cursor.x - 1;
            const immediate = row.getCellPtr(x);
            if (!immediate.attrs.wide_spacer_tail) break :prev x;
            break :prev x - 1;
        };

        try row.attachGrapheme(prev, c);
        return;
    }

    // If we're soft-wrapping, then handle that first.
    if (self.screen.cursor.pending_wrap and self.modes.autowrap)
        try self.printWrap();

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => _ = @call(.{ .modifier = .always_inline }, self.printCell, .{c}),

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screen.cursor.x == self.cols - 1) {
                const spacer_head = self.printCell(' ');
                spacer_head.attrs.wide_spacer_head = true;
                try self.printWrap();
            }

            const wide_cell = self.printCell(c);
            wide_cell.attrs.wide = true;

            // Write our spacer
            self.screen.cursor.x += 1;
            const spacer = self.printCell(' ');
            spacer.attrs.wide_spacer_tail = true;
        },

        else => unreachable,
    }

    // Move the cursor
    self.screen.cursor.x += 1;

    // If we're at the column limit, then we need to wrap the next time.
    // This is unlikely so we do the increment above and decrement here
    // if we need to rather than check once.
    if (self.screen.cursor.x == self.cols) {
        self.screen.cursor.x -= 1;
        self.screen.cursor.pending_wrap = true;
    }
}

fn printCell(self: *Terminal, unmapped_c: u21) *Screen.Cell {
    // const tracy = trace(@src());
    // defer tracy.end();

    const c = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.charset.single_shift) |key_once| blk: {
            self.charset.single_shift = null;
            break :blk key_once;
        } else self.charset.gl;
        const set = self.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) break :c unmapped_c;

        // Get our lookup table and map it
        const table = set.table();
        break :c @intCast(u21, table[@intCast(u8, unmapped_c)]);
    };

    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const cell = row.getCellPtr(self.screen.cursor.x);

    // If this cell is wide char then we need to clear it.
    // We ignore wide spacer HEADS because we can just write
    // single-width characters into that.
    if (cell.attrs.wide) {
        const x = self.screen.cursor.x + 1;
        assert(x < self.cols);

        const spacer_cell = row.getCellPtr(x);
        spacer_cell.attrs.wide_spacer_tail = false;

        if (self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    } else if (cell.attrs.wide_spacer_tail) {
        assert(self.screen.cursor.x > 0);
        const x = self.screen.cursor.x - 1;

        const wide_cell = row.getCellPtr(x);
        wide_cell.attrs.wide = false;

        if (self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.attrs.grapheme) row.clearGraphemes(self.screen.cursor.x);

    // Write
    cell.* = self.screen.cursor.pen;
    cell.char = @intCast(u32, c);
    return cell;
}

fn printWrap(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.setWrapped(true);

    // Move to the next line
    try self.index();
    self.screen.cursor.x = 0;
}

fn clearWideSpacerHead(self: *Terminal) void {
    // TODO: handle deleting wide char on row 0 of active
    assert(self.screen.cursor.y >= 1);
    const cell = self.screen.getCellPtr(
        .active,
        self.screen.cursor.y - 1,
        self.cols - 1,
    );
    cell.attrs.wide_spacer_head = false;
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Reset margins, also sets cursor to top-left
    self.setScrollingRegion(0, 0);

    // Fill with Es, does not move cursor. We reset fg/bg so we can just
    // optimize here by doing row copies.
    const filled = self.screen.getRow(.{ .active = 0 });
    filled.fill(.{ .char = 'E' });

    var row: usize = 1;
    while (row < self.rows) : (row += 1) {
        try self.screen.getRow(.{ .active = row }).copyRow(filled);
    }
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
    const tracy = trace(@src());
    defer tracy.end();

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Outside of the scroll region we move the cursor one line down.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom)
    {
        self.screen.cursor.y = @minimum(self.screen.cursor.y + 1, self.rows - 1);
        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (self.screen.cursor.y == self.scrolling_region.bottom) {
        // If our scrolling region is the full screen, we create scrollback.
        // Otherwise, we simply scroll the region.
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.bottom == self.rows - 1)
        {
            try self.screen.scroll(.{ .delta = 1 });
        } else {
            // TODO: test
            try self.scrollUp(1);
        }

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    self.screen.cursor.y = @minimum(self.screen.cursor.y + 1, self.scrolling_region.bottom);
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
pub fn reverseIndex(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: scrolling region

    if (self.screen.cursor.y == 0) {
        try self.scrollDown(1);
    } else {
        self.screen.cursor.y -|= 1;
    }
}

// Set Cursor Position. Move cursor to the position indicated
// by row and column (1-indexed). If column is 0, it is adjusted to 1.
// If column is greater than the right-most column it is adjusted to
// the right-most column. If row is 0, it is adjusted to 1. If row is
// greater than the bottom-most row it is adjusted to the bottom-most
// row.
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: usize = 0,
        y_offset: usize = 0,
        x_max: usize,
        y_max: usize,
    } = if (self.modes.origin) .{
        .x_offset = 0, // TODO: left/right margins
        .y_offset = self.scrolling_region.top,
        .x_max = self.cols, // TODO: left/right margins
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    self.screen.cursor.x = @minimum(params.x_max, col) -| 1;
    self.screen.cursor.y = @minimum(params.y_max, row + params.y_offset) -| 1;
    // log.info("set cursor position: col={} row={}", .{ self.screen.cursor.x, self.screen.cursor.y });

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;
}

/// Move the cursor to column `col_req` (1-indexed) without modifying the row.
/// If `col_req` is 0, it is changed to 1. If `col_req` is greater than the
/// total number of columns, it is set to the right-most column.
///
/// If cursor origin mode is set, the cursor row will be set inside the
/// current scroll region.
pub fn setCursorColAbsolute(self: *Terminal, col_req: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: test

    assert(!self.modes.origin); // TODO

    if (self.status_display != .main) return; // TODO

    const col = if (col_req == 0) 1 else col_req;
    self.screen.cursor.x = @minimum(self.cols, col) - 1;
}

/// Erase the display.
/// TODO: test
pub fn eraseDisplay(
    self: *Terminal,
    mode: csi.EraseDisplay,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    switch (mode) {
        .complete => {
            var it = self.screen.rowIterator(.active);
            while (it.next()) |row| row.clear(self.screen.cursor.pen);

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .below => {
            // All lines to the right (including the cursor)
            var x: usize = self.screen.cursor.x;
            while (x < self.cols) : (x += 1) {
                const cell = self.screen.getCellPtr(.active, self.screen.cursor.y, x);
                cell.* = self.screen.cursor.pen;
                cell.char = 0;
            }

            // All lines below
            var y: usize = self.screen.cursor.y + 1;
            while (y < self.rows) : (y += 1) {
                x = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = self.screen.getCellPtr(.active, y, x);
                    cell.* = self.screen.cursor.pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .above => {
            // Erase to the left (including the cursor)
            var x: usize = 0;
            while (x <= self.screen.cursor.x) : (x += 1) {
                const cell = self.screen.getCellPtr(.active, self.screen.cursor.y, x);
                cell.* = self.screen.cursor.pen;
                cell.char = 0;
            }

            // All lines above
            var y: usize = 0;
            while (y < self.screen.cursor.y) : (y += 1) {
                x = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = self.screen.getCellPtr(.active, y, x);
                    cell.* = self.screen.cursor.pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .scrollback => self.screen.clearHistory(),
    }
}

/// Erase the line.
/// TODO: test
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
) void {
    const tracy = trace(@src());
    defer tracy.end();

    switch (mode) {
        .right => {
            const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
            row.fillSlice(self.screen.cursor.pen, self.screen.cursor.x, self.cols);
        },

        .left => {
            const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
            row.fillSlice(self.screen.cursor.pen, 0, self.screen.cursor.x + 1);

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .complete => {
            const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
            row.fill(self.screen.cursor.pen);
        },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            @panic("unimplemented");
        },
    }
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
///
/// TODO: test
pub fn deleteChars(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const line = self.screen.getRow(.{ .active = self.screen.cursor.y });

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const end = self.cols - count;

    // Shift
    var i: usize = self.screen.cursor.x;
    while (i < end) : (i += 1) {
        const j = i + count;
        const j_cell = line.getCellPtr(j);
        line.getCellPtr(i).* = j_cell.*;
        j_cell.char = 0;
    }
}

// TODO: test, docs
pub fn eraseChars(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const end = @minimum(self.cols, self.screen.cursor.x + count);

    // Shift
    var pen = self.screen.cursor.pen;
    pen.char = 0;
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.fillSlice(pen, self.screen.cursor.x, end);
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
/// TODO: test
pub fn cursorLeft(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: scroll region, wrap

    self.screen.cursor.x -|= if (count == 0) 1 else count;
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
/// TODO: test
pub fn cursorRight(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.screen.cursor.x += if (count == 0) 1 else count;
    self.screen.cursor.pending_wrap = false;
    if (self.screen.cursor.x >= self.cols) {
        self.screen.cursor.x = self.cols - 1;
    }
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
// TODO: test
pub fn cursorDown(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.screen.cursor.y += if (count == 0) 1 else count;
    if (self.screen.cursor.y >= self.rows) {
        self.screen.cursor.y = self.rows - 1;
    }
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
// TODO: test
pub fn cursorUp(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.screen.cursor.y -|= if (count == 0) 1 else count;
    self.screen.cursor.pending_wrap = false;
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    self.cursorLeft(1);
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    while (self.screen.cursor.x < self.cols - 1) {
        // Move the cursor right
        self.screen.cursor.x += 1;

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screen.cursor.x)) return;
    }
}

/// Clear tab stops.
/// TODO: test
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

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: left/right margin mode
    // TODO: origin mode

    self.screen.cursor.x = 0;
    self.screen.cursor.pending_wrap = false;
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.index();
}

/// Inserts spaces at current cursor position moving existing cell contents
/// to the right. The contents of the count right-most columns in the scroll
/// region are lost. The cursor position is not changed.
///
/// This unsets the pending wrap state without wrapping.
///
/// The inserted cells are colored according to the current SGR state.
pub fn insertBlanks(self: *Terminal, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Unset pending wrap state without wrapping
    self.screen.cursor.pending_wrap = false;

    // If our count is larger than the remaining amount, we just erase right.
    if (count > self.cols - self.screen.cursor.x) {
        self.eraseLine(.right);
        return;
    }

    // Get the current row
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });

    // Determine our indexes.
    const start = self.screen.cursor.x;
    const pivot = self.screen.cursor.x + count;

    // This is the number of spaces we have left to shift existing data.
    // If count is bigger than the available space left after the cursor,
    // we may have no space at all for copying.
    const copyable = self.screen.cols - pivot;
    if (copyable > 0) {
        // This is the index of the final copyable value that we need to copy.
        const copyable_end = start + copyable - 1;

        // Shift count cells. We have to do this backwards since we're not
        // allocated new space, otherwise we'll copy duplicates.
        var i: usize = 0;
        while (i < copyable) : (i += 1) {
            const to = self.screen.cols - 1 - i;
            const from = copyable_end - i;
            row.getCellPtr(to).* = row.getCell(from);
        }
    }

    // Insert zero
    var pen = self.screen.cursor.pen;
    pen.char = ' '; // NOTE: this should be 0 but we need space for tests
    row.fillSlice(pen, start, pivot);
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
pub fn insertLines(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Move the cursor to the left margin
    self.screen.cursor.x = 0;

    // Remaining rows from our cursor
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // If count is greater than the amount of rows, adjust down.
    const adjusted_count = @minimum(count, rem);

    // The the top `scroll_amount` lines need to move to the bottom
    // scroll area. We may have nothing to scroll if we're clearing.
    const scroll_amount = rem - adjusted_count;
    var y: usize = self.scrolling_region.bottom;
    const top = y - scroll_amount;

    // Ensure we have the lines populated to the end
    while (y > top) : (y -= 1) {
        try self.screen.copyRow(.{ .active = y }, .{ .active = y - adjusted_count });
    }

    // Insert count blank lines
    y = self.screen.cursor.y;
    while (y < self.screen.cursor.y + adjusted_count) : (y += 1) {
        const row = self.screen.getRow(.{ .active = y });
        row.clear(self.screen.cursor.pen);
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
pub fn deleteLines(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: scroll region bounds

    // Move the cursor to the left margin
    self.screen.cursor.x = 0;

    // Remaining number of lines in the scrolling region
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // If the count is more than our remaining lines, we adjust down.
    const adjusted_count = @minimum(count, rem);

    // Scroll up the count amount.
    var y: usize = self.screen.cursor.y;
    while (y <= self.scrolling_region.bottom - adjusted_count) : (y += 1) {
        try self.screen.copyRow(.{ .active = y }, .{ .active = y + adjusted_count });
    }

    while (y <= self.scrolling_region.bottom) : (y += 1) {
        const row = self.screen.getRow(.{ .active = y });
        row.fill(self.screen.cursor.pen);
    }
}

/// Scroll the text down by one row.
/// TODO: test
pub fn scrollDown(self: *Terminal, count: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Preserve the cursor
    const cursor = self.screen.cursor;
    defer self.screen.cursor = cursor;

    // Move to the top of the scroll region
    self.screen.cursor.y = self.scrolling_region.top;
    try self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
// TODO: test
pub fn scrollUp(self: *Terminal, count: usize) !void {
    // Preserve the cursor
    const cursor = self.screen.cursor;
    defer self.screen.cursor = cursor;

    // Move to the top of the scroll region
    self.screen.cursor.y = self.scrolling_region.top;
    try self.deleteLines(count);
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(enum) {
    /// Scroll to the top of the scrollback
    top: void,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom: void,

    delta: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) !void {
    const tracy = trace(@src());
    defer tracy.end();

    try self.screen.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .bottom = {} },
        .delta => |delta| .{ .delta_no_grow = delta },
    });
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
pub fn setScrollingRegion(self: *Terminal, top: usize, bottom: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    var t = if (top == 0) 1 else top;
    var b = @minimum(bottom, self.rows);
    if (t >= b) {
        t = 1;
        b = self.rows;
    }

    self.scrolling_region = .{
        .top = t - 1,
        .bottom = b - 1,
    };

    self.setCursorPos(1, 1);
}

test "Terminal: input with no control characters" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
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
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hel\nlo", str);
    }
}

test "Terminal: print writes to bottom if scrolled" {
    var t = try init(testing.allocator, 5, 2);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);

    // Make newlines so we create scrollback
    // 3 pushes hello off the screen
    try t.index();
    try t.index();
    try t.index();
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to the top
    try t.scrollViewport(.{ .top = {} });
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    try t.scrollViewport(.{ .bottom = {} });
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: print charset" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.configureCharset(.G0, .utf8);
    try t.print('`');
    t.configureCharset(.G0, .ascii);
    try t.print('`');
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }
}

test "Terminal: print invoke charset" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, false);
    try t.print('`');
    try t.print('`');
    t.invokeCharset(.GL, .G0, false);
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}

test "Terminal: print invoke charset single" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.configureCharset(.G1, .dec_special);

    // Basic grid writing
    try t.print('`');
    t.invokeCharset(.GL, .G1, true);
    try t.print('`');
    try t.print('`');
    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
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
        var str = try t.plainString(testing.allocator);
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

test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screen.cursor.pending_wrap == false);
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
        var str = try t.plainString(testing.allocator);
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
    try testing.expectEqual(@as(usize, 7), t.screen.cursor.x);

    // HT
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 15), t.screen.cursor.x);

    // HT at the end
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 19), t.screen.cursor.x);
}

test "Terminal: setCursorPosition" {
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
    t.modes.origin = true;

    // No change without a scroll region
    t.setCursorPos(81, 81);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    // Set the scroll region
    t.setScrollingRegion(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    t.setScrollingRegion(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screen.cursor.y);
}

test "Terminal: setScrollingRegion" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Initial value
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Move our cusor so we can verify we move it back
    t.setCursorPos(5, 5);
    t.setScrollingRegion(3, 7);

    // Cursor should move back to top-left
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);

    // Scroll region is set
    try testing.expectEqual(@as(usize, 2), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 6), t.scrolling_region.bottom);

    // Scroll region invalid
    t.setScrollingRegion(7, 3);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);

    // Scroll region with zero top and bottom
    t.setScrollingRegion(0, 0);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, t.rows - 1), t.scrolling_region.bottom);
}

test "Terminal: deleteLines" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
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
    try t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

test "Terminal: deleteLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 80, 80);
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

    t.setScrollingRegion(1, 3);
    t.setCursorPos(1, 1);
    try t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

test "Terminal: insertLines" {
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
    try t.insertLines(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

test "Terminal: insertLines with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 6);
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

    t.setScrollingRegion(1, 2);
    t.setCursorPos(1, 1);
    try t.insertLines(1);

    try t.print('X');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
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
    try t.insertLines(20);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

test "Terminal: reverseIndex" {
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
    try t.reverseIndex();
    try t.print('D');
    t.carriageReturn();
    try t.linefeed();
    t.carriageReturn();
    try t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

test "Terminal: reverseIndex from the top" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
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
    try t.reverseIndex();
    try t.print('D');

    t.carriageReturn();
    try t.linefeed();
    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

test "Terminal: index" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try t.index();
    try t.print('A');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();

    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    t.setScrollingRegion(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
}

test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setScrollingRegion(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();
    try t.print('B');

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

test "Terminal: DECALN" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 2);
    defer t.deinit(alloc);

    // Initial value
    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    try t.print('B');
    try t.decaln();

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}

test "Terminal: insertBlanks" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

test "Terminal: insertBlanks pushes off end" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

test "Terminal: insertBlanks more than size" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.setCursorPos(1, 1);
    t.insertBlanks(5);

    {
        var str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}
