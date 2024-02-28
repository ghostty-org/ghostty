//! The primary terminal emulation structure. This represents a single
//!
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const simd = @import("../simd/main.zig");
const unicode = @import("../unicode/main.zig");

const ansi = @import("ansi.zig");
const modes = @import("modes.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const color = @import("color.zig");
const Screen = @import("Screen.zig");
const mouse_shape = @import("mouse_shape.zig");

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
pub fn alternateScreen(
    self: *Terminal,
    alloc: Allocator,
    options: AlternateScreenOptions,
) void {
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

    // Bring our pen with us
    self.screen.cursor = old.cursor;

    // Bring our charset state with us
    self.screen.charset = old.charset;

    // Clear our selection
    self.screen.selection = null;

    // Mark kitty images as dirty so they redraw
    self.screen.kitty_images.dirty = true;

    if (options.clear_on_enter) {
        self.eraseDisplay(alloc, .complete, false);
    }
}

/// Switch back to the primary screen (reset alternate screen mode).
pub fn primaryScreen(
    self: *Terminal,
    alloc: Allocator,
    options: AlternateScreenOptions,
) void {
    //log.info("primary screen active={} options={}", .{ self.active_screen, options });

    // TODO: test
    // TODO(mitchellh): what happens if we enter alternate screen multiple times?
    if (self.active_screen == .primary) return;

    if (options.clear_on_exit) self.eraseDisplay(alloc, .complete, false);

    // Switch the screens
    const old = self.screen;
    self.screen = self.secondary_screen;
    self.secondary_screen = old;
    self.active_screen = .primary;

    // Clear our selection
    self.screen.selection = null;

    // Mark kitty images as dirty so they redraw
    self.screen.kitty_images.dirty = true;

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
    self.eraseDisplay(alloc, .complete, false);
    self.setCursorPos(1, 1);
}

/// Resize the underlying terminal.
pub fn resize(self: *Terminal, alloc: Allocator, cols: usize, rows: usize) !void {
    // If our cols/rows didn't change then we're done
    if (self.cols == cols and self.rows == rows) return;

    // Resize our tabstops
    // TODO: use resize, but it doesn't set new tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try Tabstops.init(alloc, cols, 8);
    }

    // If we're making the screen smaller, dealloc the unused items.
    if (self.active_screen == .primary) {
        self.clearPromptForResize();
        if (self.modes.get(.wraparound)) {
            try self.screen.resize(rows, cols);
        } else {
            try self.screen.resizeWithoutReflow(rows, cols);
        }
        try self.secondary_screen.resizeWithoutReflow(rows, cols);
    } else {
        try self.screen.resizeWithoutReflow(rows, cols);
        if (self.modes.get(.wraparound)) {
            try self.secondary_screen.resize(rows, cols);
        } else {
            try self.secondary_screen.resizeWithoutReflow(rows, cols);
        }
    }

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

/// If shell_redraws_prompt is true and we're on the primary screen,
/// then this will clear the screen from the cursor down if the cursor is
/// on a prompt in order to allow the shell to redraw the prompt.
fn clearPromptForResize(self: *Terminal) void {
    assert(self.active_screen == .primary);

    if (!self.flags.shell_redraws_prompt) return;

    // We need to find the first y that is a prompt. If we find any line
    // that is NOT a prompt (or input -- which is part of a prompt) then
    // we are not at a prompt and we can exit this function.
    const prompt_y: usize = prompt_y: {
        // Keep track of the found value, because we want to find the START
        var found: ?usize = null;

        // Search from the cursor up
        var y: usize = 0;
        while (y <= self.screen.cursor.y) : (y += 1) {
            const real_y = self.screen.cursor.y - y;
            const row = self.screen.getRow(.{ .active = real_y });
            switch (row.getSemanticPrompt()) {
                // We are at a prompt but we're not at the start of the prompt.
                // We mark our found value and continue because the prompt
                // may be multi-line.
                .input => found = real_y,

                // If we find the prompt then we're done. We are also done
                // if we find any prompt continuation, because the shells
                // that send this currently (zsh) cannot redraw every line.
                .prompt, .prompt_continuation => {
                    found = real_y;
                    break;
                },

                // If we have command output, then we're most certainly not
                // at a prompt. Break out of the loop.
                .command => break,

                // If we don't know, we keep searching.
                .unknown => {},
            }
        }

        if (found) |found_y| break :prompt_y found_y;
        return;
    };
    assert(prompt_y < self.rows);

    // We want to clear all the lines from prompt_y downwards because
    // the shell will redraw the prompt.
    for (prompt_y..self.rows) |y| {
        const row = self.screen.getRow(.{ .active = y });
        row.setWrapped(false);
        row.setDirty(true);
        row.clear(.{});
    }
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
    self.screen.saved_cursor = .{
        .x = self.screen.cursor.x,
        .y = self.screen.cursor.y,
        .pen = self.screen.cursor.pen,
        .pending_wrap = self.screen.cursor.pending_wrap,
        .origin = self.modes.get(.origin),
        .charset = self.screen.charset,
    };
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    const saved: Screen.Cursor.Saved = self.screen.saved_cursor orelse .{
        .x = 0,
        .y = 0,
        .pen = .{},
        .pending_wrap = false,
        .origin = false,
        .charset = .{},
    };

    self.screen.cursor.pen = saved.pen;
    self.screen.charset = saved.charset;
    self.modes.set(.origin, saved.origin);
    self.screen.cursor.x = @min(saved.x, self.cols - 1);
    self.screen.cursor.y = @min(saved.y, self.rows - 1);
    self.screen.cursor.pending_wrap = saved.pending_wrap;
}

/// TODO: test
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    switch (attr) {
        .unset => {
            self.screen.cursor.pen.fg = .none;
            self.screen.cursor.pen.bg = .none;
            self.screen.cursor.pen.attrs = .{};
        },

        .bold => {
            self.screen.cursor.pen.attrs.bold = true;
        },

        .reset_bold => {
            // Bold and faint share the same SGR code for this
            self.screen.cursor.pen.attrs.bold = false;
            self.screen.cursor.pen.attrs.faint = false;
        },

        .italic => {
            self.screen.cursor.pen.attrs.italic = true;
        },

        .reset_italic => {
            self.screen.cursor.pen.attrs.italic = false;
        },

        .faint => {
            self.screen.cursor.pen.attrs.faint = true;
        },

        .underline => |v| {
            self.screen.cursor.pen.attrs.underline = v;
        },

        .reset_underline => {
            self.screen.cursor.pen.attrs.underline = .none;
        },

        .underline_color => |rgb| {
            self.screen.cursor.pen.attrs.underline_color = true;
            self.screen.cursor.pen.underline_fg = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            };
        },

        .@"256_underline_color" => |idx| {
            self.screen.cursor.pen.attrs.underline_color = true;
            self.screen.cursor.pen.underline_fg = self.color_palette.colors[idx];
        },

        .reset_underline_color => {
            self.screen.cursor.pen.attrs.underline_color = false;
        },

        .blink => {
            log.warn("blink requested, but not implemented", .{});
            self.screen.cursor.pen.attrs.blink = true;
        },

        .reset_blink => {
            self.screen.cursor.pen.attrs.blink = false;
        },

        .inverse => {
            self.screen.cursor.pen.attrs.inverse = true;
        },

        .reset_inverse => {
            self.screen.cursor.pen.attrs.inverse = false;
        },

        .invisible => {
            self.screen.cursor.pen.attrs.invisible = true;
        },

        .reset_invisible => {
            self.screen.cursor.pen.attrs.invisible = false;
        },

        .strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = true;
        },

        .reset_strikethrough => {
            self.screen.cursor.pen.attrs.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.screen.cursor.pen.fg = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .direct_color_bg => |rgb| {
            self.screen.cursor.pen.bg = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .@"8_fg" => |n| {
            self.screen.cursor.pen.fg = .{ .indexed = @intFromEnum(n) };
        },

        .@"8_bg" => |n| {
            self.screen.cursor.pen.bg = .{ .indexed = @intFromEnum(n) };
        },

        .reset_fg => self.screen.cursor.pen.fg = .none,

        .reset_bg => self.screen.cursor.pen.bg = .none,

        .@"8_bright_fg" => |n| {
            self.screen.cursor.pen.fg = .{ .indexed = @intFromEnum(n) };
        },

        .@"8_bright_bg" => |n| {
            self.screen.cursor.pen.bg = .{ .indexed = @intFromEnum(n) };
        },

        .@"256_fg" => |idx| {
            self.screen.cursor.pen.fg = .{ .indexed = idx };
        },

        .@"256_bg" => |idx| {
            self.screen.cursor.pen.bg = .{ .indexed = idx };
        },

        .unknown => return error.InvalidAttribute,
    }
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

    const pen = self.screen.cursor.pen;
    var attrs = [_]u8{0} ** 8;
    var i: usize = 0;

    if (pen.attrs.bold) {
        attrs[i] = '1';
        i += 1;
    }

    if (pen.attrs.faint) {
        attrs[i] = '2';
        i += 1;
    }

    if (pen.attrs.italic) {
        attrs[i] = '3';
        i += 1;
    }

    if (pen.attrs.underline != .none) {
        attrs[i] = '4';
        i += 1;
    }

    if (pen.attrs.blink) {
        attrs[i] = '5';
        i += 1;
    }

    if (pen.attrs.inverse) {
        attrs[i] = '7';
        i += 1;
    }

    if (pen.attrs.invisible) {
        attrs[i] = '8';
        i += 1;
    }

    if (pen.attrs.strikethrough) {
        attrs[i] = '9';
        i += 1;
    }

    for (attrs[0..i]) |c| {
        try writer.print(";{c}", .{c});
    }

    switch (pen.fg) {
        .none => {},
        .indexed => |idx| if (idx >= 16)
            try writer.print(";38:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";9{}", .{idx - 8})
        else
            try writer.print(";3{}", .{idx}),
        .rgb => |rgb| try writer.print(";38:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    switch (pen.bg) {
        .none => {},
        .indexed => |idx| if (idx >= 16)
            try writer.print(";48:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";10{}", .{idx - 8})
        else
            try writer.print(";4{}", .{idx}),
        .rgb => |rgb| try writer.print(";48:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    return stream.getWritten();
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screen.charset.charsets.set(slot, set);
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
        self.screen.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.screen.charset.gl = slot,
        .GR => self.screen.charset.gr = slot,
    }
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
    if (c > 255 and self.modes.get(.grapheme_cluster) and self.screen.cursor.x > 0) grapheme: {
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });

        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme. Otherwise, we can stay in this cell.
        const Prev = struct { cell: *Screen.Cell, x: usize };
        const prev: Prev = prev: {
            const x = x: {
                // If we have wraparound, then we always use the prev col
                if (self.modes.get(.wraparound)) break :x self.screen.cursor.x - 1;

                // If we do not have wraparound, the logic is trickier. If
                // we're not on the last column, then we just use the previous
                // column. Otherwise, we need to check if there is text to
                // figure out if we're attaching to the prev or current.
                if (self.screen.cursor.x != right_limit - 1) break :x self.screen.cursor.x - 1;
                const current = row.getCellPtr(self.screen.cursor.x);
                break :x self.screen.cursor.x - @intFromBool(current.char == 0);
            };
            const immediate = row.getCellPtr(x);

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            if (!immediate.attrs.wide_spacer_tail) break :prev .{
                .cell = immediate,
                .x = x,
            };

            break :prev .{
                .cell = row.getCellPtr(x - 1),
                .x = x - 1,
            };
        };

        // If our cell has no content, then this is a new cell and
        // necessarily a grapheme break.
        if (prev.cell.char == 0) break :grapheme;

        const grapheme_break = brk: {
            var state: unicode.GraphemeBreakState = .{};
            var cp1: u21 = @intCast(prev.cell.char);
            if (prev.cell.attrs.grapheme) {
                var it = row.codepointIterator(prev.x);
                while (it.next()) |cp2| {
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
                const prev_props = unicode.getProperties(@intCast(prev.cell.char));
                const emoji = prev_props.grapheme_boundary_class == .extended_pictographic;
                if (!emoji) return;

                switch (c) {
                    0xFE0F => wide: {
                        if (prev.cell.attrs.wide) break :wide;

                        // Move our cursor back to the previous. We'll move
                        // the cursor within this block to the proper location.
                        self.screen.cursor.x = prev.x;

                        // If we don't have space for the wide char, we need
                        // to insert spacers and wrap. Then we just print the wide
                        // char as normal.
                        if (prev.x == right_limit - 1) {
                            if (!self.modes.get(.wraparound)) return;
                            const spacer_head = self.printCell(' ');
                            spacer_head.attrs.wide_spacer_head = true;
                            try self.printWrap();
                        }

                        const wide_cell = self.printCell(@intCast(prev.cell.char));
                        wide_cell.attrs.wide = true;

                        // Write our spacer
                        self.screen.cursor.x += 1;
                        const spacer = self.printCell(' ');
                        spacer.attrs.wide_spacer_tail = true;

                        // Move the cursor again so we're beyond our spacer
                        self.screen.cursor.x += 1;
                        if (self.screen.cursor.x == right_limit) {
                            self.screen.cursor.x -= 1;
                            self.screen.cursor.pending_wrap = true;
                        }
                    },

                    0xFE0E => narrow: {
                        // Prev cell is no longer wide
                        if (!prev.cell.attrs.wide) break :narrow;
                        prev.cell.attrs.wide = false;

                        // Remove the wide spacer tail
                        const cell = row.getCellPtr(prev.x + 1);
                        cell.attrs.wide_spacer_tail = false;

                        break :narrow;
                    },

                    else => unreachable,
                }
            }

            log.debug("c={x} grapheme attach to x={}", .{ c, prev.x });
            try row.attachGrapheme(prev.x, c);
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
        const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
        const prev: usize = prev: {
            const x = self.screen.cursor.x - 1;
            const immediate = row.getCellPtr(x);
            if (!immediate.attrs.wide_spacer_tail) break :prev x;
            break :prev x - 1;
        };

        // If this is a emoji variation selector, prev must be an emoji
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_cell = row.getCellPtr(prev);
            const prev_props = unicode.getProperties(@intCast(prev_cell.char));
            const emoji = prev_props.grapheme_boundary_class == .extended_pictographic;
            if (!emoji) return;
        }

        try row.attachGrapheme(prev, c);
        return;
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screen.cursor.pending_wrap and self.modes.get(.wraparound))
        try self.printWrap();

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screen.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => _ = @call(.always_inline, printCell, .{ self, c }),

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
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We sould prevent this downstream.
            _ = self.printCell(' ');
        },

        else => unreachable,
    }

    // Move the cursor
    self.screen.cursor.x += 1;

    // If we're at the column limit, then we need to wrap the next time.
    // This is unlikely so we do the increment above and decrement here
    // if we need to rather than check once.
    if (self.screen.cursor.x == right_limit) {
        self.screen.cursor.x -= 1;
        self.screen.cursor.pending_wrap = true;
    }
}

fn printCell(self: *Terminal, unmapped_c: u21) *Screen.Cell {
    const c: u21 = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.screen.charset.single_shift) |key_once| blk: {
            self.screen.charset.single_shift = null;
            break :blk key_once;
        } else self.screen.charset.gl;
        const set = self.screen.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) break :c unmapped_c;

        // If we're outside of ASCII range this is an invalid value in
        // this table so we just return space.
        if (unmapped_c > std.math.maxInt(u8)) break :c ' ';

        // Get our lookup table and map it
        const table = set.table();
        break :c @intCast(table[@intCast(unmapped_c)]);
    };

    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const cell = row.getCellPtr(self.screen.cursor.x);

    // If this cell is wide char then we need to clear it.
    // We ignore wide spacer HEADS because we can just write
    // single-width characters into that.
    if (cell.attrs.wide) {
        const x = self.screen.cursor.x + 1;
        if (x < self.cols) {
            const spacer_cell = row.getCellPtr(x);
            spacer_cell.* = self.screen.cursor.pen;
        }

        if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    } else if (cell.attrs.wide_spacer_tail) {
        assert(self.screen.cursor.x > 0);
        const x = self.screen.cursor.x - 1;

        const wide_cell = row.getCellPtr(x);
        wide_cell.* = self.screen.cursor.pen;

        if (self.screen.cursor.y > 0 and self.screen.cursor.x <= 1) {
            self.clearWideSpacerHead();
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.attrs.grapheme) row.clearGraphemes(self.screen.cursor.x);

    // Write
    cell.* = self.screen.cursor.pen;
    cell.char = @intCast(c);
    return cell;
}

fn printWrap(self: *Terminal) !void {
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.setWrapped(true);

    // Get the old semantic prompt so we can extend it to the next
    // line. We need to do this before we index() because we may
    // modify memory.
    const old_prompt = row.getSemanticPrompt();

    // Move to the next line
    try self.index();
    self.screen.cursor.x = self.scrolling_region.left;

    // New line must inherit semantic prompt of the old line
    const new_row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    new_row.setSemanticPrompt(old_prompt);
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

/// Print the previous printed character a repeated amount of times.
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    if (self.previous_char) |c| {
        const count = @max(count_req, 1);
        for (0..count) |_| try self.print(c);
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
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

    // Clear our stylistic attributes
    self.screen.cursor.pen = .{
        .bg = self.screen.cursor.pen.bg,
        .fg = self.screen.cursor.pen.fg,
        .attrs = .{
            .protected = self.screen.cursor.pen.attrs.protected,
        },
    };

    // Our pen has the letter E
    const pen: Screen.Cell = .{ .char = 'E' };

    // Fill with Es, does not move cursor.
    for (0..self.rows) |y| {
        const filled = self.screen.getRow(.{ .active = y });
        filled.fill(pen);
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
    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Outside of the scroll region we move the cursor one line down.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom)
    {
        self.screen.cursor.y = @min(self.screen.cursor.y + 1, self.rows - 1);
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
            try self.screen.scroll(.{ .screen = 1 });
        } else {
            try self.scrollUp(1);
        }

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    self.screen.cursor.y = @min(self.screen.cursor.y + 1, self.scrolling_region.bottom);
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
    if (self.screen.cursor.y != self.scrolling_region.top or
        self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right)
    {
        self.cursorUp(1);
        return;
    }

    try self.scrollDown(1);
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
        x_offset: usize = 0,
        y_offset: usize = 0,
        x_max: usize,
        y_max: usize,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1, // We need this 1-indexed
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    self.screen.cursor.x = @min(params.x_max, col + params.x_offset) -| 1;
    self.screen.cursor.y = @min(params.y_max, row + params.y_offset) -| 1;
    // log.info("set cursor position: col={} row={}", .{ self.screen.cursor.x, self.screen.cursor.y });

    // Unset pending wrap state
    self.screen.cursor.pending_wrap = false;
}

/// Erase the display.
pub fn eraseDisplay(
    self: *Terminal,
    alloc: Allocator,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    // Erasing clears all attributes / colors _except_ the background
    const pen: Screen.Cell = switch (self.screen.cursor.pen.bg) {
        .none => .{},
        else => |bg| .{ .bg = bg },
    };

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screen.protected_mode == .iso or protected_req;

    switch (mode) {
        .scroll_complete => {
            self.screen.scroll(.{ .clear = {} }) catch |err| {
                log.warn("scroll clear failed, doing a normal clear err={}", .{err});
                self.eraseDisplay(alloc, .complete, protected_req);
                return;
            };

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;

            // Clear all Kitty graphics state for this screen
            self.screen.kitty_images.delete(alloc, self, .{ .all = true });
        },

        .complete => {
            // If we're on the primary screen and our last non-empty row is
            // a prompt, then we do a scroll_complete instead. This is a
            // heuristic to get the generally desirable behavior that ^L
            // at a prompt scrolls the screen contents prior to clearing.
            // Most shells send `ESC [ H ESC [ 2 J` so we can't just check
            // our current cursor position. See #905
            if (self.active_screen == .primary) at_prompt: {
                // Go from the bottom of the viewport up and see if we're
                // at a prompt.
                const viewport_max = Screen.RowIndexTag.viewport.maxLen(&self.screen);
                for (0..viewport_max) |y| {
                    const bottom_y = viewport_max - y - 1;
                    const row = self.screen.getRow(.{ .viewport = bottom_y });
                    if (row.isEmpty()) continue;
                    switch (row.getSemanticPrompt()) {
                        // If we're at a prompt or input area, then we are at a prompt.
                        .prompt,
                        .prompt_continuation,
                        .input,
                        => break,

                        // If we have command output, then we're most certainly not
                        // at a prompt.
                        .command => break :at_prompt,

                        // If we don't know, we keep searching.
                        .unknown => {},
                    }
                } else break :at_prompt;

                self.screen.scroll(.{ .clear = {} }) catch {
                    // If we fail, we just fall back to doing a normal clear
                    // so we don't worry about the error.
                };
            }

            var it = self.screen.rowIterator(.active);
            while (it.next()) |row| {
                row.setWrapped(false);
                row.setDirty(true);

                if (!protected) {
                    row.clear(pen);
                    continue;
                }

                // Protected mode erase
                for (0..row.lenCells()) |x| {
                    const cell = row.getCellPtr(x);
                    if (cell.attrs.protected) continue;
                    cell.* = pen;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;

            // Clear all Kitty graphics state for this screen
            self.screen.kitty_images.delete(alloc, self, .{ .all = true });
        },

        .below => {
            // All lines to the right (including the cursor)
            {
                self.eraseLine(.right, protected_req);
                const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
                row.setWrapped(false);
                row.setDirty(true);
            }

            // All lines below
            for ((self.screen.cursor.y + 1)..self.rows) |y| {
                const row = self.screen.getRow(.{ .active = y });
                row.setWrapped(false);
                row.setDirty(true);
                for (0..self.cols) |x| {
                    if (row.header().flags.grapheme) row.clearGraphemes(x);
                    const cell = row.getCellPtr(x);
                    if (protected and cell.attrs.protected) continue;
                    cell.* = pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .above => {
            // Erase to the left (including the cursor)
            self.eraseLine(.left, protected_req);

            // All lines above
            var y: usize = 0;
            while (y < self.screen.cursor.y) : (y += 1) {
                var x: usize = 0;
                while (x < self.cols) : (x += 1) {
                    const cell = self.screen.getCellPtr(.active, y, x);
                    if (protected and cell.attrs.protected) continue;
                    cell.* = pen;
                    cell.char = 0;
                }
            }

            // Unsets pending wrap state
            self.screen.cursor.pending_wrap = false;
        },

        .scrollback => self.screen.clear(.history) catch |err| {
            // This isn't a huge issue, so just log it.
            log.err("failed to clear scrollback: {}", .{err});
        },
    }
}

/// Erase the line.
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    // We always fill with the background
    const pen: Screen.Cell = switch (self.screen.cursor.pen.bg) {
        .none => .{},
        else => |bg| .{ .bg = bg },
    };

    // Get our start/end positions depending on mode.
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screen.cursor.x;

            // If our X is a wide spacer tail then we need to erase the
            // previous cell too so we don't split a multi-cell character.
            if (x > 0) {
                const cell = row.getCellPtr(x);
                if (cell.attrs.wide_spacer_tail) x -= 1;
            }

            // This resets the soft-wrap of this line
            row.setWrapped(false);

            break :right .{ x, row.lenCells() };
        },

        .left => left: {
            var x = self.screen.cursor.x;

            // If our x is a wide char we need to delete the tail too.
            const cell = row.getCellPtr(x);
            if (cell.attrs.wide) {
                if (row.getCellPtr(x + 1).attrs.wide_spacer_tail) {
                    x += 1;
                }
            }

            break :left .{ 0, x + 1 };
        },

        // Note that it seems like complete should reset the soft-wrap
        // state of the line but in xterm it does not.
        .complete => .{ 0, row.lenCells() },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };

    // All modes will clear the pending wrap state and we know we have
    // a valid mode at this point.
    self.screen.cursor.pending_wrap = false;

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screen.protected_mode == .iso or protected_req;

    // If we're not respecting protected attributes, we can use a fast-path
    // to fill the entire line.
    if (!protected) {
        row.fillSlice(self.screen.cursor.pen, start, end);
        return;
    }

    for (start..end) |x| {
        const cell = row.getCellPtr(x);
        if (cell.attrs.protected) continue;
        cell.* = pen;
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
pub fn deleteChars(self: *Terminal, count: usize) !void {
    if (count == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // This resets the pending wrap state
    self.screen.cursor.pending_wrap = false;

    const pen: Screen.Cell = .{
        .bg = self.screen.cursor.pen.bg,
    };

    // If our X is a wide spacer tail then we need to erase the
    // previous cell too so we don't split a multi-cell character.
    const line = self.screen.getRow(.{ .active = self.screen.cursor.y });
    if (self.screen.cursor.x > 0) {
        const cell = line.getCellPtr(self.screen.cursor.x);
        if (cell.attrs.wide_spacer_tail) {
            line.getCellPtr(self.screen.cursor.x - 1).* = pen;
        }
    }

    // We go from our cursor right to the end and either copy the cell
    // "count" away or clear it.
    for (self.screen.cursor.x..self.scrolling_region.right + 1) |x| {
        const copy_x = x + count;
        if (copy_x >= self.scrolling_region.right + 1) {
            line.getCellPtr(x).* = pen;
            continue;
        }

        const copy_cell = line.getCellPtr(copy_x);
        if (x == 0 and copy_cell.attrs.wide_spacer_tail) {
            line.getCellPtr(x).* = pen;
            continue;
        }
        line.getCellPtr(x).* = copy_cell.*;
        copy_cell.char = 0;
    }
}

pub fn eraseChars(self: *Terminal, count_req: usize) void {
    const count = @max(count_req, 1);

    // This resets the pending wrap state
    self.screen.cursor.pending_wrap = false;

    // Our last index is at most the end of the number of chars we have
    // in the current line.
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    const end = end: {
        var end = @min(self.cols, self.screen.cursor.x + count);

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != self.cols) {
            const last = row.getCellPtr(end - 1);
            if (last.attrs.wide) end += 1;
        }

        break :end end;
    };

    // This resets the soft-wrap of this line
    row.setWrapped(false);

    const pen: Screen.Cell = .{
        .bg = self.screen.cursor.pen.bg,
    };

    // If we never had a protection mode, then we can assume no cells
    // are protected and go with the fast path. If the last protection
    // mode was not ISO we also always ignore protection attributes.
    if (self.screen.protected_mode != .iso) {
        row.fillSlice(pen, self.screen.cursor.x, end);
    }

    // We had a protection mode at some point. We must go through each
    // cell and check its protection attribute.
    for (self.screen.cursor.x..end) |x| {
        const cell = row.getCellPtr(x);
        if (cell.attrs.protected) continue;
        cell.* = pen;
    }
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

    var count: usize = @max(count_req, 1);

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screen.cursor.x -|= count;
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
                self.screen.cursor.x = left_margin;
                self.screen.cursor.y = top;
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
        self.screen.cursor.x -= amount;

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screen.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screen.cursor.y = bottom;
            self.screen.cursor.x = right_margin;
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
            const row = self.screen.getRow(.{ .active = self.screen.cursor.y - 1 });
            if (!row.isWrapped()) break;
        }

        self.screen.cursor.y -= 1;
        self.screen.cursor.x = right_margin;
        count -= 1;
    }
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screen.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right
    else
        self.cols - 1;

    const count = @max(count_req, 1);
    self.screen.cursor.x = @min(max, self.screen.cursor.x +| count);
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screen.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom
    else
        self.rows - 1;

    const count = @max(count_req, 1);
    self.screen.cursor.y = @min(max, self.screen.cursor.y +| count);
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screen.cursor.pending_wrap = false;

    // The min the cursor can move to depends where the cursor currently is
    const min = if (self.screen.cursor.y >= self.scrolling_region.top)
        self.scrolling_region.top
    else
        0;

    const count = @max(count_req, 1);
    self.screen.cursor.y = @max(min, self.screen.cursor.y -| count);
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    self.cursorLeft(1);
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) !void {
    while (self.screen.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screen.cursor.x += 1;

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
        self.screen.cursor.x -= 1;
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

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    // Always reset pending wrap state
    self.screen.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screen.cursor.x = if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screen.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0;
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    try self.index();
    if (self.modes.get(.linefeed)) self.carriageReturn();
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
    self.screen.cursor.pending_wrap = false;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // The limit we can shift to is our right margin. We add 1 since the
    // math around this is 1-indexed.
    const right_limit = self.scrolling_region.right + 1;

    // If our count is larger than the remaining amount, we just erase right.
    // We only do this if we can erase the entire line (no right margin).
    if (right_limit == self.cols and
        count > right_limit - self.screen.cursor.x)
    {
        self.eraseLine(.right, false);
        return;
    }

    // Get the current row
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });

    // Determine our indexes.
    const start = self.screen.cursor.x;
    const pivot = @min(self.screen.cursor.x + count, right_limit);

    // This is the number of spaces we have left to shift existing data.
    // If count is bigger than the available space left after the cursor,
    // we may have no space at all for copying.
    const copyable = right_limit - pivot;
    if (copyable > 0) {
        // This is the index of the final copyable value that we need to copy.
        const copyable_end = start + copyable - 1;

        // If our last cell we're shifting is wide, then we need to clear
        // it to be empty so we don't split the multi-cell char.
        const cell = row.getCellPtr(copyable_end);
        if (cell.attrs.wide) cell.char = 0;

        // Shift count cells. We have to do this backwards since we're not
        // allocated new space, otherwise we'll copy duplicates.
        var i: usize = 0;
        while (i < copyable) : (i += 1) {
            const to = right_limit - 1 - i;
            const from = copyable_end - i;
            const src = row.getCell(from);
            const dst = row.getCellPtr(to);
            dst.* = src;
        }
    }

    // Insert blanks. The blanks preserve the background color.
    row.fillSlice(.{
        .bg = self.screen.cursor.pen.bg,
    }, start, pivot);
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
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom or
        self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // Move the cursor to the left margin
    self.screen.cursor.x = self.scrolling_region.left;
    self.screen.cursor.pending_wrap = false;

    // Remaining rows from our cursor
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // If count is greater than the amount of rows, adjust down.
    const adjusted_count = @min(count, rem);

    // The the top `scroll_amount` lines need to move to the bottom
    // scroll area. We may have nothing to scroll if we're clearing.
    const scroll_amount = rem - adjusted_count;
    var y: usize = self.scrolling_region.bottom;
    const top = y - scroll_amount;

    // Ensure we have the lines populated to the end
    while (y > top) : (y -= 1) {
        const src = self.screen.getRow(.{ .active = y - adjusted_count });
        const dst = self.screen.getRow(.{ .active = y });
        for (self.scrolling_region.left..self.scrolling_region.right + 1) |x| {
            try dst.copyCell(src, x);
        }
    }

    // Insert count blank lines
    y = self.screen.cursor.y;
    while (y < self.screen.cursor.y + adjusted_count) : (y += 1) {
        const row = self.screen.getRow(.{ .active = y });
        row.fillSlice(.{
            .bg = self.screen.cursor.pen.bg,
        }, self.scrolling_region.left, self.scrolling_region.right + 1);
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
    // If the cursor is outside the scroll region we do nothing.
    if (self.screen.cursor.y < self.scrolling_region.top or
        self.screen.cursor.y > self.scrolling_region.bottom or
        self.screen.cursor.x < self.scrolling_region.left or
        self.screen.cursor.x > self.scrolling_region.right) return;

    // Move the cursor to the left margin
    self.screen.cursor.x = self.scrolling_region.left;
    self.screen.cursor.pending_wrap = false;

    // If this is a full line margin then we can do a faster scroll.
    if (self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1)
    {
        self.screen.scrollRegionUp(
            .{ .active = self.screen.cursor.y },
            .{ .active = self.scrolling_region.bottom },
            @min(count, (self.scrolling_region.bottom - self.screen.cursor.y) + 1),
        );
        return;
    }

    // Left/right margin is set, we need to do a slower scroll.
    // Remaining rows from our cursor in the region, 1-indexed.
    const rem = self.scrolling_region.bottom - self.screen.cursor.y + 1;

    // If our count is greater than the remaining amount, we can just
    // clear the region using insertLines.
    if (count >= rem) {
        try self.insertLines(count);
        return;
    }

    // The amount of lines we need to scroll up.
    const scroll_amount = rem - count;
    const scroll_end_y = self.screen.cursor.y + scroll_amount;
    for (self.screen.cursor.y..scroll_end_y) |y| {
        const src = self.screen.getRow(.{ .active = y + count });
        const dst = self.screen.getRow(.{ .active = y });
        for (self.scrolling_region.left..self.scrolling_region.right + 1) |x| {
            try dst.copyCell(src, x);
        }
    }

    // Insert blank lines
    for (scroll_end_y..self.scrolling_region.bottom + 1) |y| {
        const row = self.screen.getRow(.{ .active = y });
        row.setWrapped(false);
        row.fillSlice(.{
            .bg = self.screen.cursor.pen.bg,
        }, self.scrolling_region.left, self.scrolling_region.right + 1);
    }
}

/// Scroll the text down by one row.
pub fn scrollDown(self: *Terminal, count: usize) !void {
    // Preserve the cursor
    const cursor = self.screen.cursor;
    defer self.screen.cursor = cursor;

    // Move to the top of the scroll region
    self.screen.cursor.y = self.scrolling_region.top;
    self.screen.cursor.x = self.scrolling_region.left;
    try self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
pub fn scrollUp(self: *Terminal, count: usize) !void {
    // Preserve the cursor
    const cursor = self.screen.cursor;
    defer self.screen.cursor = cursor;

    // Move to the top of the scroll region
    self.screen.cursor.y = self.scrolling_region.top;
    self.screen.cursor.x = self.scrolling_region.left;
    try self.deleteLines(count);
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(enum) {
    /// Scroll to the top of the scrollback
    top: void,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom: void,

    /// Scroll by some delta amount, up is negative.
    delta: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) !void {
    try self.screen.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .bottom = {} },
        .delta => |delta| .{ .viewport = delta },
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
pub fn setTopAndBottomMargin(self: *Terminal, top_req: usize, bottom_req: usize) void {
    const top = @max(1, top_req);
    const bottom = @min(self.rows, if (bottom_req == 0) self.rows else bottom_req);
    if (top >= bottom) return;

    self.scrolling_region.top = top - 1;
    self.scrolling_region.bottom = bottom - 1;
    self.setCursorPos(1, 1);
}

/// DECSLRM
pub fn setLeftAndRightMargin(self: *Terminal, left_req: usize, right_req: usize) void {
    // We must have this mode enabled to do anything
    if (!self.modes.get(.enable_left_and_right_margin)) return;

    const left = @max(1, left_req);
    const right = @min(self.cols, if (right_req == 0) self.cols else right_req);
    if (left >= right) return;

    self.scrolling_region.left = left - 1;
    self.scrolling_region.right = right - 1;
    self.setCursorPos(1, 1);
}

/// Mark the current semantic prompt information. Current escape sequences
/// (OSC 133) only allow setting this for wherever the current active cursor
/// is located.
pub fn markSemanticPrompt(self: *Terminal, p: SemanticPrompt) void {
    //log.debug("semantic_prompt y={} p={}", .{ self.screen.cursor.y, p });
    const row = self.screen.getRow(.{ .active = self.screen.cursor.y });
    row.setSemanticPrompt(switch (p) {
        .prompt => .prompt,
        .prompt_continuation => .prompt_continuation,
        .input => .input,
        .command => .command,
    });
}

/// Returns true if the cursor is currently at a prompt. Another way to look
/// at this is it returns false if the shell is currently outputting something.
/// This requires shell integration (semantic prompt integration).
///
/// If the shell integration doesn't exist, this will always return false.
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    // If we're on the secondary screen, we're never at a prompt.
    if (self.active_screen == .alternate) return false;

    var y: usize = 0;
    while (y <= self.screen.cursor.y) : (y += 1) {
        // We want to go bottom up
        const bottom_y = self.screen.cursor.y - y;
        const row = self.screen.getRow(.{ .active = bottom_y });
        switch (row.getSemanticPrompt()) {
            // If we're at a prompt or input area, then we are at a prompt.
            .prompt,
            .prompt_continuation,
            .input,
            => return true,

            // If we have command output, then we're most certainly not
            // at a prompt.
            .command => return false,

            // If we don't know, we keep searching.
            .unknown => {},
        }
    }

    return false;
}

/// Set the pwd for the terminal.
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    self.pwd.clearRetainingCapacity();
    try self.pwd.appendSlice(pwd);
}

/// Returns the pwd for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setPwd.
pub fn getPwd(self: *const Terminal) ?[]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items;
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

/// Set the character protection mode for the terminal.
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screen.cursor.pen.attrs.protected = false;

            // screen.protected_mode is NEVER reset to ".off" because
            // logic such as eraseChars depends on knowing what the
            // _most recent_ mode was.
        },

        .iso => {
            self.screen.cursor.pen.attrs.protected = true;
            self.screen.protected_mode = .iso;
        },

        .dec => {
            self.screen.cursor.pen.attrs.protected = true;
            self.screen.protected_mode = .dec;
        },
    }
}

/// Full reset
pub fn fullReset(self: *Terminal, alloc: Allocator) void {
    self.primaryScreen(alloc, .{ .clear_on_exit = true, .cursor_save = true });
    self.screen.charset = .{};
    self.modes = .{};
    self.flags = .{};
    self.tabstops.reset(TABSTOP_INTERVAL);
    self.screen.cursor = .{};
    self.screen.saved_cursor = null;
    self.screen.selection = null;
    self.screen.kitty_keyboard = .{};
    self.screen.protected_mode = .off;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };
    self.previous_char = null;
    self.eraseDisplay(alloc, .scrollback, false);
    self.eraseDisplay(alloc, .complete, false);
    self.pwd.clearRetainingCapacity();
    self.status_display = .main;
}

test "Terminal: fullReset with a non-empty pen" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.pen.bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x7F } };
    t.screen.cursor.pen.fg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x7F } };
    t.fullReset(testing.allocator);

    const cell = t.screen.getCell(.active, t.screen.cursor.y, t.screen.cursor.x);
    try testing.expect(cell.bg == .none);
    try testing.expect(cell.fg == .none);
}

test "Terminal: fullReset origin mode" {
    var t = try init(testing.allocator, 10, 10);
    defer t.deinit(testing.allocator);

    t.setCursorPos(3, 5);
    t.modes.set(.origin, true);
    t.fullReset(testing.allocator);

    // Origin mode should be reset and the cursor should be moved
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expect(!t.modes.get(.origin));
}

test "Terminal: fullReset status display" {
    var t = try init(testing.allocator, 10, 10);
    defer t.deinit(testing.allocator);

    t.status_display = .status_line;
    t.fullReset(testing.allocator);
    try testing.expect(t.status_display == .main);
}

// X
test "Terminal: input with no control characters" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 5), t.screen.cursor.x);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

// X
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
// X
test "Terminal: print single very long line" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    // This would crash for issue 1400. So the assertion here is
    // that we simply do not crash.
    for (0..500) |_| try t.print('x');
}

// X
test "Terminal: print over wide char at 0,0" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    try t.print(0x1F600); // Smiley face
    t.setCursorPos(0, 0);
    try t.print('A'); // Smiley face

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.x);

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 'A'), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expect(!cell.attrs.wide_spacer_tail);
    }
}

// X
test "Terminal: print over wide spacer tail" {
    var t = try init(testing.allocator, 5, 5);
    defer t.deinit(testing.allocator);

    try t.print('橋');
    t.setCursorPos(1, 2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" X", str);
    }

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, 'X'), cell.char);
        try testing.expect(!cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }
}

// X
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

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x26C8), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
}

// X
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

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x2764), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
}

// X
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

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x2764), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
    {
        const cell = row.getCell(2);
        try testing.expectEqual(@as(u32, 0x2764), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(2));
    }
}

// X
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

    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x2764), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x1F468), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }
    {
        const cell = row.getCell(2);
        try testing.expectEqual(@as(u32, 0x1F469), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(2));
    }
    {
        const cell = row.getCell(3);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
    }
    {
        const cell = row.getCell(4);
        try testing.expectEqual(@as(u32, 0x1F467), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(4));
    }
    {
        const cell = row.getCell(5);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x1F468), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 5), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 'x'), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, 0), cell.char);
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 'x'), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, 0), cell.char);
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 'x'), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, 'y'), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(0));
    }
}

// X
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

test "Terminal: soft wrap with semantic prompt" {
    var t = try init(testing.allocator, 3, 80);
    defer t.deinit(testing.allocator);

    t.markSemanticPrompt(.prompt);
    for ("hello") |c| try t.print(c);

    {
        const row = t.screen.getRow(.{ .active = 0 });
        try testing.expect(row.getSemanticPrompt() == .prompt);
    }
    {
        const row = t.screen.getRow(.{ .active = 1 });
        try testing.expect(row.getSemanticPrompt() == .prompt);
    }
}

// X
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
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(4);
        try testing.expectEqual(@as(u32, 0), cell.char);
        try testing.expect(!cell.attrs.wide);
    }
}

// X
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

    // Make sure we printed nothing
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(4);
        try testing.expectEqual(@as(u32, 'A'), cell.char);
        try testing.expect(!cell.attrs.wide);
    }
}

// X
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

    // Make sure we printed nothing
    const row = t.screen.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(4);
        try testing.expectEqual(@as(u32, '❤'), cell.char);
        try testing.expect(!cell.attrs.wide);
    }
}

// X
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
    try t.scrollViewport(.{ .top = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Type
    try t.print('A');
    try t.scrollViewport(.{ .bottom = {} });
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("```◆", str);
    }
}

// X
test "Terminal: print charset outside of ASCII" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    // G1 should have no effect
    t.configureCharset(.G1, .dec_special);
    t.configureCharset(.G2, .dec_special);
    t.configureCharset(.G3, .dec_special);

    // Basic grid writing
    t.configureCharset(.G0, .dec_special);
    try t.print('`');
    try t.print(0x1F600);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("◆ ", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆◆`", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("`◆`", str);
    }
}

// X
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

// X
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

// X
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

// X
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

// X
test "Terminal: linefeed unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    try t.linefeed();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

// X
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

// X
test "Terminal: carriage return unsets pending wrap" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    // Basic grid writing
    for ("hello") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap == true);
    t.carriageReturn();
    try testing.expect(t.screen.cursor.pending_wrap == false);
}

// X
test "Terminal: carriage return origin mode moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.modes.set(.origin, true);
    t.screen.cursor.x = 0;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

// X
test "Terminal: carriage return left of left margin moves to zero" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 1;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
}

// X
test "Terminal: carriage return right of left margin moves to left margin" {
    var t = try init(testing.allocator, 5, 80);
    defer t.deinit(testing.allocator);

    t.screen.cursor.x = 3;
    t.scrolling_region.left = 2;
    t.carriageReturn();
    try testing.expectEqual(@as(usize, 2), t.screen.cursor.x);
}

// X
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

// X
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

// X
test "Terminal: horizontal tabs starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.screen.cursor.x = 8;
    try t.print('X');
    t.screen.cursor.x = 8;
    try t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("        X       A", str);
    }
}

// X
test "Terminal: horizontal tabs with right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.screen.cursor.x = 0;
    try t.print('X');
    try t.horizontalTab();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X    A", str);
    }
}

// X
test "Terminal: horizontal tabs back" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    // Edge of screen
    t.screen.cursor.x = 19;

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

// X
test "Terminal: horizontal tabs back starting on tabstop" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.screen.cursor.x = 8;
    try t.print('X');
    t.screen.cursor.x = 8;
    try t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A       X", str);
    }
}

// X
test "Terminal: horizontal tabs with left margin in origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 5;
    t.screen.cursor.x = 3;
    try t.print('X');
    try t.horizontalTabBack();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  AX", str);
    }
}

// X
test "Terminal: horizontal tab back with cursor before left margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 20, 5);
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.saveCursor();
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(5, 0);
    t.restoreCursor();
    try t.horizontalTabBack();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X", str);
    }
}

// X
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

// X
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

// X
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

// X
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

// X
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

// X
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
    t.setTopAndBottomMargin(10, t.rows);
    t.setCursorPos(0, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(1, 1);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screen.cursor.y);

    t.setCursorPos(100, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 79), t.screen.cursor.y);

    t.setTopAndBottomMargin(10, 11);
    t.setCursorPos(2, 0);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 10), t.screen.cursor.y);
}

// X
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
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

// X
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
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

// X
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
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nGHI", str);
    }
}

// X
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
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

// X
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

// X
test "Terminal: setLeftAndRightMargin left only" {
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
    t.setLeftAndRightMargin(2, 0);
    try testing.expectEqual(@as(usize, 1), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, t.cols - 1), t.scrolling_region.right);
    t.setCursorPos(1, 2);
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

// X
test "Terminal: setLeftAndRightMargin left and right" {
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
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C\nABF\nDEI\nGH", str);
    }
}

// X
test "Terminal: setLeftAndRightMargin left equal right" {
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
    t.setLeftAndRightMargin(2, 2);
    t.setCursorPos(1, 2);
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: setLeftAndRightMargin mode 69 unset" {
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
    t.modes.set(.enable_left_and_right_margin, false);
    t.setLeftAndRightMargin(1, 2);
    t.setCursorPos(1, 2);
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nE\nD", str);
    }
}

// X
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);
    try t.deleteLines(1);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nC\n\nD", str);
    }
}

// X
test "Terminal: deleteLines with scroll region, large count" {
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(1, 1);
    try t.deleteLines(5);

    try t.print('E');
    t.carriageReturn();
    try t.linefeed();

    // We should be
    // try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    // try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\n\n\nD", str);
    }
}

// X
test "Terminal: deleteLines with scroll region, cursor outside of region" {
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

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC\nD", str);
    }
}

// X
test "Terminal: deleteLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.deleteLines(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B", str);
    }
}

// X
test "Terminal: deleteLines simple" {
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
    try t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

// X
test "Terminal: deleteLines left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    try t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nDHI756\nG   89", str);
    }
}

test "Terminal: deleteLines left/right scroll region clears row wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('0');
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    try t.printRepeat(1000);
    for (0..t.rows - 1) |y| {
        const row = t.screen.getRow(.{ .active = y });
        try testing.expect(row.isWrapped());
    }
    {
        const row = t.screen.getRow(.{ .active = t.rows - 1 });
        try testing.expect(!row.isWrapped());
    }
}

// X
test "Terminal: deleteLines left/right scroll region from top" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    try t.deleteLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

// X
test "Terminal: deleteLines left/right scroll region high count" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    try t.deleteLines(100);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nG   89", str);
    }
}

// X
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
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\nGHI", str);
    }
}

// X
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
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: insertLines top/bottom scroll region" {
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
    t.carriageReturn();
    try t.linefeed();
    try t.printString("123");
    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(2, 2);
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\n\nDEF\n123", str);
    }
}

// X
test "Terminal: insertLines left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    try t.insertLines(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123\nD   56\nGEF489\n HI7", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\n\nB\nC", str);
    }
}

// X
test "Terminal: insertLines zero" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    // This should do nothing
    t.setCursorPos(1, 1);
    try t.insertLines(0);
}

// X
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

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(1, 1);
    try t.insertLines(1);

    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nC\nD\nE", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

// X
test "Terminal: insertLines resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.insertLines(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("B\nABCDE", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nBD\nC", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("E\nD\nA\nB", str);
    }
}

// X
test "Terminal: reverseIndex top of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 10);
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
    try t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nX\nA\nB\nC", str);
    }
}

// X
test "Terminal: reverseIndex top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(1, 1);
    try t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nA\nB\nC", str);
    }
}

// X
test "Terminal: reverseIndex not top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setCursorPos(2, 1);
    try t.reverseIndex();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\nB\nC", str);
    }
}

// X
test "Terminal: reverseIndex top/bottom margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(2, 1);
    try t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n\nB", str);
    }
}

// X
test "Terminal: reverseIndex outside top/bottom margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.setCursorPos(2, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('C');
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    try t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nB\nC", str);
    }
}

// X
test "Terminal: reverseIndex left/right margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 2);
    try t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\nDBC\nGEF\n HI", str);
    }
}

// X
test "Terminal: reverseIndex outside left/right margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("ABC");
    t.setCursorPos(2, 1);
    try t.printString("DEF");
    t.setCursorPos(3, 1);
    try t.printString("GHI");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 3);
    t.setCursorPos(1, 1);
    try t.reverseIndex();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: index" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try t.index();
    try t.print('A');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA", str);
    }
}

// X
test "Terminal: index from the bottom" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    t.cursorLeft(1); // undo moving right from 'A'
    try t.index();

    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\nB", str);
    }
}

// X
test "Terminal: index outside of scrolling region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
    t.setTopAndBottomMargin(2, 5);
    try t.index();
    try testing.expectEqual(@as(usize, 1), t.screen.cursor.y);
}

// X
test "Terminal: index from the bottom outside of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 2, 5);
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\n\nAB", str);
    }
}

// X
test "Terminal: index no scroll region, top of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.print('A');
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

// X
test "Terminal: index bottom of primary screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(5, 1);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA\n X", str);
    }
}

// X
test "Terminal: index bottom of primary screen background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    t.setCursorPos(5, 1);
    try t.print('A');
    t.screen.cursor.pen = pen;
    try t.index();

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\n\nA", str);
        for (0..5) |x| {
            const cell = t.screen.getCell(.active, 4, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: index inside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n X", str);
    }
}

// X
test "Terminal: index bottom of scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(4, 1);
    try t.print('B');
    t.setCursorPos(3, 1);
    try t.print('A');
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nA\n X\nB", str);
    }
}

// X
test "Terminal: index bottom of primary screen with scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.setCursorPos(3, 1);
    try t.print('A');
    t.setCursorPos(5, 1);
    try t.index();
    try t.index();
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nA\n\nX", str);
    }
}

// X
test "Terminal: index outside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    t.setTopAndBottomMargin(1, 3);
    t.scrolling_region.left = 3;
    t.scrolling_region.right = 5;
    t.setCursorPos(3, 3);
    try t.print('A');
    t.setCursorPos(3, 1);
    try t.index();
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n\nX A", str);
    }
}

// X
test "Terminal: index inside left/right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
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
    try t.index();

    try testing.expectEqual(@as(usize, 2), t.screen.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AAAAAA\nAAAAAA\n   AAA", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("EE\nEE", str);
    }
}

// X
test "Terminal: decaln reset margins" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    // Initial value
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
    }
}

// X
test "Terminal: decaln preserves color" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    // Initial value
    t.screen.cursor.pen = pen;
    t.modes.set(.origin, true);
    t.setTopAndBottomMargin(2, 3);
    try t.decaln();
    try t.scrollDown(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nEEE\nEEE", str);
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expectEqual(pen, cell);
    }
}

// X
test "Terminal: insertBlanks" {
    // NOTE: this is not verified with conformance tests, so these
    // tests might actually be verifying wrong behavior.
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
    defer t.deinit(alloc);

    try t.print('A');
    try t.print('B');
    try t.print('C');
    t.screen.cursor.pen.attrs.bold = true;
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expect(!cell.attrs.bold);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  A", str);
    }
}

// X
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
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

// X
test "Terminal: insertBlanks no scroll region, fits" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
    }
}

// X
test "Terminal: insertBlanks preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.screen.cursor.pen = pen;
    t.insertBlanks(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  ABC", str);
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expectEqual(pen, cell);
    }
}

// X
test "Terminal: insertBlanks shift off screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 10);
    defer t.deinit(alloc);

    for ("  ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.insertBlanks(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

// X
test "Terminal: insertBlanks split multi-cell character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 10);
    defer t.deinit(alloc);

    for ("123") |c| try t.print(c);
    try t.print('橋');
    t.setCursorPos(1, 1);
    t.insertBlanks(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(" 123", str);
    }
}

// X
test "Terminal: insertBlanks inside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 3);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.insertBlanks(2);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X A", str);
    }
}

// X
test "Terminal: insertBlanks outside left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 6, 10);
    defer t.deinit(alloc);

    t.setCursorPos(1, 4);
    for ("ABC") |c| try t.print(c);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screen.cursor.pending_wrap);
    t.insertBlanks(2);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   ABX", str);
    }
}

// X
test "Terminal: insertBlanks left/right scroll region large count" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    t.modes.set(.origin, true);
    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(3, 5);
    t.setCursorPos(1, 1);
    t.insertBlanks(140);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  X", str);
    }
}

// X
test "Terminal: insert mode with space" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 2);
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

// X
test "Terminal: insert mode doesn't wrap pushed characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
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

// X
test "Terminal: insert mode does nothing at the end of the line" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
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

// X
test "Terminal: insert mode with wide characters" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
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

// X
test "Terminal: insert mode with wide characters at end" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
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

// X
test "Terminal: insert mode pushing off wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 2);
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

test "Terminal: cursorIsAtPrompt" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());

    // Input is also a prompt
    t.markSemanticPrompt(.input);
    try testing.expect(t.cursorIsAtPrompt());

    // Newline -- we expect we're still at a prompt if we received
    // prompt stuff before.
    try t.linefeed();
    try testing.expect(t.cursorIsAtPrompt());

    // But once we say we're starting output, we're not a prompt
    t.markSemanticPrompt(.command);
    try testing.expect(!t.cursorIsAtPrompt());
    try t.linefeed();
    try testing.expect(!t.cursorIsAtPrompt());

    // Until we know we're at a prompt again
    try t.linefeed();
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());
}

test "Terminal: cursorIsAtPrompt alternate screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 2);
    defer t.deinit(alloc);

    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(t.cursorIsAtPrompt());

    // Secondary screen is never a prompt
    t.alternateScreen(alloc, .{});
    try testing.expect(!t.cursorIsAtPrompt());
    t.markSemanticPrompt(.prompt);
    try testing.expect(!t.cursorIsAtPrompt());
}

// X
test "Terminal: print wide char with 1-column width" {
    const alloc = testing.allocator;
    var t = try init(alloc, 1, 2);
    defer t.deinit(alloc);

    try t.print('😀'); // 0x1F600
}

// X
test "Terminal: deleteChars" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    // the cells that shifted in should not have this attribute set
    t.screen.cursor.pen = .{ .attrs = .{ .bold = true } };

    try t.deleteChars(2);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ADE", str);

        const cell = t.screen.getCell(.active, 0, 4);
        try testing.expect(!cell.attrs.bold);
    }
}

// X
test "Terminal: deleteChars zero count" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(0);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE", str);
    }
}

// X
test "Terminal: deleteChars more than half" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(3);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AE", str);
    }
}

// X
test "Terminal: deleteChars more than line width" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(10);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

// X
test "Terminal: deleteChars should shift left" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);

    try t.deleteChars(1);
    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ACDE", str);
    }
}

// X
test "Terminal: deleteChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.deleteChars(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: deleteChars simple operation" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.setCursorPos(1, 3);
    try t.deleteChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
    }
}

// X
test "Terminal: deleteChars background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    try t.printString("ABC123");
    t.setCursorPos(1, 3);
    t.screen.cursor.pen = pen;
    try t.deleteChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB23", str);
        for (t.cols - 2..t.cols) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: deleteChars outside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 6, 10);
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    try testing.expect(t.screen.cursor.pending_wrap);
    try t.deleteChars(2);
    try testing.expect(t.screen.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC123", str);
    }
}

// X
test "Terminal: deleteChars inside scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 6, 10);
    defer t.deinit(alloc);

    try t.printString("ABC123");
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 4;
    t.setCursorPos(1, 4);
    try t.deleteChars(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC2 3", str);
    }
}

// X
test "Terminal: deleteChars split wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 6, 10);
    defer t.deinit(alloc);

    try t.printString("A橋123");
    t.setCursorPos(1, 3);
    try t.deleteChars(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A 123", str);
    }
}

// X
test "Terminal: deleteChars split wide character tail" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setCursorPos(1, t.cols - 1);
    try t.print(0x6A4B); // 橋
    t.carriageReturn();
    try t.deleteChars(t.cols - 1);
    try t.print('0');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("0", str);
    }
}

// X
test "Terminal: eraseChars resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseChars(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: eraseChars resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const row = t.screen.getRow(.{ .active = 0 });
        try testing.expect(row.isWrapped());
    }

    t.setCursorPos(1, 1);
    t.eraseChars(1);

    {
        const row = t.screen.getRow(.{ .active = 0 });
        try testing.expect(!row.isWrapped());
    }
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("XBCDE\n123", str);
    }
}

// X
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

// X
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

// X
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

// X
test "Terminal: eraseChars preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.screen.cursor.pen = pen;
    t.eraseChars(2);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
        {
            const cell = t.screen.getCell(.active, 0, 0);
            try testing.expectEqual(pen, cell);
        }
        {
            const cell = t.screen.getCell(.active, 0, 1);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
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

// X
test "Terminal: eraseChars protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: eraseChars protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: eraseChars protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// https://github.com/mitchellh/ghostty/issues/272
// This is also tested in depth in screen resize tests but I want to keep
// this test around to ensure we don't regress at multiple layers.
test "Terminal: resize less cols with wide char then print" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
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
    var t = try init(alloc, cols, rows);
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
    var t = try init(alloc, cols, rows);
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
    var t = try init(alloc, cols, rows);
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

// X
test "Terminal: saveCursor" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    t.screen.cursor.pen.attrs.bold = true;
    t.screen.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.saveCursor();
    t.screen.charset.gr = .G0;
    t.screen.cursor.pen.attrs.bold = false;
    t.modes.set(.origin, false);
    t.restoreCursor();
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

test "Terminal: saveCursor with screen change" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    t.screen.cursor.pen.attrs.bold = true;
    t.screen.cursor.x = 2;
    t.screen.charset.gr = .G3;
    t.modes.set(.origin, true);
    t.alternateScreen(alloc, .{
        .cursor_save = true,
        .clear_on_enter = true,
    });
    // make sure our cursor and charset have come with us
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.cursor.x == 2);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
    t.screen.charset.gr = .G0;
    t.screen.cursor.pen.attrs.bold = false;
    t.modes.set(.origin, false);
    t.primaryScreen(alloc, .{
        .cursor_save = true,
        .clear_on_enter = true,
    });
    try testing.expect(t.screen.cursor.pen.attrs.bold);
    try testing.expect(t.screen.charset.gr == .G3);
    try testing.expect(t.modes.get(.origin));
}

// X
test "Terminal: saveCursor position" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
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

// X
test "Terminal: saveCursor pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: saveCursor origin mode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
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
    var t = try init(alloc, 10, 5);
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

// X
test "Terminal: saveCursor protected pen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    try testing.expect(t.screen.cursor.pen.attrs.protected);
    t.setCursorPos(1, 10);
    t.saveCursor();
    t.setProtectedMode(.off);
    try testing.expect(!t.screen.cursor.pen.attrs.protected);
    t.restoreCursor();
    try testing.expect(t.screen.cursor.pen.attrs.protected);
}

// X
test "Terminal: setProtectedMode" {
    const alloc = testing.allocator;
    var t = try init(alloc, 3, 3);
    defer t.deinit(alloc);

    try testing.expect(!t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.iso);
    try testing.expect(t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.dec);
    try testing.expect(t.screen.cursor.pen.attrs.protected);
    t.setProtectedMode(.off);
    try testing.expect(!t.screen.cursor.pen.attrs.protected);
}

// X
test "Terminal: eraseLine simple erase right" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

// X
test "Terminal: eraseLine resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseLine(.right, false);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDB", str);
    }
}

// X
test "Terminal: eraseLine resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE123") |c| try t.print(c);
    {
        const row = t.screen.getRow(.{ .active = 0 });
        try testing.expect(row.isWrapped());
    }

    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);

    {
        const row = t.screen.getRow(.{ .active = 0 });
        try testing.expect(!row.isWrapped());
    }
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("X\n123", str);
    }
}

// X
test "Terminal: eraseLine right preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
        for (1..5) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: eraseLine right wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 4);
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB", str);
    }
}

// X
test "Terminal: eraseLine right protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

// X
test "Terminal: eraseLine right protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

// X
test "Terminal: eraseLine right protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.right, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A", str);
    }
}

// X
test "Terminal: eraseLine right protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("12345678") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseLine(.right, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("123  X", str);
    }
}

// X
test "Terminal: eraseLine simple erase left" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("   DE", str);
    }
}

// X
test "Terminal: eraseLine left resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.eraseLine(.left, false);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('B');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    B", str);
    }
}

// X
test "Terminal: eraseLine left preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  CDE", str);
        for (0..2) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: eraseLine left wide character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("AB") |c| try t.print(c);
    try t.print('橋');
    for ("DE") |c| try t.print(c);
    t.setCursorPos(1, 3);
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    DE", str);
    }
}

// X
test "Terminal: eraseLine left protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

// X
test "Terminal: eraseLine left protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

// X
test "Terminal: eraseLine left protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.left, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("  C", str);
    }
}

// X
test "Terminal: eraseLine left protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseLine(.left, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X  9", str);
    }
}

// X
test "Terminal: eraseLine complete preserves background sgr" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    for ("ABCDE") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.screen.cursor.pen = pen;
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
        for (0..5) |x| {
            const cell = t.screen.getCell(.active, 0, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: eraseLine complete protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 1);
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC", str);
    }
}

// X
test "Terminal: eraseLine complete protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.iso);
    for ("ABC") |c| try t.print(c);
    t.setProtectedMode(.dec);
    t.setProtectedMode(.off);
    t.setCursorPos(1, 2);
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

// X
test "Terminal: eraseLine complete protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.setProtectedMode(.dec);
    for ("ABC") |c| try t.print(c);
    t.setCursorPos(1, 2);
    t.eraseLine(.complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

// X
test "Terminal: eraseLine complete protected requested" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseLine(.complete, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("     X", str);
    }
}

// X
test "Terminal: eraseDisplay simple erase below" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

// X
test "Terminal: eraseDisplay erase below preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    t.screen.cursor.pen = pen;
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
        for (1..5) |x| {
            const cell = t.screen.getCell(.active, 1, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: eraseDisplay below split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 4);
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AB橋C\nDE", str);
    }
}

// X
test "Terminal: eraseDisplay below protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay below protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

// X
test "Terminal: eraseDisplay below protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .below, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nD", str);
    }
}

// X
test "Terminal: eraseDisplay simple erase above" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay below protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay erase above preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABC") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("DEF") |c| try t.print(c);
    t.carriageReturn();
    try t.linefeed();
    for ("GHI") |c| try t.print(c);
    t.setCursorPos(2, 2);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    t.screen.cursor.pen = pen;
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
        for (0..2) |x| {
            const cell = t.screen.getCell(.active, 1, x);
            try testing.expectEqual(pen, cell);
        }
    }
}

// X
test "Terminal: eraseDisplay above split multi-cell" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("AB橋C");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("DE橋F");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("GH橋I");
    t.setCursorPos(2, 3);
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    F\nGH橋I", str);
    }
}

// X
test "Terminal: eraseDisplay above protected attributes respected with iso" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay above protected attributes ignored with dec most recent" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay above protected attributes ignored with dec set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .above, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n  F\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay above protected attributes respected with force" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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
    t.eraseDisplay(alloc, .above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\nGHI", str);
    }
}

// X
test "Terminal: eraseDisplay above" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = .{ .rgb = pink },
        .fg = .{ .rgb = pink },
        .attrs = .{ .bold = true },
    };
    const cell_ptr = t.screen.getCellPtr(.active, 0, 0);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg.rgb.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // move the cursor below it
    t.screen.cursor.y = 40;
    t.screen.cursor.x = 40;
    // erase above the cursor
    t.eraseDisplay(testing.allocator, .above, false);
    // check it was erased
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg == .none);
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);

    // Check that our pen hasn't changed
    try testing.expect(t.screen.cursor.pen.attrs.bold);

    // check that another cell got the correct bg
    cell = t.screen.getCell(.active, 0, 1);
    try testing.expect(cell.bg.rgb.eql(pink));
}

// X
test "Terminal: eraseDisplay below" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = .{ .rgb = pink },
        .fg = .{ .rgb = pink },
        .attrs = .{ .bold = true },
    };
    const cell_ptr = t.screen.getCellPtr(.active, 60, 60);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg.rgb.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // erase below the cursor
    t.eraseDisplay(testing.allocator, .below, false);
    // check it was erased
    cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg == .none);
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);

    // check that another cell got the correct bg
    cell = t.screen.getCell(.active, 0, 1);
    try testing.expect(cell.bg.rgb.eql(pink));
}

// X
test "Terminal: eraseDisplay complete" {
    var t = try init(testing.allocator, 80, 80);
    defer t.deinit(testing.allocator);

    const pink = color.RGB{ .r = 0xFF, .g = 0x00, .b = 0x7F };
    t.screen.cursor.pen = Screen.Cell{
        .char = 'a',
        .bg = .{ .rgb = pink },
        .fg = .{ .rgb = pink },
        .attrs = .{ .bold = true },
    };
    var cell_ptr = t.screen.getCellPtr(.active, 60, 60);
    cell_ptr.* = t.screen.cursor.pen;
    cell_ptr = t.screen.getCellPtr(.active, 0, 0);
    cell_ptr.* = t.screen.cursor.pen;
    // verify the cell was set
    var cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg.rgb.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // verify the cell was set
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg.rgb.eql(pink));
    try testing.expect(cell.char == 'a');
    try testing.expect(cell.attrs.bold);
    // position our cursor between the cells
    t.screen.cursor.y = 30;
    // erase everything
    t.eraseDisplay(testing.allocator, .complete, false);
    // check they were erased
    cell = t.screen.getCell(.active, 60, 60);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg == .none);
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
    cell = t.screen.getCell(.active, 0, 0);
    try testing.expect(cell.bg.rgb.eql(pink));
    try testing.expect(cell.fg == .none);
    try testing.expect(cell.char == 0);
    try testing.expect(!cell.attrs.bold);
}

// X
test "Terminal: eraseDisplay protected complete" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseDisplay(alloc, .complete, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X", str);
    }
}

// X
test "Terminal: eraseDisplay protected below" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 4);
    t.eraseDisplay(alloc, .below, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A\n123  X", str);
    }
}

// X
test "Terminal: eraseDisplay protected above" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    t.eraseDisplay(alloc, .scroll_complete, false);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

// X
test "Terminal: eraseDisplay scroll complete" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 3);
    defer t.deinit(alloc);

    try t.print('A');
    t.carriageReturn();
    try t.linefeed();
    for ("123456789") |c| try t.print(c);
    t.setCursorPos(t.screen.cursor.y + 1, 6);
    t.setProtectedMode(.dec);
    try t.print('X');
    t.setCursorPos(t.screen.cursor.y + 1, 8);
    t.eraseDisplay(alloc, .above, true);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n     X  9", str);
    }
}

// X
test "Terminal: cursorLeft no wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 5);
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

// X
test "Terminal: cursorLeft unsets pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCXE", str);
    }
}

// X
test "Terminal: cursorLeft unsets pending wrap state with longer jump" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(3);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AXCDE", str);
    }
}

// X
test "Terminal: cursorLeft reverse wrap with pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: cursorLeft reverse wrap extended with pending wrap state" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorLeft(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: cursorLeft reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    for ("ABCDE1") |c| try t.print(c);
    t.cursorLeft(2);
    try t.print('X');
    try testing.expect(t.screen.cursor.pending_wrap);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX\n1", str);
    }
}

// X
test "Terminal: cursorLeft reverse wrap with no soft wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorLeft reverse wrap before left margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorLeft extended reverse wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorLeft extended reverse wrap bottom wraparound" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 3);
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

// X
test "Terminal: cursorLeft extended reverse wrap is priority if both set" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 3);
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

// X
test "Terminal: cursorLeft extended reverse wrap above top scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap_extended, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(2, 1);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
}

// X
test "Terminal: cursorLeft reverse wrap on first row" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.wraparound, true);
    t.modes.set(.reverse_wrap, true);

    t.setTopAndBottomMargin(3, 0);
    t.setCursorPos(1, 2);
    t.cursorLeft(1000);

    try testing.expectEqual(@as(usize, 0), t.screen.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screen.cursor.y);
}

// X
test "Terminal: cursorDown basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorDown above bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorDown below bottom scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorDown resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorDown(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDE\n    X", str);
    }
}

// X
test "Terminal: cursorUp basic" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorUp below top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorUp above top scroll margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorUp resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorUp(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: cursorRight resets wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);
    t.cursorRight(1);
    try testing.expect(!t.screen.cursor.pending_wrap);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABCDX", str);
    }
}

// X
test "Terminal: cursorRight to the edge of screen" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

// X
test "Terminal: cursorRight left of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: cursorRight right of right margin" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.scrolling_region.right = 2;
    t.screen.cursor.x = 3;
    t.cursorRight(100);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    X", str);
    }
}

// X
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
    try t.scrollDown(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\nABC\nDEF\nGHI", str);
    }
}

// X
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
    try t.scrollDown(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nDEF\n\nGHI", str);
    }
}

// X
test "Terminal: scrollDown left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    const cursor = t.screen.cursor;
    try t.scrollDown(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

// X
test "Terminal: scrollDown outside of left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    const cursor = t.screen.cursor;
    try t.scrollDown(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("A   23\nDBC156\nGEF489\n HI7", str);
    }
}

// X
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
    try t.scrollDown(1);
    try t.print('X');

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("\n    A\n    B\nX   C", str);
    }
}

// X
test "Terminal: scrollUp simple" {
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
    try t.scrollUp(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("DEF\nGHI", str);
    }
}

// X
test "Terminal: scrollUp top/bottom scroll region" {
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
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(1, 1);
    try t.scrollUp(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("ABC\nGHI", str);
    }
}

// X
test "Terminal: scrollUp left/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 10, 10);
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
    const cursor = t.screen.cursor;
    try t.scrollUp(1);
    try testing.expectEqual(cursor, t.screen.cursor);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AEF423\nDHI756\nG   89", str);
    }
}

// X
test "Terminal: scrollUp preserves pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: scrollUp full top/bottom region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.setTopAndBottomMargin(2, 5);
    try t.scrollUp(4);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top", str);
    }
}

// X
test "Terminal: scrollUp full top/bottomleft/right scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("top");
    t.setCursorPos(5, 1);
    try t.printString("ABCDE");
    t.modes.set(.enable_left_and_right_margin, true);
    t.setTopAndBottomMargin(2, 5);
    t.setLeftAndRightMargin(2, 4);
    try t.scrollUp(4);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("top\n\n\n\nA   E", str);
    }
}

// X
test "Terminal: tabClear single" {
    const alloc = testing.allocator;
    var t = try init(alloc, 30, 5);
    defer t.deinit(alloc);

    try t.horizontalTab();
    t.tabClear(.current);
    t.setCursorPos(1, 1);
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 16), t.screen.cursor.x);
}

// X
test "Terminal: tabClear all" {
    const alloc = testing.allocator;
    var t = try init(alloc, 30, 5);
    defer t.deinit(alloc);

    t.tabClear(.all);
    t.setCursorPos(1, 1);
    try t.horizontalTab();
    try testing.expectEqual(@as(usize, 29), t.screen.cursor.x);
}

// X
test "Terminal: printRepeat simple" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("A");
    try t.printRepeat(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AA", str);
    }
}

// X
test "Terminal: printRepeat wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printString("    A");
    try t.printRepeat(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("    A\nA", str);
    }
}

// X
test "Terminal: printRepeat no previous character" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    try t.printRepeat(1);

    {
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }
}

test "Terminal: DECCOLM without DEC mode 40" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.@"132_column", true);
    try t.deccolm(alloc, .@"132_cols");
    try testing.expectEqual(@as(usize, 5), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.modes.get(.@"132_column"));
}

test "Terminal: DECCOLM unset" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
}

test "Terminal: DECCOLM resets pending wrap" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    for ("ABCDE") |c| try t.print(c);
    try testing.expect(t.screen.cursor.pending_wrap);

    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");
    try testing.expectEqual(@as(usize, 80), t.cols);
    try testing.expectEqual(@as(usize, 5), t.rows);
    try testing.expect(!t.screen.cursor.pending_wrap);
}

test "Terminal: DECCOLM preserves SGR bg" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
    defer t.deinit(alloc);

    const pen: Screen.Cell = .{
        .bg = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } },
    };

    t.screen.cursor.pen = pen;
    t.modes.set(.enable_mode_3, true);
    try t.deccolm(alloc, .@"80_cols");

    {
        const cell = t.screen.getCell(.active, 0, 0);
        try testing.expectEqual(pen, cell);
    }
}

test "Terminal: DECCOLM resets scroll region" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

// X
test "Terminal: printAttributes" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 5);
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

test "Terminal: preserve grapheme cluster on large scrollback" {
    const alloc = testing.allocator;
    var t = try init(alloc, 5, 3);
    defer t.deinit(alloc);

    // This is the label emoji + the VS16 variant selector
    const label = "\u{1F3F7}\u{FE0F}";

    // This bug required a certain behavior around scrollback interacting
    // with the circular buffer that we use at the time of writing this test.
    // Mainly, we want to verify that in certain scroll scenarios we preserve
    // grapheme clusters. This test is admittedly somewhat brittle but we
    // should keep it around to prevent this regression.
    for (0..t.screen.max_scrollback * 2) |_| {
        try t.printString(label ++ "\n");
    }

    try t.scrollViewport(.{ .delta = -1 });
    {
        const str = try t.screen.testString(alloc, .viewport);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("🏷️\n🏷️\n🏷️", str);
    }
}
