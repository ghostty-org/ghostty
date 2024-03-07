const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const unicode = @import("../unicode/main.zig");
const Selection = @import("Selection.zig");
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const Cell = pagepkg.Cell;
const Pin = PageList.Pin;

/// The general purpose allocator to use for all memory allocations.
/// Unfortunately some screen operations do require allocation.
alloc: Allocator,

/// The list of pages in the screen.
pages: PageList,

/// Special-case where we want no scrollback whatsoever. We have to flag
/// this because max_size 0 in PageList gets rounded up to two pages so
/// we can always have an active screen.
no_scrollback: bool = false,

/// The current cursor position
cursor: Cursor,

/// The saved cursor
saved_cursor: ?SavedCursor = null,

/// The selection for this screen (if any).
//selection: ?Selection = null,
selection: ?void = null,

/// The charset state
charset: CharsetState = .{},

/// The current or most recent protected mode. Once a protection mode is
/// set, this will never become "off" again until the screen is reset.
/// The current state of whether protection attributes should be set is
/// set on the Cell pen; this is only used to determine the most recent
/// protection mode since some sequences such as ECH depend on this.
protected_mode: ansi.ProtectedMode = .off,

/// The kitty keyboard settings.
kitty_keyboard: kitty.KeyFlagStack = .{},

/// Kitty graphics protocol state.
kitty_images: kitty.graphics.ImageStorage = .{},

/// The cursor position.
pub const Cursor = struct {
    // The x/y position within the viewport.
    x: size.CellCountInt,
    y: size.CellCountInt,

    /// The visual style of the cursor. This defaults to block because
    /// it has to default to something, but users of this struct are
    /// encouraged to set their own default.
    cursor_style: CursorStyle = .block,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    /// The protected mode state of the cursor. If this is true then
    /// all new characters printed will have the protected state set.
    protected: bool = false,

    /// The currently active style. This is the concrete style value
    /// that should be kept up to date. The style ID to use for cell writing
    /// is below.
    style: style.Style = .{},

    /// The currently active style ID. The style is page-specific so when
    /// we change pages we need to ensure that we update that page with
    /// our style when used.
    style_id: style.Id = style.default_id,
    style_ref: ?*size.CellCountInt = null,

    /// The pointers into the page list where the cursor is currently
    /// located. This makes it faster to move the cursor.
    page_pin: *PageList.Pin,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
};

/// The visual style of the cursor. Whether or not it blinks
/// is determined by mode 12 (modes.zig). This mode is synchronized
/// with CSI q, the same as xterm.
pub const CursorStyle = enum { bar, block, underline };

/// Saved cursor state.
pub const SavedCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    style: style.Style,
    protected: bool,
    pending_wrap: bool,
    origin: bool,
    charset: CharsetState,
};

/// State required for all charset operations.
pub const CharsetState = struct {
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

/// Initialize a new screen.
///
/// max_scrollback is the amount of scrollback to keep in bytes. This
/// will be rounded UP to the nearest page size because our minimum allocation
/// size is that anyways.
///
/// If max scrollback is 0, then no scrollback is kept at all.
pub fn init(
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
) !Screen {
    // Initialize our backing pages.
    var pages = try PageList.init(alloc, cols, rows, max_scrollback);
    errdefer pages.deinit();

    // Create our tracked pin for the cursor.
    const page_pin = try pages.trackPin(.{ .page = pages.pages.first.? });
    errdefer pages.untrackPin(page_pin);
    const page_rac = page_pin.rowAndCell();

    return .{
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = max_scrollback == 0,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        },
    };
}

pub fn deinit(self: *Screen) void {
    self.kitty_images.deinit(self.alloc, self);
    self.pages.deinit();
}

/// Clone the screen.
///
/// This will copy:
///
///   - Screen dimensions
///   - Screen data (cell state, etc.) for the region
///
/// Anything not mentioned above is NOT copied. Some of this is for
/// very good reason:
///
///   - Kitty images have a LOT of data. This is not efficient to copy.
///     Use a lock and access the image data. The dirty bit is there for
///     a reason.
///   - Cursor location can be expensive to calculate with respect to the
///     specified region. It is faster to grab the cursor from the old
///     screen and then move it to the new screen.
///
/// If not mentioned above, then there isn't a specific reason right now
/// to not copy some data other than we probably didn't need it and it
/// isn't necessary for screen coherency.
///
/// Other notes:
///
///   - The viewport will always be set to the active area of the new
///     screen. This is the bottom "rows" rows.
///   - If the clone region is smaller than a viewport area, blanks will
///     be filled in at the bottom.
///
pub fn clone(
    self: *const Screen,
    alloc: Allocator,
    top: point.Point,
    bot: ?point.Point,
) !Screen {
    return try self.clonePool(alloc, null, top, bot);
}

/// Same as clone but you can specify a custom memory pool to use for
/// the screen.
pub fn clonePool(
    self: *const Screen,
    alloc: Allocator,
    pool: ?*PageList.MemoryPool,
    top: point.Point,
    bot: ?point.Point,
) !Screen {
    var pages = if (pool) |p|
        try self.pages.clonePool(p, top, bot)
    else
        try self.pages.clone(alloc, top, bot);
    errdefer pages.deinit();

    return .{
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = self.no_scrollback,

        // TODO: let's make this reasonble
        .cursor = undefined,
    };
}

pub fn cursorCellRight(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x + n < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + n);
}

pub fn cursorCellLeft(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x >= n);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell - n);
}

pub fn cursorCellEndOfPrev(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.y > 0);

    var page_pin = self.cursor.page_pin.up(1).?;
    page_pin.x = self.pages.cols - 1;
    const page_rac = page_pin.rowAndCell();
    return page_rac.cell;
}

/// Move the cursor right. This is a specialized function that is very fast
/// if the caller can guarantee we have space to move right (no wrapping).
pub fn cursorRight(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x + n < self.pages.cols);

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell + n);
    self.cursor.page_pin.x += n;
    self.cursor.x += n;
}

/// Move the cursor left.
pub fn cursorLeft(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x >= n);

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell - n);
    self.cursor.page_pin.x -= n;
    self.cursor.x -= n;
}

/// Move the cursor up.
///
/// Precondition: The cursor is not at the top of the screen.
pub fn cursorUp(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y >= n);

    const page_pin = self.cursor.page_pin.up(n).?;
    const page_rac = page_pin.rowAndCell();
    self.cursor.page_pin.* = page_pin;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    self.cursor.y -= n;
}

pub fn cursorRowUp(self: *Screen, n: size.CellCountInt) *pagepkg.Row {
    assert(self.cursor.y >= n);

    const page_pin = self.cursor.page_pin.up(n).?;
    const page_rac = page_pin.rowAndCell();
    return page_rac.row;
}

/// Move the cursor down.
///
/// Precondition: The cursor is not at the bottom of the screen.
pub fn cursorDown(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y + n < self.pages.rows);

    // We move the offset into our page list to the next row and then
    // get the pointers to the row/cell and set all the cursor state up.
    const page_pin = self.cursor.page_pin.down(n).?;
    const page_rac = page_pin.rowAndCell();
    self.cursor.page_pin.* = page_pin;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;

    // Y of course increases
    self.cursor.y += n;
}

/// Move the cursor to some absolute horizontal position.
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);

    self.cursor.page_pin.x = x;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}

/// Move the cursor to some absolute position.
pub fn cursorAbsolute(self: *Screen, x: size.CellCountInt, y: size.CellCountInt) void {
    assert(x < self.pages.cols);
    assert(y < self.pages.rows);

    var page_pin = if (y < self.cursor.y)
        self.cursor.page_pin.up(self.cursor.y - y).?
    else if (y > self.cursor.y)
        self.cursor.page_pin.down(y - self.cursor.y).?
    else
        self.cursor.page_pin.*;
    page_pin.x = x;
    const page_rac = page_pin.rowAndCell();
    self.cursor.page_pin.* = page_pin;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
    self.cursor.y = y;
}

/// Reloads the cursor pointer information into the screen. This is expensive
/// so it should only be done in cases where the pointers are invalidated
/// in such a way that its difficult to recover otherwise.
pub fn cursorReload(self: *Screen) void {
    // Our tracked pin is ALWAYS accurate, so we derive the active
    // point from the pin. If this returns null it means our pin
    // points outside the active area. In that case, we update the
    // pin to be the top-left.
    const pt: point.Point = self.pages.pointFromPin(
        .active,
        self.cursor.page_pin.*,
    ) orelse reset: {
        const pin = self.pages.pin(.{ .active = .{} }).?;
        self.cursor.page_pin.* = pin;
        break :reset self.pages.pointFromPin(.active, pin).?;
    };

    self.cursor.x = @intCast(pt.active.x);
    self.cursor.y = @intCast(pt.active.y);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Scroll the active area and keep the cursor at the bottom of the screen.
/// This is a very specialized function but it keeps it fast.
pub fn cursorDownScroll(self: *Screen) !void {
    assert(self.cursor.y == self.pages.rows - 1);

    // If we have no scrollback, then we shift all our rows instead.
    if (self.no_scrollback) {
        // Erase rows will shift our rows up
        self.pages.eraseRows(.{ .active = .{} }, .{ .active = .{} });

        // We need to move our cursor down one because eraseRows will
        // preserve our pin directly and we're erasing one row.
        const page_pin = self.cursor.page_pin.down(1).?;
        const page_rac = page_pin.rowAndCell();
        self.cursor.page_pin.* = page_pin;
        self.cursor.page_row = page_rac.row;
        self.cursor.page_cell = page_rac.cell;

        // Erase rows does NOT clear the cells because in all other cases
        // we never write those rows again. Active erasing is a bit
        // different so we manually clear our one row.
        self.clearCells(
            &page_pin.page.data,
            self.cursor.page_row,
            page_pin.page.data.getCells(self.cursor.page_row),
        );
    } else {
        // Grow our pages by one row. The PageList will handle if we need to
        // allocate, prune scrollback, whatever.
        _ = try self.pages.grow();
        const page_pin = self.cursor.page_pin.down(1).?;
        const page_rac = page_pin.rowAndCell();
        self.cursor.page_pin.* = page_pin;
        self.cursor.page_row = page_rac.row;
        self.cursor.page_cell = page_rac.cell;

        // Clear the new row so it gets our bg color. We only do this
        // if we have a bg color at all.
        if (self.cursor.style.bg_color != .none) {
            self.clearCells(
                &page_pin.page.data,
                self.cursor.page_row,
                page_pin.page.data.getCells(self.cursor.page_row),
            );
        }
    }

    // The newly created line needs to be styled according to the bg color
    // if it is set.
    if (self.cursor.style_id != style.default_id) {
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

/// Move the cursor down if we're not at the bottom of the screen. Otherwise
/// scroll. Currently only used for testing.
fn cursorDownOrScroll(self: *Screen) !void {
    if (self.cursor.y + 1 < self.pages.rows) {
        self.cursorDown(1);
    } else {
        try self.cursorDownScroll();
    }
}

/// Options for scrolling the viewport of the terminal grid. The reason
/// we have this in addition to PageList.Scroll is because we have additional
/// scroll behaviors that are not part of the PageList.Scroll enum.
pub const Scroll = union(enum) {
    /// For all of these, see PageList.Scroll.
    active,
    top,
    delta_row: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scroll(self: *Screen, behavior: Scroll) void {
    // No matter what, scrolling marks our image state as dirty since
    // it could move placements. If there are no placements or no images
    // this is still a very cheap operation.
    self.kitty_images.dirty = true;

    switch (behavior) {
        .active => self.pages.scroll(.{ .active = {} }),
        .top => self.pages.scroll(.{ .top = {} }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
    }
}

/// See PageList.scrollClear. In addition to that, we reset the cursor
/// to be on top.
pub fn scrollClear(self: *Screen) !void {
    try self.pages.scrollClear();
    self.cursorReload();

    // No matter what, scrolling marks our image state as dirty since
    // it could move placements. If there are no placements or no images
    // this is still a very cheap operation.
    self.kitty_images.dirty = true;
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub fn viewportIsBottom(self: Screen) bool {
    return self.pages.viewport == .active;
}

/// Erase the region specified by tl and br, inclusive. This will physically
/// erase the rows meaning the memory will be reclaimed (if the underlying
/// page is empty) and other rows will be shifted up.
pub fn eraseRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
) void {
    // Erase the rows
    self.pages.eraseRows(tl, bl);

    // Just to be safe, reset our cursor since it is possible depending
    // on the points that our active area shifted so our pointers are
    // invalid.
    self.cursorReload();
}

// Clear the region specified by tl and bl, inclusive. Cleared cells are
// colored with the current style background color. This will clear all
// cells in the rows.
//
// If protected is true, the protected flag will be respected and only
// unprotected cells will be cleared. Otherwise, all cells will be cleared.
pub fn clearRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
    protected: bool,
) void {
    var it = self.pages.pageIterator(.right_down, tl, bl);
    while (it.next()) |chunk| {
        for (chunk.rows()) |*row| {
            const cells_offset = row.cells;
            const cells_multi: [*]Cell = row.cells.ptr(chunk.page.data.memory);
            const cells = cells_multi[0..self.pages.cols];

            // Clear all cells
            if (protected) {
                self.clearUnprotectedCells(&chunk.page.data, row, cells);
            } else {
                self.clearCells(&chunk.page.data, row, cells);
            }

            // Reset our row to point to the proper memory but everything
            // else is zeroed.
            row.* = .{ .cells = cells_offset };
        }
    }
}

/// Clear the cells with the blank cell. This takes care to handle
/// cleaning up graphemes and styles.
pub fn clearCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    // If this row has graphemes, then we need go through a slow path
    // and delete the cell graphemes.
    if (row.grapheme) {
        for (cells) |*cell| {
            if (cell.hasGrapheme()) page.clearGrapheme(row, cell);
        }
    }

    if (row.styled) {
        for (cells) |*cell| {
            if (cell.style_id == style.default_id) continue;

            // Fast-path, the style ID matches, in this case we just update
            // our own ref and continue. We never delete because our style
            // is still active.
            if (cell.style_id == self.cursor.style_id) {
                self.cursor.style_ref.?.* -= 1;
                continue;
            }

            // Slow path: we need to lookup this style so we can decrement
            // the ref count. Since we've already loaded everything, we also
            // just go ahead and GC it if it reaches zero, too.
            if (page.styles.lookupId(page.memory, cell.style_id)) |prev_style| {
                // Below upsert can't fail because it should already be present
                const md = page.styles.upsert(page.memory, prev_style.*) catch unreachable;
                assert(md.ref > 0);
                md.ref -= 1;
                if (md.ref == 0) page.styles.remove(page.memory, cell.style_id);
            }
        }

        // If we have no left/right scroll region we can be sure that
        // the row is no longer styled.
        if (cells.len == self.pages.cols) row.styled = false;
    }

    @memset(cells, self.blankCell());
}

/// Clear cells but only if they are not protected.
pub fn clearUnprotectedCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    for (cells) |*cell| {
        if (cell.protected) continue;
        const cell_multi: [*]Cell = @ptrCast(cell);
        self.clearCells(page, row, cell_multi[0..1]);
    }
}

/// Returns the blank cell to use when doing terminal operations that
/// require preserving the bg color.
fn blankCell(self: *const Screen) Cell {
    if (self.cursor.style_id == style.default_id) return .{};
    return self.cursor.style.bgCell() orelse .{};
}

/// Resize the screen. The rows or cols can be bigger or smaller.
///
/// This will reflow soft-wrapped text. If the screen size is getting
/// smaller and the maximum scrollback size is exceeded, data will be
/// lost from the top of the scrollback.
///
/// If this returns an error, the screen is left in a likely garbage state.
/// It is very hard to undo this operation without blowing up our memory
/// usage. The only way to recover is to reset the screen. The only way
/// this really fails is if page allocation is required and fails, which
/// probably means the system is in trouble anyways. I'd like to improve this
/// in the future but it is not a priority particularly because this scenario
/// (resize) is difficult.
pub fn resize(
    self: *Screen,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    try self.resizeInternal(cols, rows, true);
}

/// Resize the screen without any reflow. In this mode, columns/rows will
/// be truncated as they are shrunk. If they are grown, the new space is filled
/// with zeros.
pub fn resizeWithoutReflow(
    self: *Screen,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    try self.resizeInternal(cols, rows, false);
}

/// Resize the screen.
// TODO: replace resize and resizeWithoutReflow with this.
fn resizeInternal(
    self: *Screen,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    reflow: bool,
) !void {
    // No matter what we mark our image state as dirty
    self.kitty_images.dirty = true;

    // Perform the resize operation. This will update cursor by reference.
    try self.pages.resize(.{
        .rows = rows,
        .cols = cols,
        .reflow = reflow,
        .cursor = .{ .x = self.cursor.x, .y = self.cursor.y },
    });

    // If we have no scrollback and we shrunk our rows, we must explicitly
    // erase our history. This is beacuse PageList always keeps at least
    // a page size of history.
    if (self.no_scrollback) {
        self.pages.eraseRows(.{ .history = .{} }, null);
    }

    // If our cursor was updated, we do a full reload so all our cursor
    // state is correct.
    self.cursorReload();
}

/// Set a style attribute for the current cursor.
///
/// This can cause a page split if the current page cannot fit this style.
/// This is the only scenario an error return is possible.
pub fn setAttribute(self: *Screen, attr: sgr.Attribute) !void {
    switch (attr) {
        .unset => {
            self.cursor.style = .{};
        },

        .bold => {
            self.cursor.style.flags.bold = true;
        },

        .reset_bold => {
            // Bold and faint share the same SGR code for this
            self.cursor.style.flags.bold = false;
            self.cursor.style.flags.faint = false;
        },

        .italic => {
            self.cursor.style.flags.italic = true;
        },

        .reset_italic => {
            self.cursor.style.flags.italic = false;
        },

        .faint => {
            self.cursor.style.flags.faint = true;
        },

        .underline => |v| {
            self.cursor.style.flags.underline = v;
        },

        .reset_underline => {
            self.cursor.style.flags.underline = .none;
        },

        .underline_color => |rgb| {
            self.cursor.style.underline_color = .{ .rgb = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            } };
        },

        .@"256_underline_color" => |idx| {
            self.cursor.style.underline_color = .{ .palette = idx };
        },

        .reset_underline_color => {
            self.cursor.style.underline_color = .none;
        },

        .blink => {
            self.cursor.style.flags.blink = true;
        },

        .reset_blink => {
            self.cursor.style.flags.blink = false;
        },

        .inverse => {
            self.cursor.style.flags.inverse = true;
        },

        .reset_inverse => {
            self.cursor.style.flags.inverse = false;
        },

        .invisible => {
            self.cursor.style.flags.invisible = true;
        },

        .reset_invisible => {
            self.cursor.style.flags.invisible = false;
        },

        .strikethrough => {
            self.cursor.style.flags.strikethrough = true;
        },

        .reset_strikethrough => {
            self.cursor.style.flags.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.cursor.style.fg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .direct_color_bg => |rgb| {
            self.cursor.style.bg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .@"8_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .reset_fg => self.cursor.style.fg_color = .none,

        .reset_bg => self.cursor.style.bg_color = .none,

        .@"8_bright_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bright_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"256_fg" => |idx| {
            self.cursor.style.fg_color = .{ .palette = idx };
        },

        .@"256_bg" => |idx| {
            self.cursor.style.bg_color = .{ .palette = idx };
        },

        .unknown => return,
    }

    try self.manualStyleUpdate();
}

/// Call this whenever you manually change the cursor style.
pub fn manualStyleUpdate(self: *Screen) !void {
    var page = &self.cursor.page_pin.page.data;

    // Remove our previous style if is unused.
    if (self.cursor.style_ref) |ref| {
        if (ref.* == 0) {
            page.styles.remove(page.memory, self.cursor.style_id);
        }
    }

    // If our new style is the default, just reset to that
    if (self.cursor.style.default()) {
        self.cursor.style_id = 0;
        self.cursor.style_ref = null;
        return;
    }

    // After setting the style, we need to update our style map.
    // Note that we COULD lazily do this in print. We should look into
    // if that makes a meaningful difference. Our priority is to keep print
    // fast because setting a ton of styles that do nothing is uncommon
    // and weird.
    const md = try page.styles.upsert(page.memory, self.cursor.style);
    self.cursor.style_id = md.id;
    self.cursor.style_ref = &md.ref;
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
// pub fn selectionString(
//     self: *Screen,
//     alloc: Allocator,
//     sel: Selection,
//     trim: bool,
// ) ![:0]const u8 {
//     _ = self;
//     _ = alloc;
//     _ = sel;
//     _ = trim;
//     @panic("TODO");
// }

/// Select the line under the given point. This will select across soft-wrapped
/// lines and will omit the leading and trailing whitespace. If the point is
/// over whitespace but the line has non-whitespace characters elsewhere, the
/// line will be selected.
pub fn selectLine(self: *Screen, pin: Pin) ?Selection {
    _ = self;

    // Whitespace characters for selection purposes
    const whitespace = &[_]u32{ 0, ' ', '\t' };

    // Get the current point semantic prompt state since that determines
    // boundary conditions too. This makes it so that line selection can
    // only happen within the same prompt state. For example, if you triple
    // click output, but the shell uses spaces to soft-wrap to the prompt
    // then the selection will stop prior to the prompt. See issue #1329.
    const semantic_prompt_state = state: {
        const rac = pin.rowAndCell();
        break :state rac.row.semantic_prompt.promptOrInput();
    };

    // The real start of the row is the first row in the soft-wrap.
    const start_pin: Pin = start_pin: {
        var it = pin.rowIterator(.left_up, null);
        var it_prev: Pin = pin;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (!row.wrap) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }

            // See semantic_prompt_state comment for why
            const current_prompt = row.semantic_prompt.promptOrInput();
            if (current_prompt != semantic_prompt_state) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }

            it_prev = p;
        } else {
            var copy = it_prev;
            copy.x = 0;
            break :start_pin copy;
        }
    };

    // The real end of the row is the final row in the soft-wrap.
    const end_pin: Pin = end_pin: {
        var it = pin.rowIterator(.right_down, null);
        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            // See semantic_prompt_state comment for why
            const current_prompt = row.semantic_prompt.promptOrInput();
            if (current_prompt != semantic_prompt_state) {
                var prev = p.up(1).?;
                prev.x = p.page.data.size.cols - 1;
                break :end_pin prev;
            }

            if (!row.wrap) {
                var copy = p;
                copy.x = p.page.data.size.cols - 1;
                break :end_pin copy;
            }
        }

        return null;
    };

    // Go forward from the start to find the first non-whitespace character.
    const start: Pin = start: {
        var it = start_pin.cellIterator(.right_down, end_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_whitespace) continue;

            break :start p;
        }

        return null;
    };

    // Go backward from the end to find the first non-whitespace character.
    const end: Pin = end: {
        var it = end_pin.cellIterator(.left_up, start_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_whitespace) continue;

            break :end p;
        }

        return null;
    };

    return Selection.init(start, end, false);
}

/// Return the selection for all contents on the screen. Surrounding
/// whitespace is omitted. If there is no selection, this returns null.
pub fn selectAll(self: *Screen) ?Selection {
    const whitespace = &[_]u32{ 0, ' ', '\t' };

    const start: Pin = start: {
        var it = self.pages.cellIterator(
            .right_down,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_whitespace) continue;

            break :start p;
        }

        return null;
    };

    const end: Pin = end: {
        var it = self.pages.cellIterator(
            .left_up,
            .{ .screen = .{} },
            null,
        );
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u32,
                whitespace,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_whitespace) continue;

            break :end p;
        }

        return null;
    };

    return Selection.init(start, end, false);
}

/// Select the word under the given point. A word is any consecutive series
/// of characters that are exclusively whitespace or exclusively non-whitespace.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenario
/// this happens is if the point pt is outside of the written screen space.
pub fn selectWord(self: *Screen, pin: Pin) ?Selection {
    _ = self;

    // Boundary characters for selection purposes
    const boundary = &[_]u32{
        0,
        ' ',
        '\t',
        '\'',
        '"',
        '│',
        '`',
        '|',
        ':',
        ',',
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        '<',
        '>',
    };

    // If our cell is empty we can't select a word, because we can't select
    // areas where the screen is not yet written.
    const start_cell = pin.rowAndCell().cell;
    if (!start_cell.hasText()) return null;

    // Determine if we are a boundary or not to determine what our boundary is.
    const expect_boundary = std.mem.indexOfAny(
        u32,
        boundary,
        &[_]u32{start_cell.content.codepoint},
    ) != null;

    // Go forwards to find our end boundary
    const end: Pin = end: {
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?; // Consume one, our start
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // If we reached an empty cell its always a boundary
            if (!cell.hasText()) break :end prev;

            // If we do not match our expected set, we hit a boundary
            const this_boundary = std.mem.indexOfAny(
                u32,
                boundary,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;

            // If we are going to the next row and it isn't wrapped, we
            // return the previous.
            if (p.x == p.page.data.size.cols - 1 and !rac.row.wrap) {
                break :end p;
            }

            prev = p;
        }

        break :end prev;
    };

    // Go backwards to find our start boundary
    const start: Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?; // Consume one, our start
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // If we are going to the next row and it isn't wrapped, we
            // return the previous.
            if (p.x == p.page.data.size.cols - 1 and !rac.row.wrap) {
                break :start prev;
            }

            // If we reached an empty cell its always a boundary
            if (!cell.hasText()) break :start prev;

            // If we do not match our expected set, we hit a boundary
            const this_boundary = std.mem.indexOfAny(
                u32,
                boundary,
                &[_]u32{cell.content.codepoint},
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;

            prev = p;
        }

        break :start prev;
    };

    return Selection.init(start, end, false);
}

/// Select the command output under the given point. The limits of the output
/// are determined by semantic prompt information provided by shell integration.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenarios
/// this happens is if:
///  - the point pt is outside of the written screen space.
///  - the point pt is on a prompt / input line.
pub fn selectOutput(self: *Screen, pin: Pin) ?Selection {
    _ = self;

    switch (pin.rowAndCell().row.semantic_prompt) {
        .input, .prompt_continuation, .prompt => {
            // Cursor on a prompt line, selection impossible
            return null;
        },

        else => {},
    }

    // Go forwards to find our end boundary
    // We are looking for input start / prompt markers
    const end: Pin = boundary: {
        var it = pin.rowIterator(.right_down, null);
        var it_prev = pin;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            switch (row.semantic_prompt) {
                .input, .prompt_continuation, .prompt => {
                    var copy = it_prev;
                    copy.x = it_prev.page.data.size.cols - 1;
                    break :boundary copy;
                },
                else => {},
            }

            it_prev = p;
        }

        // Find the last non-blank row
        it = it_prev.rowIterator(.left_up, null);
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            const cells = p.page.data.getCells(row);
            if (Cell.hasTextAny(cells)) {
                var copy = p;
                copy.x = p.page.data.size.cols - 1;
                break :boundary copy;
            }
        }

        // In this case it means that all our rows are blank. Let's
        // just return no selection, this is a weird case.
        return null;
    };

    // Go backwards to find our start boundary
    // We are looking for output start markers
    const start: Pin = boundary: {
        var it = pin.rowIterator(.left_up, null);
        var it_prev = pin;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            switch (row.semantic_prompt) {
                .command => break :boundary p,
                else => {},
            }

            it_prev = p;
        }

        break :boundary it_prev;
    };

    return Selection.init(start, end, false);
}

/// Returns the selection bounds for the prompt at the given point. If the
/// point is not on a prompt line, this returns null. Note that due to
/// the underlying protocol, this will only return the y-coordinates of
/// the prompt. The x-coordinates of the start will always be zero and
/// the x-coordinates of the end will always be the last column.
///
/// Note that this feature requires shell integration. If shell integration
/// is not enabled, this will always return null.
pub fn selectPrompt(self: *Screen, pin: Pin) ?Selection {
    _ = self;

    // Ensure that the line the point is on is a prompt.
    const is_known = switch (pin.rowAndCell().row.semantic_prompt) {
        .prompt, .prompt_continuation, .input => true,
        .command => return null,

        // We allow unknown to continue because not all shells output any
        // semantic prompt information for continuation lines. This has the
        // possibility of making this function VERY slow (we look at all
        // scrollback) so we should try to avoid this in the future by
        // setting a flag or something if we have EVER seen a semantic
        // prompt sequence.
        .unknown => false,
    };

    // Find the start of the prompt.
    var saw_semantic_prompt = is_known;
    const start: Pin = start: {
        var it = pin.rowIterator(.left_up, null);
        var it_prev = it.next().?;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            switch (row.semantic_prompt) {
                // A prompt, we continue searching.
                .prompt, .prompt_continuation, .input => saw_semantic_prompt = true,

                // See comment about "unknown" a few lines above. If we have
                // previously seen a semantic prompt then if we see an unknown
                // we treat it as a boundary.
                .unknown => if (saw_semantic_prompt) break :start it_prev,

                // Command output or unknown, definitely not a prompt.
                .command => break :start it_prev,
            }

            it_prev = p;
        }

        break :start it_prev;
    };

    // If we never saw a semantic prompt flag, then we can't trust our
    // start value and we return null. This scenario usually means that
    // semantic prompts aren't enabled via the shell.
    if (!saw_semantic_prompt) return null;

    // Find the end of the prompt.
    const end: Pin = end: {
        var it = pin.rowIterator(.right_down, null);
        var it_prev = it.next().?;
        it_prev.x = it_prev.page.data.size.cols - 1;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;
            switch (row.semantic_prompt) {
                // A prompt, we continue searching.
                .prompt, .prompt_continuation, .input => {},

                // Command output or unknown, definitely not a prompt.
                .command, .unknown => break :end it_prev,
            }

            it_prev = p;
            it_prev.x = it_prev.page.data.size.cols - 1;
        }

        break :end it_prev;
    };

    return Selection.init(start, end, false);
}

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
pub fn dumpString(
    self: *const Screen,
    writer: anytype,
    tl: point.Point,
) !void {
    var blank_rows: usize = 0;

    var iter = self.pages.rowIterator(.right_down, tl, null);
    while (iter.next()) |row_offset| {
        const rac = row_offset.rowAndCell();
        const cells = cells: {
            const cells: [*]pagepkg.Cell = @ptrCast(rac.cell);
            break :cells cells[0..self.pages.cols];
        };

        if (!pagepkg.Cell.hasTextAny(cells)) {
            blank_rows += 1;
            continue;
        }
        if (blank_rows > 0) {
            for (0..blank_rows) |_| try writer.writeByte('\n');
            blank_rows = 0;
        }

        // TODO: handle wrap
        blank_rows += 1;

        var blank_cells: usize = 0;
        for (cells) |*cell| {
            // Skip spacers
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If we have a zero value, then we accumulate a counter. We
            // only want to turn zero values into spaces if we have a non-zero
            // char sometime later.
            if (!cell.hasText()) {
                blank_cells += 1;
                continue;
            }
            if (blank_cells > 0) {
                for (0..blank_cells) |_| try writer.writeByte(' ');
                blank_cells = 0;
            }

            switch (cell.content_tag) {
                .codepoint => {
                    try writer.print("{u}", .{cell.content.codepoint});
                },

                .codepoint_grapheme => {
                    try writer.print("{u}", .{cell.content.codepoint});
                    const cps = row_offset.page.data.lookupGrapheme(cell).?;
                    for (cps) |cp| {
                        try writer.print("{u}", .{cp});
                    }
                },

                else => unreachable,
            }
        }
    }
}

pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder = std.ArrayList(u8).init(alloc);
    defer builder.deinit();
    try self.dumpString(builder.writer(), tl);
    return try builder.toOwnedSlice();
}

/// This is basically a really jank version of Terminal.printString. We
/// have to reimplement it here because we want a way to print to the screen
/// to test it but don't want all the features of Terminal.
pub fn testWriteString(self: *Screen, text: []const u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.pending_wrap = false;
            continue;
        }

        const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
        if (width == 0) {
            @panic("zero-width todo");
        }

        if (self.cursor.pending_wrap) {
            assert(self.cursor.x == self.pages.cols - 1);
            self.cursor.pending_wrap = false;
            self.cursor.page_row.wrap = true;
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            self.cursor.page_row.wrap_continuation = true;
        }

        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = c },
                    .style_id = self.cursor.style_id,
                };

                // If we have a ref-counted style, increase.
                if (self.cursor.style_ref) |ref| {
                    ref.* += 1;
                    self.cursor.page_row.styled = true;
                }
            },

            2 => {
                // Need a wide spacer head
                if (self.cursor.x == self.pages.cols - 1) {
                    self.cursor.page_cell.* = .{
                        .content_tag = .codepoint,
                        .content = .{ .codepoint = 0 },
                        .wide = .spacer_head,
                    };

                    self.cursor.page_row.wrap = true;
                    try self.cursorDownOrScroll();
                    self.cursorHorizontalAbsolute(0);
                    self.cursor.page_row.wrap_continuation = true;
                }

                // Write our wide char
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = c },
                    .style_id = self.cursor.style_id,
                    .wide = .wide,
                };

                // Write our tail
                self.cursorRight(1);
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = 0 },
                    .wide = .spacer_tail,
                };
            },

            else => unreachable,
        }

        if (self.cursor.x + 1 < self.pages.cols) {
            self.cursorRight(1);
        } else {
            self.cursor.pending_wrap = true;
        }
    }
}

test "Screen read and write" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello, world");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello, world", str);
}

test "Screen read and write newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello\nworld");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello\nworld", str);
}

test "Screen read and write scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 2, 1000);
    defer s.deinit();

    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("hello\nworld\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}

test "Screen read and write no scrollback small" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 2, 0);
    defer s.deinit();

    try s.testWriteString("hello\nworld\ntest");
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("world\ntest", str);
    }
}

test "Screen read and write no scrollback large" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 2, 0);
    defer s.deinit();

    for (0..1_000) |i| {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{}\n", .{i});
        try s.testWriteString(str);
    }
    try s.testWriteString("1000");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("999\n1000", str);
    }
}

test "Screen style basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_pin.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
    try testing.expect(s.cursor.style.flags.bold);

    // Set another style, we should still only have one since it was unused
    try s.setAttribute(.{ .italic = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
    try testing.expect(s.cursor.style.flags.italic);
}

test "Screen style reset to default" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_pin.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    // Reset to default
    try s.setAttribute(.{ .reset_bold = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));
}

test "Screen style reset with unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_pin.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    // Reset to default
    try s.setAttribute(.{ .unset = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));
}

test "Screen clearRows active one line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.testWriteString("hello, world");
    s.clearRows(.{ .active = .{} }, null, false);
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows active multi line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.testWriteString("hello\nworld");
    s.clearRows(.{ .active = .{} }, null, false);
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows active styled line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("hello world");
    try s.setAttribute(.{ .unset = {} });

    // We should have one style
    const page = s.cursor.page_pin.page.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    s.clearRows(.{ .active = .{} }, null, false);

    // We should have none because active cleared it
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen eraseRows history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 5, 5, 1000);
    defer s.deinit();

    try s.testWriteString("1\n2\n3\n4\n5\n6");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3\n4\n5\n6", str);
    }

    s.eraseRows(.{ .history = .{} }, null);

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}

test "Screen eraseRows history with more lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 5, 5, 1000);
    defer s.deinit();

    try s.testWriteString("A\nB\nC\n1\n2\n3\n4\n5\n6");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("A\nB\nC\n1\n2\n3\n4\n5\n6", str);
    }

    s.eraseRows(.{ .history = .{} }, null);

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("2\n3\n4\n5\n6", str);
    }
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Scrolling to the bottom does nothing
    s.scroll(.{ .active = {} });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport == .active);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback various cases" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.cursorDownScroll();

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    s.scroll(.{ .delta_row = -1 });
    try testing.expect(s.pages.viewport != .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    s.clearRows(.{ .active = .{} }, null, false);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    s.scroll(.{ .active = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scrollback with multi-row delta" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");

    // Scroll to top
    s.scroll(.{ .top = {} });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down multiple
    s.scroll(.{ .delta_row = 5 });
    try testing.expect(s.pages.viewport == .active);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 50);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = 1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback doesn't move viewport if not at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");

    // First test: we scroll up by 1, so we're not at the bottom anymore.
    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Next, we scroll back down by 1, this grows the scrollback but we
    // shouldn't move.
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Scroll again, this clears scrollback so we should move viewports
    // but still see the same thing since our original view fits.
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }
}

test "Screen: scroll and clear full screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 5);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll and clear partial screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 5);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
}

test "Screen: scroll and clear empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 5);
    defer s.deinit();
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scroll and clear ignore blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursorAbsolute(0, 0);

    // Write and clear
    try s.testWriteString("3ABCD\n");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3ABCD", contents);
    }

    try s.scrollClear();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursorAbsolute(0, 0);
    try s.testWriteString("X");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3ABCD\nX", contents);
    }
}

test "Screen: clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    // Clone
    var s2 = try s.clone(alloc, .{ .active = .{} }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    // Write to s1, should not be in s2
    try s.testWriteString("\n34567");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n34567", contents);
    }
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
}

test "Screen: clone partial" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    // Clone
    var s2 = try s.clone(alloc, .{ .active = .{ .y = 1 } }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }
}

test "Screen: clone basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        var s2 = try s.clone(
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 1 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    {
        var s2 = try s.clone(
            alloc,
            .{ .active = .{ .y = 1 } },
            .{ .active = .{ .y = 2 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: clone empty viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(
            alloc,
            .{ .viewport = .{ .y = 0 } },
            .{ .viewport = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents
        const contents = try s2.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

test "Screen: clone empty active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(
            alloc,
            .{ .active = .{ .y = 0 } },
            .{ .active = .{ .y = 0 } },
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line active with extra space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(
            alloc,
            .{ .active = .{ .y = 0 } },
            null,
        );
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

test "Screen: clear history with no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 3);
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expect(s.pages.viewport == .active);
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: clear history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.pages.viewport == .active);

    // Scroll to top
    s.scroll(.{ .top = {} });
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    s.eraseRows(.{ .history = .{} }, null);
    try testing.expect(s.pages.viewport == .active);
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: clear above cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 3);
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: clear above cursor with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    s.clearRows(
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = s.cursor.y - 1 } },
        false,
    );
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("\n\n6IJKL", contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n\n\n6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Resize
    try s.resizeWithoutReflow(10, 10);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);
    try s.resizeWithoutReflow(10, 2);

    // Since we shrunk, we should adjust our cursor
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = y } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resizeWithoutReflow(6, 2);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = y } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resizeWithoutReflow(10, 7);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(20, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(4, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) more rows with scrollback cursor end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 7, 3, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(7, 10);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 7, 3, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(7, 2);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/1030
test "Screen: resize (no reflow) less rows with empty trailing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try s.scrollClear();
    s.cursorAbsolute(0, 0);
    try s.testWriteString("A\nB");

    const cursor = s.cursor;
    try s.resizeWithoutReflow(5, 2);
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("A\nB", contents);
    }
}

test "Screen: resize (no reflow) more rows with soft wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 3);
    defer s.deinit();
    const str = "1A2B\n3C4E\n5F6G";
    try s.testWriteString(str);

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = y } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }

    // Resize
    try s.resizeWithoutReflow(2, 10);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4E\n5F\n6G";
        try testing.expectEqualStrings(expected, contents);
    }

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = y } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(5, 10);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(5, 10);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Set our cursor to be on the "4"
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint);
    }

    // Resize
    try s.resize(5, 10);

    // Cursor should still be on the "4"
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '4'), list_cell.cell.content.codepoint);
    }

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const cursor = s.cursor;
    try s.resize(10, 3);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/272#issuecomment-1676038963
test "Screen: resize more cols perfect split" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    try s.resize(10, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD2EFGH\n3IJKL", contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) more cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(8, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) less cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    s.scroll(.{ .delta_row = -4 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(4, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("6\n7\n8", contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    // Old implementation doesn't do this but it makes sense to me:
    // {
    //     const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
    //     defer alloc.free(contents);
    //     try testing.expectEqualStrings("2\n3\n4", contents);
    // }
}

test "Screen: resize more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Set one of the rows to be a prompt
    {
        s.cursorAbsolute(0, 1);
        s.cursor.page_row.semantic_prompt = .prompt;
    }

    try s.resize(10, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our one row should still be a semantic prompt, the others should not.
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .unknown);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .prompt);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .unknown);
    }
}

test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(10, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 6, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2\nEFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on the last row
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(10, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should still be on the 3
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint);
    }
}

test "Screen: resize more cols with reflow that forces more wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '2'), list_cell.cell.content.codepoint);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(7, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 5), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that unwraps multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '3'), list_cell.cell.content.codepoint);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(15, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 10), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // // Set our cursor to be on the "5"
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint);
    }

    // Resize
    try s.resize(10, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should still be on the "5"
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, '5'), list_cell.cell.content.codepoint);
    }
}

test "Screen: resize more cols with reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 5);
    defer s.deinit();
    const str = "1ABC\n2DEF\n3ABC\n4DEF";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursorAbsolute(0, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint);
    }

    // Verify we soft wrapped
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\n4D\nEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(7, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABC\n2DEF\n3ABC\n4DEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

test "Screen: resize more rows and cols with wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(5, 10);

    // Cursor should move due to wrapping
    try testing.expectEqual(@as(size.CellCountInt, 3), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(5, 1);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows moving cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Put our cursor on the last line
    s.cursorAbsolute(1, 2);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'I'), list_cell.cell.content.codepoint);
    }

    // Resize
    try s.resize(5, 1);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
}

test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(5, 1);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize
    try s.resize(5, 1);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with full scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 3);
    defer s.deinit();
    const str = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);

    // Resize
    try s.resize(5, 2);

    // Cursor should stay in the same relative place (bottom of the
    // screen, same character).
    try testing.expectEqual(@as(size.CellCountInt, 4), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(3, 3);

    // Cursor should not move
    try testing.expectEqual(cursor.x, s.cursor.x);
    try testing.expectEqual(cursor.y, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols with reflow but row space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursorAbsolute(4, 0);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'D'), list_cell.cell.content.codepoint);
    }

    try s.resize(3, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.y);
}

test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJ\nKL\n4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow previously wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(3, 3);

    // {
    //     const contents = try s.testString(alloc, .viewport);
    //     defer alloc.free(contents);
    //     const expected = "CD\n5EF\nGH";
    //     try testing.expectEqualStrings(expected, contents);
    // }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "ABC\nD5E\nFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursorAbsolute(1, s.pages.rows - 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'E'), list_cell.cell.content.codepoint);
    }

    try s.resize(3, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3C\n4D\n5E";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 1), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
}

test "Screen: resize less cols with reflow previously wrapped and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 2);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Put our cursor on the end
    s.cursorAbsolute(s.pages.cols - 1, s.pages.rows - 1);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint);
    }

    try s.resize(3, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "CD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1AB\nCD2\nEFG\nH3I\nJKL\n4AB\nCD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), s.cursor.y);
    {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = s.cursor.x,
            .y = s.cursor.y,
        } }).?;
        try testing.expectEqual(@as(u32, 'H'), list_cell.cell.content.codepoint);
    }
}

test "Screen: resize more rows, less cols with reflow with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 3);
    defer s.deinit();
    const str = "1ABCD\n2EFGH3IJKL\n4MNOP";
    try s.testWriteString(str);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(2, 10);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        const expected = "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
}

// This seems like it should work fine but for some reason in practice
// in the initial implementation I found this bug! This is a regression
// test for that.
test "Screen: resize more rows then shrink again" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 10);
    defer s.deinit();
    const str = "1ABC";
    try s.testWriteString(str);

    // Grow
    try s.resize(5, 10);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Shrink
    try s.resize(5, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Grow again
    try s.resize(5, 10);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols to eliminate wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 1, 0);
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }

    // Resize to 1 column can't fit a wide char. So it should be deleted.
    try s.resize(1, 1);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(@as(u21, 0), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.narrow, cell.wide);
    }
}

test "Screen: resize less cols to wrap wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 3, 0);
    defer s.deinit();
    const str = "x😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(2, 3);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("x\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
        try testing.expect(list_cell.row.wrap);
    }
}

test "Screen: resize less cols to eliminate wide char with row space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(1, 2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: resize more cols with wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 2, 0);
    defer s.deinit();
    const str = "  😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("  \n😀", contents);
    }

    // So this is the key point: we end up with a wide spacer head at
    // the end of row 1, then the emoji, then a wide spacer tail on row 2.
    // We should expect that if we resize to more cols, the wide spacer
    // head is replaced with the emoji.
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(4, 2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 3, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: resize more cols with wide spacer head multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 3, 0);
    defer s.deinit();
    const str = "xxxyy😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xxx\nyy\n😀", contents);
    }

    // Similar to the "wide spacer head" test, but this time we'er going
    // to increase our columns such that multiple rows are unwrapped.
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 2 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    try s.resize(8, 2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 5, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 6, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: resize more cols requiring a wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    const str = "xx😀";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }

    // This resizes to 3 columns, which isn't enough space for our wide
    // char to enter row 1. But we need to mark the wide spacer head on the
    // end of the first row since we're wrapping to the next row.
    try s.resize(3, 2);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 2, .y = 0 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_head, cell.wide);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        try testing.expectEqual(@as(u21, '😀'), cell.content.codepoint);
    }
    {
        const list_cell = s.pages.getCell(.{ .screen = .{ .x = 1, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expectEqual(Cell.Wide.spacer_tail, cell.wide);
    }
}

test "Screen: selectAll" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    {
        try s.testWriteString("ABC  DEF\n 123\n456");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    {
        try s.testWriteString("\nFOO\n BAR\n BAZ\n QWERTY\n 12345678");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 8,
            .y = 7,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectLine" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Outside of active area
    // try testing.expect(s.selectLine(.{ .x = 13, .y = 0 }) == null);
    // try testing.expect(s.selectLine(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going backward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 7,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Outside active area
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 9,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectLine across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");

    // Going forward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectLine across soft-wrap ignores blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString(" 12 34012             \n 123");

    // Going forward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going backward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectLine with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 5);
    defer s.deinit();
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    // Selecting first line
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }

    // Selecting last line
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
}

// https://github.com/mitchellh/ghostty/issues/1329
test "Screen: selectLine semantic prompt boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABCDE\nA    > ");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ABCDE\nA    \n> ", contents);
    }

    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 1 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .prompt;
    }

    // Selecting output stops at the prompt even if soft-wrapped
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
    {
        var sel = s.selectLine(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
}

test "Screen: selectWord" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Outside of active area
    // try testing.expect(s.selectWord(.{ .x = 9, .y = 0 }) == null);
    // try testing.expect(s.selectWord(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Whitespace
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Whitespace single char
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // End of screen
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectWord across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString(" 1234012\n 123");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(" 1234\n012\n 123", contents);
    }

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectWord whitespace across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString("1       1\n 123");

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Going forward and backward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectWord with character boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_][]const u8{
        " 'abc' \n123",
        " \"abc\" \n123",
        " │abc│ \n123",
        " `abc` \n123",
        " |abc| \n123",
        " :abc: \n123",
        " ,abc, \n123",
        " (abc( \n123",
        " )abc) \n123",
        " [abc[ \n123",
        " ]abc] \n123",
        " {abc{ \n123",
        " }abc} \n123",
        " <abc< \n123",
        " >abc> \n123",
    };

    for (cases) |case| {
        var s = try init(alloc, 20, 10, 0);
        defer s.deinit();
        try s.testWriteString(case);

        // Inside character forward
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 2,
                .y = 0,
            } }).?).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start().*).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end().*).?);
        }

        // Inside character backward
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 4,
                .y = 0,
            } }).?).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start().*).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end().*).?);
        }

        // Inside character bidirectional
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 3,
                .y = 0,
            } }).?).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 2,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start().*).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end().*).?);
        }

        // On quote
        // NOTE: this behavior is not ideal, so we can change this one day,
        // but I think its also not that important compared to the above.
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?).?;
            defer sel.deinit(&s);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start().*).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 1,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end().*).?);
        }
    }
}

test "Screen: selectOutput" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 15, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output1\n");         // 0
        try s.testWriteString("output1\n");         // 1
        try s.testWriteString("prompt2\n");         // 2
        try s.testWriteString("input2\n");          // 3
        try s.testWriteString("output2\n");         // 4
        try s.testWriteString("output2\n");         // 5
        try s.testWriteString("prompt3$ input3\n"); // 6
        try s.testWriteString("output3\n");         // 7
        try s.testWriteString("output3\n");         // 8
        try s.testWriteString("output3");           // 9
    }
    // zig fmt: on

    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 2 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .prompt;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 3 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 4 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .command;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 6 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 7 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .command;
    }

    // No start marker, should select from the beginning
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
    // Both start and end markers, should select between them
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 5,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 4,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 5,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
    // No end marker, should select till the end
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 7,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 7,
        } }, s.pages.pointFromPin(.active, sel.start().*).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 10,
        } }, s.pages.pointFromPin(.active, sel.end().*).?);
    }
    // input / prompt at y = 0, pt.y = 0
    {
        s.deinit();
        s = try init(alloc, 10, 5, 0);
        try s.testWriteString("prompt1$ input1\n");
        try s.testWriteString("output1\n");
        try s.testWriteString("prompt2\n");
        {
            const pin = s.pages.pin(.{ .screen = .{ .y = 0 } }).?;
            const row = pin.rowAndCell().row;
            row.semantic_prompt = .input;
        }
        {
            const pin = s.pages.pin(.{ .screen = .{ .y = 1 } }).?;
            const row = pin.rowAndCell().row;
            row.semantic_prompt = .command;
        }
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).?) == null);
    }
}

test "Screen: selectPrompt basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 15, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output1\n");         // 0
        try s.testWriteString("output1\n");         // 1
        try s.testWriteString("prompt2\n");         // 2
        try s.testWriteString("input2\n");          // 3
        try s.testWriteString("output2\n");         // 4
        try s.testWriteString("output2\n");         // 5
        try s.testWriteString("prompt3$ input3\n"); // 6
        try s.testWriteString("output3\n");         // 7
        try s.testWriteString("output3\n");         // 8
        try s.testWriteString("output3");           // 9
    }
    // zig fmt: on

    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 2 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .prompt;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 3 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 4 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .command;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 6 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 7 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .command;
    }

    // Not at a prompt
    {
        const sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?);
        try testing.expect(sel == null);
    }
    {
        const sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 8,
        } }).?);
        try testing.expect(sel == null);
    }

    // Single line prompt
    {
        var sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 6,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 6,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }

    // Multi line prompt
    {
        var sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 3,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectPrompt prompt at start" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 15, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("prompt1\n");         // 0
        try s.testWriteString("input1\n");          // 1
        try s.testWriteString("output2\n");         // 2
        try s.testWriteString("output2\n");         // 3
    }
    // zig fmt: on

    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 0 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .prompt;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 1 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 2 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .command;
    }

    // Not at a prompt
    {
        const sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 3,
        } }).?);
        try testing.expect(sel == null);
    }

    // Multi line prompt
    {
        var sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}

test "Screen: selectPrompt prompt at end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 15, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output2\n");         // 0
        try s.testWriteString("output2\n");         // 1
        try s.testWriteString("prompt1\n");         // 2
        try s.testWriteString("input1\n");          // 3
    }
    // zig fmt: on

    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 2 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .prompt;
    }
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 3 } }).?;
        const row = pin.rowAndCell().row;
        row.semantic_prompt = .input;
    }

    // Not at a prompt
    {
        const sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).?);
        try testing.expect(sel == null);
    }

    // Multi line prompt
    {
        var sel = s.selectPrompt(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.start().*).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end().*).?);
    }
}
