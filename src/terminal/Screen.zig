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

/// The selection for this screen (if any). This MUST be a tracked selection
/// otherwise the selection will become invalid. Instead of accessing this
/// directly to set it, use the `select` function which will assert and
/// automatically setup tracking.
selection: ?Selection = null,

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
    // Create a tracked pin remapper for our selection and cursor. Note
    // that we may want to expose this generally in the future but at the
    // time of doing this we don't need to.
    var pin_remap = PageList.Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();

    var pages = try self.pages.clone(.{
        .top = top,
        .bot = bot,
        .memory = if (pool) |p| .{
            .pool = p,
        } else .{
            .alloc = alloc,
        },
        .tracked_pins = &pin_remap,
    });
    errdefer pages.deinit();

    // Find our cursor. If the cursor isn't in the cloned area, we move it
    // to the top-left arbitrarily because a screen must have SOME cursor.
    const cursor: Cursor = cursor: {
        if (pin_remap.get(self.cursor.page_pin)) |p| remap: {
            const page_rac = p.rowAndCell();
            const pt = pages.pointFromPin(.active, p.*) orelse break :remap;
            break :cursor .{
                .x = @intCast(pt.active.x),
                .y = @intCast(pt.active.y),
                .page_pin = p,
                .page_row = page_rac.row,
                .page_cell = page_rac.cell,
            };
        }

        const page_pin = try pages.trackPin(.{ .page = pages.pages.first.? });
        const page_rac = page_pin.rowAndCell();
        break :cursor .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        };
    };

    // Preserve our selection if we have one.
    const sel: ?Selection = if (self.selection) |sel| sel: {
        assert(sel.tracked());

        const ordered: struct {
            tl: *Pin,
            br: *Pin,
        } = switch (sel.order(self)) {
            .forward, .mirrored_forward => .{
                .tl = sel.bounds.tracked.start,
                .br = sel.bounds.tracked.end,
            },
            .reverse, .mirrored_reverse => .{
                .tl = sel.bounds.tracked.end,
                .br = sel.bounds.tracked.start,
            },
        };

        const start_pin = pin_remap.get(ordered.tl) orelse start: {

            // No start means it is outside the cloned area. We change it
            // to the top-left. If we have no end pin then our whole
            // selection is outside the cloned area so we can just set it
            // as null.
            if (pin_remap.get(ordered.br) == null) break :sel null;
            break :start try pages.trackPin(.{ .page = pages.pages.first.? });
        };

        const end_pin = pin_remap.get(ordered.br) orelse end: {
            // No end means it is outside the cloned area. We change it
            // to the bottom-right.
            break :end try pages.trackPin(pages.pin(.{ .active = .{
                .x = pages.cols - 1,
                .y = pages.rows - 1,
            } }) orelse break :sel null);
        };

        break :sel .{
            .bounds = .{ .tracked = .{
                .start = start_pin,
                .end = end_pin,
            } },
            .rectangle = sel.rectangle,
        };
    } else null;

    return .{
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = self.no_scrollback,
        .cursor = cursor,
        .selection = sel,
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

/// Copy another cursor. The cursor can be on any screen but the x/y
/// must be within our screen bounds.
pub fn cursorCopy(self: *Screen, other: Cursor) !void {
    assert(other.x < self.pages.cols);
    assert(other.y < self.pages.rows);

    const old = self.cursor;
    self.cursor = other;
    errdefer self.cursor = old;

    // We need to keep our old x/y because that is our cursorAbsolute
    // will fix up our pointers.
    //
    // We keep our old page pin because we expect to be in the active
    // page relative to our own screen.
    self.cursor.page_pin = old.page_pin;
    self.cursor.x = old.x;
    self.cursor.y = old.y;
    self.cursorAbsolute(other.x, other.y);

    // We keep the old style ref so manualStyleUpdate can clean our old style up.
    self.cursor.style_id = old.style_id;
    self.cursor.style_ref = old.style_ref;
    try self.manualStyleUpdate();
}

/// Options for scrolling the viewport of the terminal grid. The reason
/// we have this in addition to PageList.Scroll is because we have additional
/// scroll behaviors that are not part of the PageList.Scroll enum.
pub const Scroll = union(enum) {
    /// For all of these, see PageList.Scroll.
    active,
    top,
    pin: Pin,
    delta_row: isize,
    delta_prompt: isize,
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
        .pin => |p| self.pages.scroll(.{ .pin = p }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
        .delta_prompt => |v| self.pages.scroll(.{ .delta_prompt = v }),
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
            if (page.styles.lookupId(
                page.memory,
                cell.style_id,
            )) |prev_style| {
                // Below upsert can't fail because it should already be present
                const md = page.styles.upsert(
                    page.memory,
                    prev_style.*,
                ) catch unreachable;
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

/// Clears the prompt lines if the cursor is currently at a prompt. This
/// clears the entire line. This is used for resizing when the shell
/// handles reflow.
///
/// The cleared cells are not colored with the current style background
/// color like other clear functions, because this is a special case used
/// for a specific purpose that does not want that behavior.
pub fn clearPrompt(self: *Screen) void {
    var found: ?Pin = null;

    // From our cursor, move up and find all prompt lines.
    var it = self.cursor.page_pin.rowIterator(
        .left_up,
        self.pages.pin(.{ .active = .{} }),
    );
    while (it.next()) |p| {
        const row = p.rowAndCell().row;
        switch (row.semantic_prompt) {
            // We are at a prompt but we're not at the start of the prompt.
            // We mark our found value and continue because the prompt
            // may be multi-line.
            .input => found = p,

            // If we find the prompt then we're done. We are also done
            // if we find any prompt continuation, because the shells
            // that send this currently (zsh) cannot redraw every line.
            .prompt, .prompt_continuation => {
                found = p;
                break;
            },

            // If we have command output, then we're most certainly not
            // at a prompt. Break out of the loop.
            .command => break,

            // If we don't know, we keep searching.
            .unknown => {},
        }
    }

    // If we found a prompt, we clear it.
    if (found) |top| {
        var clear_it = top.rowIterator(.right_down, null);
        while (clear_it.next()) |p| {
            const row = p.rowAndCell().row;
            p.page.data.clearCells(row, 0, p.page.data.size.cols);
        }
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

    // std.log.warn("active styles={}", .{page.styles.count(page.memory)});

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
    const md = page.styles.upsert(
        page.memory,
        self.cursor.style,
    ) catch |err| md: {
        switch (err) {
            // Our style map is full. Let's allocate a new page by doubling
            // the size and then try again.
            error.OutOfMemory => {
                const node = try self.pages.adjustCapacity(
                    self.cursor.page_pin.page,
                    .{ .styles = page.capacity.styles * 2 },
                );

                page = &node.data;
            },

            // We've run out of style IDs. This is fixed by doing a page
            // compaction.
            error.Overflow => {
                const node = try self.pages.compact(
                    self.cursor.page_pin.page,
                );
                page = &node.data;
            },
        }

        // Since this modifies our cursor page, we need to reload
        self.cursorReload();

        break :md try page.styles.upsert(
            page.memory,
            self.cursor.style,
        );
    };
    self.cursor.style_id = md.id;
    self.cursor.style_ref = &md.ref;
}

/// Append a grapheme to the given cell within the current cursor row.
pub fn appendGrapheme(self: *Screen, cell: *Cell, cp: u21) !void {
    self.cursor.page_pin.page.data.appendGrapheme(
        self.cursor.page_row,
        cell,
        cp,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            // We need to determine the actual cell index of the cell so
            // that after we adjust the capacity we can reload the cell.
            const cell_idx: usize = cell_idx: {
                const cells: [*]Cell = @ptrCast(self.cursor.page_cell);
                const zero: [*]Cell = cells - self.cursor.x;
                const target: [*]Cell = @ptrCast(cell);
                const cell_idx = (@intFromPtr(target) - @intFromPtr(zero)) / @sizeOf(Cell);
                break :cell_idx cell_idx;
            };

            // Adjust our capacity. This will update our cursor page pin and
            // force us to reload.
            const original_node = self.cursor.page_pin.page;
            const new_bytes = original_node.data.capacity.grapheme_bytes * 2;
            _ = try self.pages.adjustCapacity(original_node, .{ .grapheme_bytes = new_bytes });
            self.cursorReload();

            // The cell pointer is now invalid, so we need to get it from
            // the reloaded cursor pointers.
            const reloaded_cell: *Cell = switch (std.math.order(cell_idx, self.cursor.x)) {
                .eq => self.cursor.page_cell,
                .lt => self.cursorCellLeft(@intCast(self.cursor.x - cell_idx)),
                .gt => self.cursorCellRight(@intCast(cell_idx - self.cursor.x)),
            };

            try self.cursor.page_pin.page.data.appendGrapheme(
                self.cursor.page_row,
                reloaded_cell,
                cp,
            );
        },
    };
}

/// Set the selection to the given selection. If this is a tracked selection
/// then the screen will take overnship of the selection. If this is untracked
/// then the screen will convert it to tracked internally. This will automatically
/// untrack the prior selection (if any).
///
/// Set the selection to null to clear any previous selection.
///
/// This is always recommended over setting `selection` directly. Beyond
/// managing memory for you, it also performs safety checks that the selection
/// is always tracked.
pub fn select(self: *Screen, sel_: ?Selection) !void {
    const sel = sel_ orelse {
        self.clearSelection();
        return;
    };

    // If this selection is untracked then we track it.
    const tracked_sel = if (sel.tracked()) sel else try sel.track(self);
    errdefer if (!sel.tracked()) tracked_sel.deinit(self);

    // Untrack prior selection
    if (self.selection) |*old| old.deinit(self);
    self.selection = tracked_sel;
}

/// Same as select(null) but can't fail.
pub fn clearSelection(self: *Screen) void {
    if (self.selection) |*sel| sel.deinit(self);
    self.selection = null;
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
pub fn selectionString(
    self: *Screen,
    alloc: Allocator,
    sel: Selection,
    trim: bool,
) ![:0]const u8 {
    // Use an ArrayList so that we can grow the array as we go. We
    // build an initial capacity of just our rows in our selection times
    // columns. It can be more or less based on graphemes, newlines, etc.
    var strbuilder = std.ArrayList(u8).init(alloc);
    defer strbuilder.deinit();

    const sel_ordered = sel.ordered(self, .forward);
    const sel_start = start: {
        var start = sel_ordered.start();
        const cell = start.rowAndCell().cell;
        if (cell.wide == .spacer_tail) start.x -= 1;
        break :start start;
    };
    const sel_end = end: {
        var end = sel_ordered.end();
        const cell = end.rowAndCell().cell;
        switch (cell.wide) {
            .narrow, .wide => {},

            // We can omit the tail
            .spacer_tail => end.x -= 1,

            // With the head we want to include the wrapped wide character.
            .spacer_head => if (end.down(1)) |p| {
                end = p;
                end.x = 0;
            },
        }
        break :end end;
    };

    var page_it = sel_start.pageIterator(.right_down, sel_end);
    var row_count: usize = 0;
    while (page_it.next()) |chunk| {
        const rows = chunk.rows();
        for (rows) |row| {
            const cells_ptr = row.cells.ptr(chunk.page.data.memory);

            const start_x = if (row_count == 0 or sel_ordered.rectangle)
                sel_start.x
            else
                0;
            const end_x = if (row_count == rows.len - 1 or sel_ordered.rectangle)
                sel_end.x + 1
            else
                self.pages.cols;

            const cells = cells_ptr[start_x..end_x];
            for (cells) |*cell| {
                // Skip wide spacers
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                var buf: [4]u8 = undefined;
                {
                    const raw: u21 = if (cell.hasText()) cell.content.codepoint else 0;
                    const char = if (raw > 0) raw else ' ';
                    const encode_len = try std.unicode.utf8Encode(char, &buf);
                    try strbuilder.appendSlice(buf[0..encode_len]);
                }
                if (cell.hasGrapheme()) {
                    const cps = chunk.page.data.lookupGrapheme(cell).?;
                    for (cps) |cp| {
                        const encode_len = try std.unicode.utf8Encode(cp, &buf);
                        try strbuilder.appendSlice(buf[0..encode_len]);
                    }
                }
            }

            if (row_count < rows.len - 1 and
                (!row.wrap or sel_ordered.rectangle))
            {
                try strbuilder.append('\n');
            }

            row_count += 1;
        }
    }

    // Remove any trailing spaces on lines. We could do optimize this by
    // doing this in the loop above but this isn't very hot path code and
    // this is simple.
    if (trim) {
        var it = std.mem.tokenizeScalar(u8, strbuilder.items, '\n');

        // Reset our items. We retain our capacity. Because we're only
        // removing bytes, we know that the trimmed string must be no longer
        // than the original string so we copy directly back into our
        // allocated memory.
        strbuilder.clearRetainingCapacity();
        while (it.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, " \t");
            const i = strbuilder.items.len;
            strbuilder.items.len += trimmed.len;
            std.mem.copyForwards(u8, strbuilder.items[i..], trimmed);
            try strbuilder.append('\n');
        }

        // Remove all trailing newlines
        for (0..strbuilder.items.len) |_| {
            if (strbuilder.items[strbuilder.items.len - 1] != '\n') break;
            strbuilder.items.len -= 1;
        }
    }

    // Get our final string
    const string = try strbuilder.toOwnedSliceSentinel(0);
    errdefer alloc.free(string);

    return string;
}

pub const SelectLine = struct {
    /// The pin of some part of the line to select.
    pin: Pin,

    /// These are the codepoints to consider whitespace to trim
    /// from the ends of the selection.
    whitespace: ?[]const u21 = &.{ 0, ' ', '\t' },

    /// If true, line selection will consider semantic prompt
    /// state changing a boundary. State changing is ANY state
    /// change.
    semantic_prompt_boundary: bool = true,
};

/// Select the line under the given point. This will select across soft-wrapped
/// lines and will omit the leading and trailing whitespace. If the point is
/// over whitespace but the line has non-whitespace characters elsewhere, the
/// line will be selected.
pub fn selectLine(self: *const Screen, opts: SelectLine) ?Selection {
    _ = self;

    // Get the current point semantic prompt state since that determines
    // boundary conditions too. This makes it so that line selection can
    // only happen within the same prompt state. For example, if you triple
    // click output, but the shell uses spaces to soft-wrap to the prompt
    // then the selection will stop prior to the prompt. See issue #1329.
    const semantic_prompt_state: ?bool = state: {
        if (!opts.semantic_prompt_boundary) break :state null;
        const rac = opts.pin.rowAndCell();
        break :state rac.row.semantic_prompt.promptOrInput();
    };

    // The real start of the row is the first row in the soft-wrap.
    const start_pin: Pin = start_pin: {
        var it = opts.pin.rowIterator(.left_up, null);
        var it_prev: Pin = opts.pin;
        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (!row.wrap) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }

            if (semantic_prompt_state) |v| {
                // See semantic_prompt_state comment for why
                const current_prompt = row.semantic_prompt.promptOrInput();
                if (current_prompt != v) {
                    var copy = it_prev;
                    copy.x = 0;
                    break :start_pin copy;
                }
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
        var it = opts.pin.rowIterator(.right_down, null);
        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (semantic_prompt_state) |v| {
                // See semantic_prompt_state comment for why
                const current_prompt = row.semantic_prompt.promptOrInput();
                if (current_prompt != v) {
                    var prev = p.up(1).?;
                    prev.x = p.page.data.size.cols - 1;
                    break :end_pin prev;
                }
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
        const whitespace = opts.whitespace orelse break :start start_pin;
        var it = start_pin.cellIterator(.right_down, end_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u21,
                whitespace,
                &[_]u21{cell.content.codepoint},
            ) != null;
            if (this_whitespace) continue;

            break :start p;
        }

        return null;
    };

    // Go backward from the end to find the first non-whitespace character.
    const end: Pin = end: {
        const whitespace = opts.whitespace orelse break :end end_pin;
        var it = end_pin.cellIterator(.left_up, start_pin);
        while (it.next()) |p| {
            const cell = p.rowAndCell().cell;
            if (!cell.hasText()) continue;

            // Non-empty means we found it.
            const this_whitespace = std.mem.indexOfAny(
                u21,
                whitespace,
                &[_]u21{cell.content.codepoint},
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

/// Select the nearest word to start point that is between start_pt and
/// end_pt (inclusive). Because it selects "nearest" to start point, start
/// point can be before or after end point.
///
/// TODO: test this
pub fn selectWordBetween(
    self: *Screen,
    start: Pin,
    end: Pin,
) ?Selection {
    const dir: PageList.Direction = if (start.before(end)) .right_down else .left_up;
    var it = start.cellIterator(dir, end);
    while (it.next()) |pin| {
        // Boundary conditions
        switch (dir) {
            .right_down => if (end.before(pin)) return null,
            .left_up => if (pin.before(end)) return null,
        }

        // If we found a word, then return it
        if (self.selectWord(pin)) |sel| return sel;
    }

    return null;
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

pub const LineIterator = struct {
    screen: *const Screen,
    current: ?Pin = null,

    pub fn next(self: *LineIterator) ?Selection {
        const current = self.current orelse return null;
        const result = self.screen.selectLine(.{
            .pin = current,
            .whitespace = null,
            .semantic_prompt_boundary = false,
        }) orelse {
            self.current = null;
            return null;
        };

        self.current = result.end().down(1);
        return result;
    }
};

/// Returns an iterator to move through the soft-wrapped lines starting
/// from pin.
pub fn lineIterator(self: *const Screen, start: Pin) LineIterator {
    return LineIterator{
        .screen = self,
        .current = start,
    };
}

/// Returns the change in x/y that is needed to reach "to" from "from"
/// within a prompt. If "to" is before or after the prompt bounds then
/// the result will be bounded to the prompt.
///
/// This feature requires shell integration. If shell integration is not
/// enabled, this will always return zero for both x and y (no path).
pub fn promptPath(
    self: *Screen,
    from: Pin,
    to: Pin,
) struct {
    x: isize,
    y: isize,
} {
    // Get our prompt bounds assuming "from" is at a prompt.
    const bounds = self.selectPrompt(from) orelse return .{ .x = 0, .y = 0 };

    // Get our actual "to" point clamped to the bounds of the prompt.
    const to_clamped = if (bounds.contains(self, to))
        to
    else if (to.before(bounds.start()))
        bounds.start()
    else
        bounds.end();

    // Convert to points
    const from_pt = self.pages.pointFromPin(.screen, from).?.screen;
    const to_pt = self.pages.pointFromPin(.screen, to_clamped).?.screen;

    // Basic math to calculate our path.
    const from_x: isize = @intCast(from_pt.x);
    const from_y: isize = @intCast(from_pt.y);
    const to_x: isize = @intCast(to_pt.x);
    const to_y: isize = @intCast(to_pt.y);
    return .{ .x = to_x - from_x, .y = to_y - from_y };
}

pub const DumpString = struct {
    /// The start and end points of the dump, both inclusive. The x will
    /// be ignored and the full row will always be dumped.
    tl: Pin,
    br: ?Pin = null,

    /// If true, this will unwrap soft-wrapped lines. If false, this will
    /// dump the screen as it is visually seen in a rendered window.
    unwrap: bool = true,
};

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
pub fn dumpString(
    self: *const Screen,
    writer: anytype,
    opts: DumpString,
) !void {
    var blank_rows: usize = 0;

    var iter = opts.tl.rowIterator(.right_down, opts.br);
    while (iter.next()) |row_offset| {
        const rac = row_offset.rowAndCell();
        const row = rac.row;
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

        if (!row.wrap or !opts.unwrap) {
            // If we're not wrapped, we always add a newline.
            // If we are wrapped, we only add a new line if we're unwrapping
            // soft-wrapped lines.
            blank_rows += 1;
        }

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

/// You should use dumpString, this is a restricted version mostly for
/// legacy and convenience reasons for unit tests.
pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder = std.ArrayList(u8).init(alloc);
    defer builder.deinit();

    try self.dumpString(builder.writer(), .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = false,
    });

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
            const cell = cell: {
                var cell = self.cursorCellLeft(1);
                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},
                    .spacer_head => unreachable,
                    .spacer_tail => cell = self.cursorCellLeft(2),
                }

                break :cell cell;
            };

            try self.cursor.page_pin.page.data.appendGrapheme(
                self.cursor.page_row,
                cell,
                c,
            );
            continue;
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

test "Screen cursorCopy x/y" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 10, 10, 0);
    defer s.deinit();
    s.cursorAbsolute(2, 3);
    try testing.expect(s.cursor.x == 2);
    try testing.expect(s.cursor.y == 3);

    var s2 = try Screen.init(alloc, 10, 10, 0);
    defer s2.deinit();
    try s2.cursorCopy(s.cursor);
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 3);
    try s2.testWriteString("Hello");

    {
        const str = try s2.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("\n\n\n  Hello", str);
    }
}

test "Screen cursorCopy style deref" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 10, 10, 0);
    defer s.deinit();

    var s2 = try Screen.init(alloc, 10, 10, 0);
    defer s2.deinit();
    const page = s2.cursor.page_pin.page.data;

    // Bold should create our style
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
    try testing.expect(s2.cursor.style.flags.bold);

    // Copy default style, should release our style
    try s2.cursorCopy(s.cursor);
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));
}

test "Screen cursorCopy style copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });

    var s2 = try Screen.init(alloc, 10, 10, 0);
    defer s2.deinit();
    const page = s2.cursor.page_pin.page.data;
    try s2.cursorCopy(s.cursor);
    try testing.expect(s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
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

test "Screen: clearPrompt" {
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
        s.cursorAbsolute(0, 2);
        s.cursor.page_row.semantic_prompt = .input;
    }

    s.clearPrompt();

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: clearPrompt no prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    s.clearPrompt();

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
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

test "Screen: scrolling moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Scroll down, should still be bottom
    try s.cursorDownScroll();

    // Our selection should've moved up
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    s.scroll(.{ .active = {} });

    // Our selection should've stayed the same
    {
        const sel = s.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s.pages.cols - 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scroll up again
    try s.cursorDownScroll();

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL", contents);
    }

    // Our selection should be null because it left the screen.
    {
        const sel = s.selection.?;
        try testing.expect(s.pages.pointFromPin(.active, sel.start()) == null);
        try testing.expect(s.pages.pointFromPin(.active, sel.end()) == null);
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
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(alloc, .{ .active = .{} }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);

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
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 1), s2.cursor.y);
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
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(alloc, .{ .active = .{ .y = 1 } }, null);
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    // Cursor is shifted since we cloned partial
    try testing.expectEqual(@as(usize, 5), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}

test "Screen: clone partial cursor out of bounds" {
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
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 0 } },
    );
    defer s2.deinit();
    {
        const contents = try s2.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Cursor is shifted since we cloned partial
    try testing.expectEqual(@as(usize, 0), s2.cursor.x);
    try testing.expectEqual(@as(usize, 0), s2.cursor.y);
}

test "Screen: clone contains full selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{} },
        null,
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains none of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 0 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();

    // Our selection should be null
    try testing.expect(s2.selection == null);
}

test "Screen: clone contains selection start cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 1 } },
        null,
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains selection end cutoff" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains selection end cutoff reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Select a single line
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 0 } },
        .{ .active = .{ .y = 1 } },
    );
    defer s2.deinit();

    // Our selection should remain valid
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = s2.pages.cols - 1,
            .y = 2,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
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

test "Screen: resize less cols with scrollback keeps cursor row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 5);
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Lets do a scroll and clear operation
    try s.scrollClear();

    // Move our cursor to the beginning
    s.cursorAbsolute(0, 0);

    try s.resize(3, 3);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), s.cursor.y);
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

test "Screen: select untracked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    try testing.expect(s.selection == null);
    const tracked = s.pages.countTrackedPins();
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
        false,
    ));
    try testing.expectEqual(tracked + 2, s.pages.countTrackedPins());
    try s.select(null);
    try testing.expectEqual(tracked, s.pages.countTrackedPins());
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    {
        try s.testWriteString("\nFOO\n BAR\n BAZ\n QWERTY\n 12345678");
        var sel = s.selectAll().?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 8,
            .y = 7,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 7,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Outside active area
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 9,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Going forward and backward
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine disabled whitespace trimming" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");

    // Going forward
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 0,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Non-wrapped
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 1,
                .y = 3,
            } }).?,
            .whitespace = null,
        }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting last line
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 2,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 2,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 4,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 1,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 5,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 9,
            .y = 10,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 6,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
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
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: promptPath" {
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

    // From is not in the prompt
    {
        const path = s.promptPath(
            s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .active = .{ .x = 0, .y = 2 } }).?,
        );
        try testing.expectEqual(@as(isize, 0), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // Same line
    {
        const path = s.promptPath(
            s.pages.pin(.{ .active = .{ .x = 6, .y = 2 } }).?,
            s.pages.pin(.{ .active = .{ .x = 3, .y = 2 } }).?,
        );
        try testing.expectEqual(@as(isize, -3), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // Different lines
    {
        const path = s.promptPath(
            s.pages.pin(.{ .active = .{ .x = 6, .y = 2 } }).?,
            s.pages.pin(.{ .active = .{ .x = 3, .y = 3 } }).?,
        );
        try testing.expectEqual(@as(isize, -3), path.x);
        try testing.expectEqual(@as(isize, 1), path.y);
    }

    // To is out of bounds before
    {
        const path = s.promptPath(
            s.pages.pin(.{ .active = .{ .x = 6, .y = 2 } }).?,
            s.pages.pin(.{ .active = .{ .x = 3, .y = 1 } }).?,
        );
        try testing.expectEqual(@as(isize, -6), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // To is out of bounds after
    {
        const path = s.promptPath(
            s.pages.pin(.{ .active = .{ .x = 6, .y = 2 } }).?,
            s.pages.pin(.{ .active = .{ .x = 3, .y = 9 } }).?,
        );
        try testing.expectEqual(@as(isize, 3), path.x);
        try testing.expectEqual(@as(isize, 1), path.y);
    }
}

test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString start outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString end outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, sel, false);
        defer alloc.free(contents);
        const expected = "1AB  \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim empty line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1AB  \n\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, sel, false);
        defer alloc.free(contents);
        const expected = "1AB  \n     \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/289
test "Screen: selectionString empty with soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 2, 0);
    defer s.deinit();

    // Let me describe the situation that caused this because this
    // test is not obvious. By writing an emoji below, we introduce
    // one cell with the emoji and one cell as a "wide char spacer".
    // We then soft wrap the line by writing spaces.
    //
    // By selecting only the tail, we'd select nothing and we had
    // a logic error that would cause a crash.
    try s.testWriteString("👨");
    try s.testWriteString("      ");

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "👨";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString with zero width joiner" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 1, 0);
    defer s.deinit();
    const str = "👨‍"; // this has a ZWJ
    try s.testWriteString(str);

    // Integrity check
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 0, .x = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = pin.page.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }

    // The real test
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, sel, true);
        defer alloc.free(contents);
        const expected = "👨‍";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString, rectangle, basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 30, 5, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
        true,
    );
    const expected =
        \\t ame
        \\ipisc
        \\usmod
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, w/EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 30, 5, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 12, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 4 } }).?,
        true,
    );
    const expected =
        \\dolor
        \\nsectetur
        \\lit, sed do
        \\or incididunt
        \\ dolore
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, more complex w/breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 30, 8, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
        \\
        \\magna aliqua. Ut enim
        \\ad minim veniam, quis
    ;
    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 11, .y = 2 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 26, .y = 7 } }).?,
        true,
    );
    const expected =
        \\elit, sed do
        \\por incididunt
        \\t dolore
        \\
        \\a. Ut enim
        \\niam, quis
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: lineIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, sel, false);
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, sel, false);
        defer alloc.free(actual);
        try testing.expectEqualStrings("2EFGH", actual);
    }
}

test "Screen: lineIterator soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, sel, false);
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, sel, false);
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }
    // try testing.expect(iter.next() == null);
}
