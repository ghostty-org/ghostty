const std = @import("std");
const size = @import("size.zig");
const charsets = @import("charsets.zig");
const kitty = @import("kitty.zig");
const modespkg = @import("modes.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Cell = @import("page.zig").Cell;
const Page = @import("page.zig").Page;
const PageList = @import("PageList.zig");
const Row = @import("page.zig").Row;
const Selection = @import("Selection.zig");
const Style = @import("style.zig").Style;

// TODO:
// - Rectangular selection

/// Formats available.
pub const Format = enum {
    /// Plain text
    plain,

    /// Include VT sequences to preserve colors, styles, URLs, etc.
    /// This is predominantly SGR sequences but may contain others as needed.
    ///
    /// Note that for reference colors, like palette indices, this will
    /// vary based on the formatter and you should see the docs. For example,
    /// PageFormatter with VT will emit SGR sequences with palette indices,
    /// not the color itself.
    vt,

    pub fn styled(self: Format) bool {
        return switch (self) {
            .plain => false,
            .vt => true,
        };
    }
};

/// Common encoding options regardless of what exact formatter is used.
pub const Options = struct {
    /// The format to emit.
    emit: Format,

    /// Whether to unwrap soft-wrapped lines. If false, this will emit the
    /// screen contents as it is rendered on the page in the given size.
    unwrap: bool = false,

    pub const plain: Options = .{ .emit = .plain };
    pub const vt: Options = .{ .emit = .vt };
};

/// Terminal formatter formats the active terminal screen.
///
/// This will always only emit data related to the currently active screen.
/// If you want to emit data for a specific screen (e.g. primary vs alt), then
/// switch to that screen in the terminal prior to using this.
///
/// If you want to emit data for all screens (a less common operation), then
/// you must create a no-content TerminalFormatter followed by multiple
/// explicit ScreenFormatter calls. This isn't a common operation so this
/// little extra work should be acceptable.
///
/// For styled formatting, this will emit the palette colors at the
/// beginning so that the output can be rendered properly according to
/// the current terminal state.
pub const TerminalFormatter = struct {
    /// The terminal to format.
    terminal: *const Terminal,

    /// The common options
    opts: Options,

    /// The content to include.
    content: ScreenFormatter.Content,

    /// Extra stuff to emit, such as terminal modes, palette, cursor, etc.
    /// This information is ONLY emitted when the format is "vt".
    extra: Extra,

    pub const Extra = packed struct {
        /// Emit the palette using OSC 4 sequences.
        palette: bool,

        /// Emit terminal modes that differ from their defaults using CSI h/l
        /// sequences. Defaults are according to the Ghostty defaults which
        /// are generally match most terminal defaults. This will include
        /// things like current screen, bracketed mode, mouse event reporting,
        /// etc.
        modes: bool,

        /// Emit scrolling region state using DECSTBM and DECSLRM sequences.
        scrolling_region: bool,

        /// Emit tabstop positions by clearing all tabs (CSI 3 g) and setting
        /// each configured tabstop with HTS.
        tabstops: bool,

        /// Emit the present working directory using OSC 7.
        pwd: bool,

        /// Emit keyboard modes such as ModifyOtherKeys using CSI > 4 m
        /// sequences.
        keyboard: bool,

        /// The screen extras to emit. TerminalFormatter always only
        /// emits data for the currently active screen. If you want to emit
        /// data for all screens, you should manually construct a no-content
        /// terminal formatter, followed by screen formatters.
        screen: ScreenFormatter.Extra,

        /// Emit nothing.
        pub const none: Extra = .{
            .palette = false,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .none,
        };

        /// Emit style-relevant information only such as palettes.
        pub const styles: Extra = .{
            .palette = true,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .styles,
        };

        /// Emit everything. This reconstructs the terminal state as closely
        /// as possible.
        pub const all: Extra = .{
            .palette = true,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        };
    };

    pub fn init(
        terminal: *const Terminal,
        opts: Options,
    ) TerminalFormatter {
        return .{
            .terminal = terminal,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .styles,
        };
    }

    pub fn format(
        self: TerminalFormatter,
        writer: *std.Io.Writer,
    ) !void {
        // Emit palette before screen content if using VT format. Technically
        // we could do this after but this way if replay is slow for whatever
        // reason the colors will be right right away.
        if (self.opts.emit == .vt and self.extra.palette) {
            for (self.terminal.color_palette.colors, 0..) |rgb, i| {
                try writer.print(
                    "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                    .{ i, rgb.r, rgb.g, rgb.b },
                );
            }
        }

        // Emit terminal modes that differ from defaults. We probably have
        // some modes we want to emit before and some after, but for now for
        // simplicity we just emit them all before. If we make this more complex
        // later we should add test cases for it.
        if (self.opts.emit == .vt and self.extra.modes) {
            inline for (@typeInfo(modespkg.Mode).@"enum".fields) |field| {
                const mode: modespkg.Mode = @enumFromInt(field.value);
                const current = self.terminal.modes.get(mode);
                const default_val = @field(self.terminal.modes.default, field.name);

                if (current != default_val) {
                    const tag: modespkg.ModeTag = @bitCast(@intFromEnum(mode));
                    const prefix = if (tag.ansi) "" else "?";
                    const suffix = if (current) "h" else "l";
                    try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
                }
            }
        }

        var screen_formatter: ScreenFormatter = .init(&self.terminal.screen, self.opts);
        screen_formatter.content = self.content;
        screen_formatter.extra = self.extra.screen;
        try screen_formatter.format(writer);

        // Extra terminal state to emit after the screen contents so that
        // it doesn't impact the emitted contents.
        if (self.opts.emit == .vt) {
            // Emit scrolling region using DECSTBM and DECSLRM
            if (self.extra.scrolling_region) {
                const region = &self.terminal.scrolling_region;

                // DECSTBM: top and bottom margins (1-indexed)
                // Only emit if not the full screen
                if (region.top != 0 or region.bottom != self.terminal.rows - 1) {
                    try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
                }

                // DECSLRM: left and right margins (1-indexed)
                // Only emit if not the full width
                if (region.left != 0 or region.right != self.terminal.cols - 1) {
                    try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
                }
            }

            // Emit tabstop positions
            if (self.extra.tabstops) {
                // Clear all tabs (CSI 3 g)
                try writer.print("\x1b[3g", .{});

                // Set each configured tabstop by moving cursor and using HTS
                for (0..self.terminal.cols) |col| {
                    if (self.terminal.tabstops.get(col)) {
                        // Move cursor to the column (1-indexed)
                        try writer.print("\x1b[{d}G", .{col + 1});
                        // Set tab (HTS)
                        try writer.print("\x1bH", .{});
                    }
                }
            }

            // Emit keyboard modes such as ModifyOtherKeys
            if (self.extra.keyboard) {
                // Only emit if modify_other_keys_2 is true
                if (self.terminal.flags.modify_other_keys_2) {
                    try writer.print("\x1b[>4;2m", .{});
                }
            }

            // Emit present working directory using OSC 7
            if (self.extra.pwd) {
                const pwd = self.terminal.pwd.items;
                if (pwd.len > 0) try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
            }
        }
    }
};

/// Screen formatter formats a single terminal screen (e.g. primary vs alt).
pub const ScreenFormatter = struct {
    /// The screen to format.
    screen: *const Screen,

    /// The common options
    opts: Options,

    /// The content to include.
    content: Content,

    /// Extra stuff to emit, such as cursor, style, hyperlinks, etc.
    /// This information is ONLY emitted when the format is "vt".
    extra: Extra,

    pub const Content = union(enum) {
        /// Emit no content, only terminal state such as modes, palette, etc.
        /// via extra.
        none,

        /// Emit the content specified by the selection. Null for all.
        selection: ?Selection,
    };

    pub const Extra = packed struct {
        /// Emit cursor position using CUP (CSI H).
        cursor: bool,

        /// Emit current SGR style state based on the cursor's active style_id.
        /// This reconstructs the SGR attributes (bold, italic, colors, etc.) at
        /// the cursor position.
        style: bool,

        /// Emit current hyperlink state using OSC 8 sequences.
        /// This sets the active hyperlink based on cursor.hyperlink_id.
        hyperlink: bool,

        /// Emit character protection mode using DECSCA.
        protection: bool,

        /// Emit Kitty keyboard protocol state using CSI > u and CSI = sequences.
        kitty_keyboard: bool,

        /// Emit character set designations and invocations.
        /// This includes G0-G3 designations (ESC ( ) * +) and GL/GR invocations.
        charsets: bool,

        /// Emit nothing.
        pub const none: Extra = .{
            .cursor = false,
            .style = false,
            .hyperlink = false,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };

        /// Emit style-relevant information only.
        pub const styles: Extra = .{
            .cursor = false,
            .style = true,
            .hyperlink = true,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };

        /// Emit everything. This reconstructs the screen state as closely
        /// as possible.
        pub const all: Extra = .{
            .cursor = true,
            .style = true,
            .hyperlink = true,
            .protection = true,
            .kitty_keyboard = true,
            .charsets = true,
        };
    };

    pub fn init(
        screen: *const Screen,
        opts: Options,
    ) ScreenFormatter {
        return .{
            .screen = screen,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .none,
        };
    }

    pub fn format(
        self: ScreenFormatter,
        writer: *std.Io.Writer,
    ) !void {
        switch (self.content) {
            .none => {},

            .selection => |selection_| {
                // Emit our pagelist contents according to our selection.
                var list_formatter: PageListFormatter = .init(&self.screen.pages, self.opts);
                if (selection_) |sel| {
                    list_formatter.top_left = sel.topLeft(self.screen);
                    list_formatter.bottom_right = sel.bottomRight(self.screen);
                }
                try list_formatter.format(writer);
            },
        }

        // Emit extra screen state after content if we care. The state has
        // to be emitted after since some state such as cursor position and
        // style are impacted by content rendering.
        switch (self.opts.emit) {
            .plain => return,
            .vt => {},
        }

        // Emit current SGR style state
        if (self.extra.style) {
            const cursor = &self.screen.cursor;
            try writer.print("{f}", .{cursor.style.formatterVt()});
        }

        // Emit current hyperlink state using OSC 8
        if (self.extra.hyperlink) {
            const cursor = &self.screen.cursor;
            if (cursor.hyperlink) |link| {
                // Start hyperlink with uri (and explicit id if present)
                switch (link.id) {
                    .explicit => |id| try writer.print(
                        "\x1b]8;id={s};{s}\x1b\\",
                        .{ id, link.uri },
                    ),
                    .implicit => try writer.print(
                        "\x1b]8;;{s}\x1b\\",
                        .{link.uri},
                    ),
                }
            }
        }

        // Emit character protection mode using DECSCA
        if (self.extra.protection) {
            const cursor = &self.screen.cursor;
            if (cursor.protected) {
                // DEC protected mode
                try writer.print("\x1b[1\"q", .{});
            }
        }

        // Emit Kitty keyboard protocol state using CSI = u
        if (self.extra.kitty_keyboard) {
            const current_flags = self.screen.kitty_keyboard.current();
            if (current_flags.int() != kitty.KeyFlags.disabled.int()) {
                const flags = current_flags.int();
                try writer.print("\x1b[={d};1u", .{flags});
            }
        }

        // Emit character set designations and invocations
        if (self.extra.charsets) {
            const charset = &self.screen.charset;

            // Emit G0-G3 designations
            for (std.enums.values(charsets.Slots)) |slot| {
                const cs = charset.charsets.get(slot);
                if (cs != .utf8) { // Only emit non-default charsets
                    const intermediate: u8 = switch (slot) {
                        .G0 => '(',
                        .G1 => ')',
                        .G2 => '*',
                        .G3 => '+',
                    };
                    const final: u8 = switch (cs) {
                        .ascii => 'B',
                        .british => 'A',
                        .dec_special => '0',
                        else => continue,
                    };
                    try writer.print("\x1b{c}{c}", .{ intermediate, final });
                }
            }

            // Emit GL invocation if not G0
            if (charset.gl != .G0) {
                const seq = switch (charset.gl) {
                    .G0 => unreachable,
                    .G1 => "\x0e", // SO - Shift Out
                    .G2 => "\x1bn", // LS2
                    .G3 => "\x1bo", // LS3
                };
                try writer.print("{s}", .{seq});
            }

            // Emit GR invocation if not G2
            if (charset.gr != .G2) {
                const seq = switch (charset.gr) {
                    .G0 => unreachable, // GR can't be G0
                    .G1 => "\x1b~", // LS1R
                    .G2 => unreachable,
                    .G3 => "\x1b|", // LS3R
                };
                try writer.print("{s}", .{seq});
            }
        }

        // Emit cursor position using CUP (CSI H)
        if (self.extra.cursor) {
            const cursor = &self.screen.cursor;
            // CUP is 1-indexed
            try writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });
        }
    }
};

/// PageList formatter formats multiple pages as represented by a PageList.
pub const PageListFormatter = struct {
    /// The pagelist to format.
    list: *const PageList,

    /// The common options
    opts: Options,

    /// The bounds of the PageList to format. The top left and bottom right
    /// MUST be ordered properly.
    top_left: ?PageList.Pin,
    bottom_right: ?PageList.Pin,

    pub fn init(
        list: *const PageList,
        opts: Options,
    ) PageListFormatter {
        return PageListFormatter{
            .list = list,
            .opts = opts,
            .top_left = null,
            .bottom_right = null,
        };
    }

    pub fn format(
        self: PageListFormatter,
        writer: *std.Io.Writer,
    ) !void {
        const tl: PageList.Pin = self.top_left orelse self.list.getTopLeft(.screen);
        const br: PageList.Pin = self.bottom_right orelse self.list.getBottomRight(.screen).?;

        var page_state: ?PageFormatter.TrailingState = null;
        var iter = tl.pageIterator(.right_down, br);
        while (iter.next()) |chunk| {
            var formatter: PageFormatter = .init(&chunk.node.data, self.opts);
            formatter.start_y = chunk.start;
            formatter.end_y = chunk.end;
            formatter.trailing_state = page_state;

            // Apply start_x if this is the first chunk
            if (chunk.node == tl.node) formatter.start_x = tl.x;

            // Apply end_x if this is the last chunk and it ends at br.y
            if (chunk.node == br.node and
                formatter.end_y == br.y + 1) formatter.end_x = br.x + 1;

            page_state = try formatter.formatWithState(writer);
        }
    }
};

/// Page formatter.
///
/// For styled formatting such as VT, this will emit references for palette
/// colors. If you want to capture the palette as-is at the type of formatting,
/// you'll have to emit the sequences for setting up the palette prior to
/// this formatting. (TODO: A function to do this)
pub const PageFormatter = struct {
    /// The page to format.
    page: *const Page,

    /// The common options
    opts: Options,

    /// Start and end points within the page to format. If end x is not given
    /// then it will be the full width. If end y is not given then it will be
    /// the full height.
    ///
    /// The start x is considered the X in the first row and end X is
    /// X in the final row. This isn't a rectangle selection by default.
    start_x: size.CellCountInt,
    start_y: size.CellCountInt,
    end_x: ?size.CellCountInt,
    end_y: ?size.CellCountInt,

    /// The previous trailing state from the prior page. If you're iterating
    /// over multiple pages this helps ensure that unwrapping and other
    /// accounting works properly.
    trailing_state: ?TrailingState,

    /// Trailing state. This is used to ensure that rows wrapped across
    /// multiple pages are unwrapped properly, as well as other accounting
    /// we may do in the future.
    pub const TrailingState = struct {
        rows: usize = 0,
        cells: usize = 0,

        pub const empty: TrailingState = .{ .rows = 0, .cells = 0 };
    };

    /// Initializes a page formatter. Other options can be set directly on the
    /// struct after initialization and before calling `format()`.
    pub fn init(page: *const Page, opts: Options) PageFormatter {
        return PageFormatter{
            .page = page,
            .opts = opts,
            .start_x = 0,
            .start_y = 0,
            .end_x = null,
            .end_y = null,
            .trailing_state = null,
        };
    }

    pub fn format(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) !void {
        _ = try self.formatWithState(writer);
    }

    pub fn formatWithState(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) !TrailingState {
        var blank_rows: usize = 0;
        var blank_cells: usize = 0;

        // Continue our prior trailing state if we have it, but only if we're
        // starting from the beginning (start_y and start_x are both 0).
        // If a non-zero start position is specified, ignore trailing state.
        if (self.trailing_state) |state| {
            if (self.start_y == 0 and self.start_x == 0) {
                blank_rows = state.rows;
                blank_cells = state.cells;
            }
        }

        // Setup our starting row and perform some validation for overflows.
        const start_y: size.CellCountInt = self.start_y;
        if (start_y >= self.page.size.rows) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_y_unclamped: size.CellCountInt = self.end_y orelse self.page.size.rows;
        if (start_y >= end_y_unclamped) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_y = @min(end_y_unclamped, self.page.size.rows);

        // Setup our starting column and perform some validation for overflows.
        // Note: start_x only applies to the first row, end_x only applies to the last row.
        const start_x: size.CellCountInt = self.start_x;
        if (start_x >= self.page.size.cols) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_x_unclamped: size.CellCountInt = self.end_x orelse self.page.size.cols;
        const end_x = @min(end_x_unclamped, self.page.size.cols);

        // If we only have a single row, validate that start_x < end_x
        if (start_y + 1 == end_y and start_x >= end_x) {
            return .{ .rows = blank_rows, .cells = blank_cells };
        }

        // Our style for non-plain formats
        var style: Style = .{};

        for (start_y..end_y) |y_usize| {
            const y: size.CellCountInt = @intCast(y_usize);
            const row: *Row = self.page.getRow(y);
            const cells: []const Cell = self.page.getCells(row);

            // Determine the x range for this row
            // - First row: start_x to end of row (or end_x if single row)
            // - Last row: start of row to end_x
            // - Middle rows: full width
            const is_first_row = (y == start_y);
            const is_last_row = (y == end_y - 1);
            const row_start_x: size.CellCountInt = if (is_first_row) start_x else 0;
            const row_end_x: size.CellCountInt = if (is_last_row) end_x else self.page.size.cols;
            const cells_subset = cells[row_start_x..row_end_x];

            // If this row is blank, accumulate to avoid a bunch of extra
            // work later. If it isn't blank, make sure we dump all our
            // blanks.
            if (!Cell.hasTextAny(cells_subset)) {
                blank_rows += 1;
                continue;
            }

            for (1..blank_rows + 1) |_| {
                try writer.writeAll("\r\n");
            }
            blank_rows = 0;

            // If we're not wrapped, we always add a newline so after
            // the row is printed we can add a newline.
            if (!row.wrap or !self.opts.unwrap) blank_rows += 1;

            // If the row doesn't continue a wrap then we need to reset
            // our blank cell count.
            if (!row.wrap_continuation or !self.opts.unwrap) blank_cells = 0;

            // Go through each cell and print it
            for (cells_subset) |*cell| {
                // Skip spacers. These happen naturally when wide characters
                // are printed again on the screen (for well-behaved terminals!)
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                // If we have a zero value, then we accumulate a counter. We
                // only want to turn zero values into spaces if we have a non-zero
                // char sometime later.
                if (!cell.hasText() or cell.codepoint() == ' ') {
                    blank_cells += 1;
                    continue;
                }

                // This cell is not blank. If we have accumulated blank cells
                // then we want to emit them now.
                if (blank_cells > 0) {
                    try writer.splatByteAll(' ', blank_cells);
                    blank_cells = 0;
                }

                switch (cell.content_tag) {
                    // We combine codepoint and graphemes because both have
                    // shared style handling. We use comptime to dup it.
                    inline .codepoint, .codepoint_grapheme => |tag| {
                        // If we're emitting styling and we have styles, then
                        // we need to load the style and emit any sequences
                        // as necessary.
                        if (self.opts.emit.styled() and cell.hasStyling()) style: {
                            // Get the style.
                            const cell_style = self.page.styles.get(
                                self.page.memory,
                                cell.style_id,
                            );

                            // If the style hasn't changed since our last
                            // emitted style, don't bloat the output.
                            if (cell_style.eql(style)) break :style;

                            // New style, emit it.
                            style = cell_style.*;
                            try writer.print("{f}", .{style.formatterVt()});
                        }

                        try writer.print("{u}", .{cell.content.codepoint});
                        if (comptime tag == .codepoint_grapheme) {
                            for (self.page.lookupGrapheme(cell).?) |cp| {
                                try writer.print("{u}", .{cp});
                            }
                        }
                    },

                    // Unreachable since we do hasText() above
                    .bg_color_palette,
                    .bg_color_rgb,
                    => unreachable,
                }
            }
        }

        return .{ .rows = blank_rows, .cells = blank_cells };
    }
};

test "Page plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello, world");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello, world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 12), state.cells);
}

test "Page plain multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain multi blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\n\r\n\r\nworld");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello\r\n\r\n\r\nworld", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 3), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain trailing blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld\r\n\r\n");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output. We expect there to be no trailing newlines because
    // we can't differentiate trailing blank lines as being meaningful because
    // the page formatter can't see the cursor position.
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain trailing whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello   \r\nworld   ");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output. We expect there to be no trailing newlines because
    // we can't differentiate trailing blank lines as being meaningful because
    // the page formatter can't see the cursor position.
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain with prior trailing state rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    var formatter: PageFormatter = .init(page, .plain);
    formatter.trailing_state = .{ .rows = 2, .cells = 0 };

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("\r\n\r\nhello", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain with prior trailing state cells no wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    var formatter: PageFormatter = .init(page, .plain);
    formatter.trailing_state = .{ .rows = 0, .cells = 3 };

    const state = try formatter.formatWithState(&builder.writer);
    // Blank cells are reset when row is not a wrap continuation
    try testing.expectEqualStrings("hello", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain with prior trailing state cells with wrap continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("world");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;

    // Surgically modify the first row to be a wrap continuation
    const row = page.getRow(0);
    row.wrap_continuation = true;

    var formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });
    formatter.trailing_state = .{ .rows = 0, .cells = 3 };

    const state = try formatter.formatWithState(&builder.writer);
    // Blank cells are preserved when row is a wrap continuation with unwrap enabled
    try testing.expectEqualStrings("   world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain soft-wrapped without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world test");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    const state = try formatter.formatWithState(&builder.writer);
    // Without unwrap, wrapped lines show as separate lines
    try testing.expectEqualStrings("hello worl\r\nd test", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
}

test "Page plain soft-wrapped with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world test");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });

    const state = try formatter.formatWithState(&builder.writer);
    // With unwrap, wrapped lines are joined together
    try testing.expectEqualStrings("hello world test", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
}

test "Page plain soft-wrapped 3 lines without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world this is a test");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    const state = try formatter.formatWithState(&builder.writer);
    // Without unwrap, wrapped lines show as separate lines
    try testing.expectEqualStrings("hello worl\r\nd this is\r\na test", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
}

test "Page plain soft-wrapped 3 lines with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world this is a test");

    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .{ .emit = .plain, .unwrap = true });

    const state = try formatter.formatWithState(&builder.writer);
    // With unwrap, wrapped lines are joined together
    try testing.expectEqualStrings("hello world this is a test", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 6), state.cells);
}

test "Page plain start_y subset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld\r\ntest");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("world\r\ntest", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 2), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
}

test "Page plain end_y subset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld\r\ntest");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 2;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain start_y and end_y range" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld\r\ntest\r\nfoo");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;
    formatter.end_y = 3;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("world\r\ntest", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 4), state.cells);
}

test "Page plain start_y out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 30;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
}

test "Page plain end_y greater than rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 30;

    const state = try formatter.formatWithState(&builder.writer);
    // Should clamp to page.size.rows and work normally
    try testing.expectEqualStrings("hello", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain end_y less than start_y" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 5;
    formatter.end_y = 2;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
}

test "Page plain start_x on first row only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 11), state.cells);
}

test "Page plain end_x on last row only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("first line\r\nsecond line\r\nthird line");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_y = 3;
    formatter.end_x = 6;

    const state = try formatter.formatWithState(&builder.writer);
    // First two rows: full width, last row: up to end_x=6
    try testing.expectEqualStrings("first line\r\nsecond line\r\nthird", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, 1), state.cells);
}

test "Page plain start_x and end_x multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world\r\ntest case\r\nfoo bar");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;
    formatter.end_y = 3;
    formatter.end_x = 4;

    const state = try formatter.formatWithState(&builder.writer);
    // First row: "world" (start_x=6 to end of row)
    // Second row: "test case" (full row)
    // Third row: "foo " (start to end_x=4)
    try testing.expectEqualStrings("world\r\ntest case\r\nfoo", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 1), state.rows);
    try testing.expectEqual(@as(usize, 1), state.cells);
}

test "Page plain start_x out of bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 100;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
}

test "Page plain end_x greater than cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.end_x = 100;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain end_x less than start_x single row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 10;
    formatter.end_y = 1;
    formatter.end_x = 5;

    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("", builder.writer.buffered());
    try testing.expectEqual(@as(usize, 0), state.rows);
    try testing.expectEqual(@as(usize, 0), state.cells);
}

test "Page plain start_y non-zero ignores trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 1;
    formatter.trailing_state = .{ .rows = 5, .cells = 10 };

    const state = try formatter.formatWithState(&builder.writer);
    // Should NOT output the 5 newlines from trailing_state because start_y is non-zero
    try testing.expectEqualStrings("world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows - 1), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain start_x non-zero ignores trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_x = 6;
    formatter.trailing_state = .{ .rows = 2, .cells = 8 };

    const state = try formatter.formatWithState(&builder.writer);
    // Should NOT output the 2 newlines or 8 spaces from trailing_state because start_x is non-zero
    try testing.expectEqualStrings("world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 11), state.cells);
}

test "Page plain start_y and start_x zero uses trailing state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    var formatter: PageFormatter = .init(page, .plain);
    formatter.start_y = 0;
    formatter.start_x = 0;
    formatter.trailing_state = .{ .rows = 2, .cells = 0 };

    const state = try formatter.formatWithState(&builder.writer);
    // SHOULD output the 2 newlines from trailing_state because both start_y and start_x are 0
    try testing.expectEqualStrings("\r\n\r\nhello", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 5), state.cells);
}

test "Page plain single line with styling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello, \x1b[1mworld\x1b[0m");

    // Verify we have only a single page
    const pages = &t.screen.pages;
    try testing.expect(pages.pages.first != null);
    try testing.expect(pages.pages.first == pages.pages.last);

    // Create the formatter
    const page = &pages.pages.last.?.data;
    const formatter: PageFormatter = .init(page, .plain);

    // Verify output
    const state = try formatter.formatWithState(&builder.writer);
    try testing.expectEqualStrings("hello, world", builder.writer.buffered());
    try testing.expectEqual(@as(usize, page.size.rows), state.rows);
    try testing.expectEqual(@as(usize, page.size.cols - 12), state.cells);
}

test "Page VT single line plain text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello", builder.writer.buffered());
}

test "Page VT single line with bold" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b[1mhello\x1b[0m");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello", builder.writer.buffered());
}

test "Page VT multiple styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b[1mhello \x1b[3mworld\x1b[0m");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello \x1b[0m\x1b[1m\x1b[3mworld", builder.writer.buffered());
}

test "Page VT with foreground color" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b[31mred\x1b[0m");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[38;5;1mred", builder.writer.buffered());
}

test "Page VT multi-line with styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b[1mfirst\x1b[0m\r\n\x1b[3msecond\x1b[0m");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[1mfirst\r\n\x1b[0m\x1b[3msecond", builder.writer.buffered());
}

test "Page VT duplicate style not emitted twice" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("\x1b[1mhel\x1b[1mlo\x1b[0m");

    const pages = &t.screen.pages;
    const page = &pages.pages.last.?.data;

    const formatter: PageFormatter = .init(page, .vt);
    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("\x1b[0m\x1b[1mhello", builder.writer.buffered());
}

test "PageList plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello, world");

    const formatter: PageListFormatter = .init(&t.screen.pages, .plain);
    try builder.writer.print("{f}", .{formatter});
    try testing.expectEqualStrings("hello, world", builder.writer.buffered());
}

test "PageList plain spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screen.pages;
    const first_page_rows = pages.pages.first.?.data.capacity.rows;

    // Fill the first page almost completely
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("page one");

    // Verify we're still on one page
    try testing.expect(pages.pages.first == pages.pages.last);

    // Add one more newline to push content to a second page
    try s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);

    // Write content on the second page
    try s.nextSlice("page two");

    // Format the entire PageList
    var formatter: PageListFormatter = .init(pages, .plain);
    try formatter.format(&builder.writer);
    const output = std.mem.trimStart(u8, builder.writer.buffered(), "\r\n");
    try testing.expectEqualStrings("page one\r\npage two", output);
}

test "PageList soft-wrapped line spanning two pages without unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screen.pages;
    const first_page_rows = pages.pages.first.?.data.capacity.rows;

    // Fill the first page with soft-wrapped content
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("hello world test");

    // Verify we're on two pages due to wrapping
    try testing.expect(pages.pages.first != pages.pages.last);

    // Format without unwrap - should show line breaks
    var formatter: PageListFormatter = .init(pages, .plain);
    try formatter.format(&builder.writer);
    const output = std.mem.trimStart(u8, builder.writer.buffered(), "\r\n");
    try testing.expectEqualStrings("hello worl\r\nd test", output);
}

test "PageList soft-wrapped line spanning two pages with unwrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screen.pages;
    const first_page_rows = pages.pages.first.?.data.capacity.rows;

    // Fill the first page with soft-wrapped content
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("hello world test");

    // Verify we're on two pages due to wrapping
    try testing.expect(pages.pages.first != pages.pages.last);

    // Format with unwrap - should join the wrapped lines
    var formatter: PageListFormatter = .init(pages, .{ .emit = .plain, .unwrap = true });
    try formatter.format(&builder.writer);
    const output = std.mem.trimStart(u8, builder.writer.buffered(), "\r\n");
    try testing.expectEqualStrings("hello world test", output);
}

test "PageList VT spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screen.pages;
    const first_page_rows = pages.pages.first.?.data.capacity.rows;

    // Fill the first page almost completely
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("\x1b[1mpage one");

    // Verify we're still on one page
    try testing.expect(pages.pages.first == pages.pages.last);

    // Add one more newline to push content to a second page
    try s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);

    // New content is still styled
    try s.nextSlice("page two");

    // Format the entire PageList with VT
    var formatter: PageListFormatter = .init(pages, .vt);
    try formatter.format(&builder.writer);
    const output = std.mem.trimStart(u8, builder.writer.buffered(), "\r\n");
    try testing.expectEqualStrings("\x1b[0m\x1b[1mpage one\r\n\x1b[0m\x1b[1mpage two", output);
}

test "PageList plain with x offset on single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world\r\ntest case\r\nfoo bar");

    const pages = &t.screen.pages;
    const node = pages.pages.first.?;

    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = node, .y = 0, .x = 6 };
    formatter.bottom_right = .{ .node = node, .y = 2, .x = 3 };

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("world\r\ntest case\r\nfoo", builder.writer.buffered());
}

test "PageList plain with x offset spanning two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screen.pages;
    const first_page_rows = pages.pages.first.?.data.capacity.rows;

    // Fill first page almost completely
    for (0..first_page_rows - 1) |_| try s.nextSlice("\r\n");
    try s.nextSlice("hello world");

    // Verify we're still on one page
    try testing.expect(pages.pages.first == pages.pages.last);

    // Push to second page
    try s.nextSlice("\r\n");
    try testing.expect(pages.pages.first != pages.pages.last);

    try s.nextSlice("foo bar test");

    const first_node = pages.pages.first.?;
    const last_node = pages.pages.last.?;

    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = first_node, .y = first_node.data.size.rows - 1, .x = 6 };
    formatter.bottom_right = .{ .node = last_node, .y = 1, .x = 3 };

    try formatter.format(&builder.writer);
    const output = std.mem.trimStart(u8, builder.writer.buffered(), "\r\n");
    try testing.expectEqualStrings("world\r\nfoo", output);
}

test "PageList plain with start_x only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world");

    const pages = &t.screen.pages;
    const node = pages.pages.first.?;

    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.top_left = .{ .node = node, .y = 0, .x = 6 };

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("world", builder.writer.buffered());
}

test "PageList plain with end_x only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello world\r\ntest");

    const pages = &t.screen.pages;
    const node = pages.pages.first.?;

    var formatter: PageListFormatter = .init(pages, .plain);
    formatter.bottom_right = .{ .node = node, .y = 1, .x = 2 };

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello world\r\ntes", builder.writer.buffered());
}

test "TerminalFormatter plain no selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld");

    const formatter: TerminalFormatter = .init(&t, .plain);

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
}

test "TerminalFormatter vt with palette" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Modify some palette colors using VT sequences
    try s.nextSlice("\x1b]4;0;rgb:12/34/56\x1b\\");
    try s.nextSlice("\x1b]4;1;rgb:ab/cd/ef\x1b\\");
    try s.nextSlice("\x1b]4;255;rgb:ff/00/ff\x1b\\");
    try s.nextSlice("test");

    const formatter: TerminalFormatter = .init(&t, .vt);

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify the palettes match
    try testing.expectEqual(t.color_palette.colors[0], t2.color_palette.colors[0]);
    try testing.expectEqual(t.color_palette.colors[1], t2.color_palette.colors[1]);
    try testing.expectEqual(t.color_palette.colors[255], t2.color_palette.colors[255]);
}

test "TerminalFormatter with selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("line1\r\nline2\r\nline3");

    var formatter: TerminalFormatter = .init(&t, .plain);
    formatter.content = .{ .selection = .init(
        t.screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        t.screen.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ) };

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("line2", builder.writer.buffered());
}

test "Screen plain single line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello, world");

    const formatter: ScreenFormatter = .init(&t.screen, .plain);

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello, world", builder.writer.buffered());
}

test "Screen plain multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("hello\r\nworld");

    const formatter: ScreenFormatter = .init(&t.screen, .plain);

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("hello\r\nworld", builder.writer.buffered());
}

test "Screen plain with selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    try s.nextSlice("line1\r\nline2\r\nline3");

    var formatter: ScreenFormatter = .init(&t.screen, .plain);
    formatter.content = .{ .selection = .init(
        t.screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        t.screen.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ) };

    try formatter.format(&builder.writer);
    try testing.expectEqualStrings("line2", builder.writer.buffered());
}

test "Screen vt with cursor position" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Position cursor at a specific location
    try s.nextSlice("hello\r\nworld");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.cursor = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify cursor positions match
    try testing.expectEqual(t.screen.cursor.x, t2.screen.cursor.x);
    try testing.expectEqual(t.screen.cursor.y, t2.screen.cursor.y);
}

test "Screen vt with style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set some style attributes
    try s.nextSlice("\x1b[1;31mhello");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.style = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify styles match
    try testing.expect(t.screen.cursor.style.eql(t2.screen.cursor.style));
}

test "Screen vt with hyperlink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set a hyperlink
    try s.nextSlice("\x1b]8;;http://example.com\x1b\\hello");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.hyperlink = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify hyperlinks match
    const has_link1 = t.screen.cursor.hyperlink != null;
    const has_link2 = t2.screen.cursor.hyperlink != null;
    try testing.expectEqual(has_link1, has_link2);

    if (has_link1) {
        const link1 = t.screen.cursor.hyperlink.?;
        const link2 = t2.screen.cursor.hyperlink.?;
        try testing.expectEqualStrings(link1.uri, link2.uri);
    }
}

test "Screen vt with protection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Enable protection mode
    try s.nextSlice("\x1b[1\"qhello");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.protection = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify protection state matches
    try testing.expectEqual(t.screen.cursor.protected, t2.screen.cursor.protected);
}

test "Screen vt with kitty keyboard" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set kitty keyboard flags (disambiguate + report_events = 3)
    try s.nextSlice("\x1b[=3;1uhello");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.kitty_keyboard = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify kitty keyboard state matches
    const flags1 = t.screen.kitty_keyboard.current().int();
    const flags2 = t2.screen.kitty_keyboard.current().int();
    try testing.expectEqual(flags1, flags2);
}

test "Screen vt with charsets" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set G0 to DEC special and shift to G1
    try s.nextSlice("\x1b(0\x0ehello");

    var formatter: ScreenFormatter = .init(&t.screen, .vt);
    formatter.extra.charsets = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify charset state matches
    try testing.expectEqual(t.screen.charset.gl, t2.screen.charset.gl);
    try testing.expectEqual(t.screen.charset.gr, t2.screen.charset.gr);
    try testing.expectEqual(
        t.screen.charset.charsets.get(.G0),
        t2.screen.charset.charsets.get(.G0),
    );
}

test "Terminal vt with scrolling region" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set scrolling region: top=5, bottom=20
    try s.nextSlice("\x1b[6;21rhello");

    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.scrolling_region = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify scrolling regions match
    try testing.expectEqual(t.scrolling_region.top, t2.scrolling_region.top);
    try testing.expectEqual(t.scrolling_region.bottom, t2.scrolling_region.bottom);
    try testing.expectEqual(t.scrolling_region.left, t2.scrolling_region.left);
    try testing.expectEqual(t.scrolling_region.right, t2.scrolling_region.right);
}

test "Terminal vt with modes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Enable some modes that differ from defaults
    try s.nextSlice("\x1b[?2004h"); // Bracketed paste
    try s.nextSlice("\x1b[?1000h"); // Mouse event normal
    try s.nextSlice("\x1b[?7l"); // Disable wraparound (default is true)
    try s.nextSlice("hello");

    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.modes = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify modes match
    try testing.expectEqual(t.modes.get(.bracketed_paste), t2.modes.get(.bracketed_paste));
    try testing.expectEqual(t.modes.get(.mouse_event_normal), t2.modes.get(.mouse_event_normal));
    try testing.expectEqual(t.modes.get(.wraparound), t2.modes.get(.wraparound));
}

test "Terminal vt with tabstops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Clear all tabs and set custom tabstops
    try s.nextSlice("\x1b[3g"); // Clear all tabs
    try s.nextSlice("\x1b[5G\x1bH"); // Set tab at column 5
    try s.nextSlice("\x1b[15G\x1bH"); // Set tab at column 15
    try s.nextSlice("\x1b[30G\x1bH"); // Set tab at column 30
    try s.nextSlice("hello");

    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.tabstops = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify tabstops match (columns are 0-indexed in the API)
    try testing.expectEqual(t.tabstops.get(4), t2.tabstops.get(4));
    try testing.expectEqual(t.tabstops.get(14), t2.tabstops.get(14));
    try testing.expectEqual(t.tabstops.get(29), t2.tabstops.get(29));
    try testing.expect(t2.tabstops.get(4)); // Column 5 (1-indexed)
    try testing.expect(t2.tabstops.get(14)); // Column 15 (1-indexed)
    try testing.expect(t2.tabstops.get(29)); // Column 30 (1-indexed)
    try testing.expect(!t2.tabstops.get(8)); // Not a tab
}

test "Terminal vt with keyboard modes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set modify other keys mode 2
    try s.nextSlice("\x1b[>4;2m");
    try s.nextSlice("hello");

    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.keyboard = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify keyboard mode matches
    try testing.expectEqual(t.flags.modify_other_keys_2, t2.flags.modify_other_keys_2);
    try testing.expect(t2.flags.modify_other_keys_2);
}

test "Terminal vt with pwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Set pwd using OSC 7
    try s.nextSlice("\x1b]7;file://host/home/user\x1b\\hello");

    var formatter: TerminalFormatter = .init(&t, .vt);
    formatter.extra.pwd = true;

    try formatter.format(&builder.writer);
    const output = builder.writer.buffered();

    // Create a second terminal and apply the output
    var t2 = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t2.deinit(alloc);

    var s2 = t2.vtStream();
    defer s2.deinit();

    try s2.nextSlice(output);

    // Verify pwd matches
    try testing.expectEqualStrings(t.pwd.items, t2.pwd.items);
}
