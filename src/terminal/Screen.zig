const Screen = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const fastmem = @import("../fastmem.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const tripwire = @import("../tripwire.zig");
const unicode = @import("../unicode/main.zig");
const Selection = @import("Selection.zig");
const PageList = @import("PageList.zig");
const StringMap = @import("StringMap.zig");
const ScreenFormatter = @import("formatter.zig").ScreenFormatter;
const osc = @import("osc.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const hyperlink = @import("hyperlink.zig");
const Offset = size.Offset;
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const Cell = pagepkg.Cell;
const Pin = PageList.Pin;

pub const CursorStyle = @import("cursor.zig").Style;

const log = std.log.scoped(.screen);

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
kitty_images: if (build_options.kitty_graphics)
    kitty.graphics.ImageStorage
else
    struct {} = .{},

/// Semantic prompt (OSC133) state.
semantic_prompt: SemanticPrompt = .disabled,

/// Dirty flags for the renderer.
dirty: Dirty = .{},

/// See Terminal.Dirty. This behaves the same way.
pub const Dirty = packed struct {
    /// Set when the selection is set or unset, regardless of if the
    /// selection is changed or not.
    selection: bool = false,

    /// When an OSC8 hyperlink is hovered, we set the full screen as dirty
    /// because links can span multiple lines.
    hyperlink_hover: bool = false,
};

pub const SemanticPrompt = struct {
    /// This is flipped to true when any sort of semantic content is
    /// seen. In particular, this is set to true only when a `prompt` type
    /// is ever set on our cursor.
    ///
    /// This is used to optimize away semantic content operations if we know
    /// we've never seen them.
    seen: bool,

    /// This is set on any `cl` or `click_events` option set on the
    /// most recent OSC 133 commands to specify how click handling in a
    /// prompt is handling.
    click: SemanticClick,

    pub const disabled: SemanticPrompt = .{
        .seen = false,
        .click = .none,
    };

    pub const SemanticClick = union(enum) {
        none,
        click_events,
        cl: osc.semantic_prompt.Click,
    };
};

/// The cursor position and style.
pub const Cursor = struct {
    // The x/y position within the active area.
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

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

    /// The hyperlink ID that is currently active for the cursor. A value
    /// of zero means no hyperlink is active. (Implements OSC8, saying that
    /// so code search can find it.).
    hyperlink_id: hyperlink.Id = 0,

    /// This is the implicit ID to use for hyperlinks that don't specify
    /// an ID. We do an overflowing add to this so repeats can technically
    /// happen with carefully crafted inputs but for real workloads its
    /// highly unlikely -- and the fix is for the TUI program to use explicit
    /// IDs.
    hyperlink_implicit_id: size.OffsetInt = 0,

    /// Heap-allocated hyperlink state so that we can recreate it when
    /// the cursor page pin changes. We can't get it from the old screen
    /// state because the page may be cleared. This is heap allocated
    /// because its most likely null.
    hyperlink: ?*hyperlink.Hyperlink = null,

    /// The current semantic content type for the cursor that will be
    /// applied to any newly written cells.
    semantic_content: pagepkg.Cell.SemanticContent = .output,
    semantic_content_clear_eol: bool = false,

    /// The pointers into the page list where the cursor is currently
    /// located. This makes it faster to move the cursor.
    page_pin: *PageList.Pin,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,

    pub fn deinit(self: *Cursor, alloc: Allocator) void {
        if (self.hyperlink) |link| {
            link.deinit(alloc);
            alloc.destroy(link);
        }
    }
};

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
    charsets: CharsetArray = .{},

    /// GL is the slot to use when using a 7-bit printable char (up to 127)
    /// GR used for 8-bit printable chars.
    gl: charsets.Slots = .G0,
    gr: charsets.Slots = .G2,

    /// Single shift where a slot is used for exactly one char.
    single_shift: ?charsets.Slots = null,

    /// An array to map a charset slot to a lookup table.
    ///
    /// We use this bespoke struct instead of `std.EnumArray` because
    /// accessing these slots is very performance critical since it's
    /// done for every single print. This benchmarks faster.
    const CharsetArray = struct {
        g0: charsets.Charset = .utf8,
        g1: charsets.Charset = .utf8,
        g2: charsets.Charset = .utf8,
        g3: charsets.Charset = .utf8,

        pub inline fn get(
            self: *const CharsetArray,
            slot: charsets.Slots,
        ) charsets.Charset {
            return switch (slot) {
                .G0 => self.g0,
                .G1 => self.g1,
                .G2 => self.g2,
                .G3 => self.g3,
            };
        }

        pub inline fn set(
            self: *CharsetArray,
            slot: charsets.Slots,
            charset: charsets.Charset,
        ) void {
            switch (slot) {
                .G0 => self.g0 = charset,
                .G1 => self.g1 = charset,
                .G2 => self.g2 = charset,
                .G3 => self.g3 = charset,
            }
        }
    };
};

pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// The maximum size of scrollback in bytes. Zero means unlimited. Any
    /// other value will be clamped to support a minimum of the active area.
    max_scrollback: usize = 0,

    /// The total storage limit for Kitty images in bytes for this
    /// screen. Kitty image storage is per-screen.
    kitty_image_storage_limit: usize = 320 * 1000 * 1000, // 320MB

    /// A simple, default terminal. If you rely on specific dimensions or
    /// scrollback (or lack of) then do not use this directly. This is just
    /// for callers that need some defaults.
    pub const default: Options = .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 0,
    };
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
    opts: Options,
) Allocator.Error!Screen {
    // Initialize our backing pages.
    var pages = try PageList.init(
        alloc,
        opts.cols,
        opts.rows,
        opts.max_scrollback,
    );
    errdefer pages.deinit();

    // Create our tracked pin for the cursor.
    const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
    errdefer pages.untrackPin(page_pin);
    const page_rac = page_pin.rowAndCell();

    var result: Screen = .{
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = opts.max_scrollback == 0,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page_pin = page_pin,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        },
    };

    if (comptime build_options.kitty_graphics) {
        // This can't fail because the storage is always empty at this point
        // and the only fail-able case is that we have to evict images.
        result.kitty_images.setLimit(
            alloc,
            &result,
            opts.kitty_image_storage_limit,
        ) catch unreachable;
    }

    return result;
}

pub fn deinit(self: *Screen) void {
    if (comptime build_options.kitty_graphics) {
        self.kitty_images.deinit(self.alloc, self);
    }
    self.cursor.deinit(self.alloc);
    self.pages.deinit();
}

/// Assert that the screen is in a consistent state. This doesn't check
/// all pages in the page list because that is SO SLOW even just for
/// tests. This only asserts the screen specific data so callers should
/// ensure they're also calling page integrity checks if necessary.
pub fn assertIntegrity(self: *const Screen) void {
    if (build_options.slow_runtime_safety) {
        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        assert(self.cursor.x < self.pages.cols);
        assert(self.cursor.y < self.pages.rows);

        // Our cursor x/y should always match the pin. If this doesn't
        // match then it indicates that the tracked pin moved and we didn't
        // account for it by either calling cursorReload or manually
        // adjusting.
        const pt: point.Point = self.pages.pointFromPin(
            .active,
            self.cursor.page_pin.*,
        ) orelse unreachable;
        assert(self.cursor.x == pt.active.x);
        assert(self.cursor.y == pt.active.y);
    }
}

/// Reset the screen according to the logic of a DEC RIS sequence.
///
/// - Clears the screen and attempts to reclaim memory.
/// - Moves the cursor to the top-left.
/// - Clears any cursor state: style, hyperlink, etc.
/// - Resets the charset
/// - Clears the selection
/// - Deletes all Kitty graphics
/// - Resets Kitty Keyboard settings
/// - Disables protection mode
///
pub fn reset(self: *Screen) void {
    // Reset our pages
    self.pages.reset();

    // The above reset preserves tracked pins so we can still use
    // our cursor pin, which should be at the top-left already.
    const cursor_pin: *PageList.Pin = self.cursor.page_pin;
    assert(cursor_pin.node == self.pages.pages.first.?);
    assert(cursor_pin.x == 0);
    assert(cursor_pin.y == 0);
    const cursor_rac = cursor_pin.rowAndCell();
    self.cursor.deinit(self.alloc);
    self.cursor = .{
        .page_pin = cursor_pin,
        .page_row = cursor_rac.row,
        .page_cell = cursor_rac.cell,
    };

    if (comptime build_options.kitty_graphics) {
        // Reset kitty graphics storage
        self.kitty_images.deinit(self.alloc, self);
        self.kitty_images = .{ .dirty = true };
    }

    // Reset our basic state
    self.saved_cursor = null;
    self.charset = .{};
    self.kitty_keyboard = .{};
    self.protected_mode = .off;
    self.semantic_prompt = .disabled;
    self.clearSelection();
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
///   - Current hyperlink cursor state has heap allocations. Since clone
///     is only for read-only operations, it is better to not have any
///     hyperlink state. Note that already-written hyperlinks are cloned.
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
    // Create a tracked pin remapper for our selection and cursor. Note
    // that we may want to expose this generally in the future but at the
    // time of doing this we don't need to.
    var pin_remap = PageList.Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();

    var pages = try self.pages.clone(alloc, .{
        .top = top,
        .bot = bot,
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

        const page_pin = try pages.trackPin(.{ .node = pages.pages.first.? });
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
            // No start means it is outside the cloned area.

            // If we have no end pin then either
            // (1) our whole selection is outside the cloned area or
            // (2) our cloned area is within the selection
            if (pin_remap.get(ordered.br) == null) {
                // We check if the selection bottom right pin is above
                // the cloned area or if the top left pin is below the
                // cloned area, in either of these cases it means that
                // the selection is fully out of bounds, so we have no
                // selection in the cloned area and break out now.
                const clone_top = self.pages.pin(top) orelse break :sel null;
                const clone_top_y = self.pages.pointFromPin(
                    .screen,
                    clone_top,
                ).?.screen.y;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.br.*,
                ).?.screen.y < clone_top_y) break :sel null;
                if (self.pages.pointFromPin(
                    .screen,
                    ordered.tl.*,
                ).?.screen.y > clone_top_y) break :sel null;
            }

            // We move the top pin back in bounds to the top row.
            break :start try pages.trackPin(.{
                .node = pages.pages.first.?,
                .x = if (sel.rectangle) ordered.tl.x else 0,
            });
        };

        // If we got to this point it means that the selection is not
        // fully out of bounds, so we move the bottom right pin back
        // in bounds if it isn't already.
        const end_pin = pin_remap.get(ordered.br) orelse try pages.trackPin(.{
            .node = pages.pages.last.?,
            .x = if (sel.rectangle) ordered.br.x else pages.cols - 1,
            .y = pages.pages.last.?.data.size.rows - 1,
        });

        break :sel .{
            .bounds = .{ .tracked = .{
                .start = start_pin,
                .end = end_pin,
            } },
            .rectangle = sel.rectangle,
        };
    } else null;

    const result: Screen = .{
        .alloc = alloc,
        .pages = pages,
        .no_scrollback = self.no_scrollback,
        .cursor = cursor,
        .selection = sel,
        .dirty = self.dirty,
    };
    result.assertIntegrity();
    return result;
}
pub fn increaseCapacity(
    self: *Screen,
    node: *PageList.List.Node,
    adjustment: ?PageList.IncreaseCapacity,
) PageList.IncreaseCapacityError!*PageList.List.Node {
    // If the page being modified isn't our cursor page then
    // this is a quick operation because we have no additional
    // accounting. We have to do this check here BEFORE calling
    // increaseCapacity because increaseCapacity will update all
    // our tracked pins (including our cursor).
    if (node != self.cursor.page_pin.node) return try self.pages.increaseCapacity(
        node,
        adjustment,
    );

    // We're modifying the cursor page. When we increase the
    // capacity below it will be short the ref count on our
    // current style and hyperlink, so we need to init those.
    const new_node = try self.pages.increaseCapacity(node, adjustment);
    const new_page: *Page = &new_node.data;

    // Re-add the style, if the page somehow doesn't have enough
    // memory to add it, we emit a warning and gracefully degrade
    // to the default style for the cursor.
    if (self.cursor.style_id != style.default_id) {
        self.cursor.style_id = new_page.styles.add(
            new_page.memory,
            self.cursor.style,
        ) catch |err| id: {
            // TODO: Should we increase the capacity further in this case?
            log.warn(
                "(Screen.increaseCapacity) Failed to add cursor style back to page, err={}",
                .{err},
            );

            // Reset the cursor style.
            self.cursor.style = .{};
            break :id style.default_id;
        };
    }

    // Re-add the hyperlink, if the page somehow doesn't have enough
    // memory to add it, we emit a warning and gracefully degrade to
    // no hyperlink.
    if (self.cursor.hyperlink) |link| {
        // So we don't attempt to free any memory in the replaced page.
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;

        // Re-add
        self.startHyperlinkOnce(link.*) catch |err| {
            // TODO: Should we increase the capacity further in this case?
            log.warn(
                "(Screen.increaseCapacity) Failed to add cursor hyperlink back to page, err={}",
                .{err},
            );
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }

    // Reload the cursor information because the pin changed.
    // So our page row/cell and so on are all off.
    self.cursorReload();

    return new_node;
}

pub inline fn cursorCellRight(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x + n < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + n);
}

pub inline fn cursorCellLeft(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
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
    defer self.assertIntegrity();

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell + n);
    self.cursor.page_pin.x += n;
    self.cursor.x += n;
}

/// Move the cursor left.
pub fn cursorLeft(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x >= n);
    defer self.assertIntegrity();

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
    defer self.assertIntegrity();

    self.cursor.y -= n; // Must be set before cursorChangePin
    self.cursorChangePin(self.cursor.page_pin.up(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

pub fn cursorRowUp(self: *Screen, n: size.CellCountInt) *pagepkg.Row {
    assert(self.cursor.y >= n);
    defer self.assertIntegrity();

    const page_pin = self.cursor.page_pin.up(n).?;
    const page_rac = page_pin.rowAndCell();
    return page_rac.row;
}

/// Move the cursor down.
///
/// Precondition: The cursor is not at the bottom of the screen.
pub fn cursorDown(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y + n < self.pages.rows);
    defer self.assertIntegrity();

    self.cursor.y += n; // Must be set before cursorChangePin

    // We move the offset into our page list to the next row and then
    // get the pointers to the row/cell and set all the cursor state up.
    self.cursorChangePin(self.cursor.page_pin.down(n).?);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Move the cursor to some absolute horizontal position.
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);
    defer self.assertIntegrity();

    self.cursor.page_pin.x = x;
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}

/// Move the cursor to some absolute position.
pub fn cursorAbsolute(self: *Screen, x: size.CellCountInt, y: size.CellCountInt) void {
    assert(x < self.pages.cols);
    assert(y < self.pages.rows);
    defer self.assertIntegrity();

    var page_pin = if (y < self.cursor.y)
        self.cursor.page_pin.up(self.cursor.y - y).?
    else if (y > self.cursor.y)
        self.cursor.page_pin.down(y - self.cursor.y).?
    else
        self.cursor.page_pin.*;
    page_pin.x = x;
    self.cursor.x = x; // Must be set before cursorChangePin
    self.cursor.y = y;
    self.cursorChangePin(page_pin);
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Reloads the cursor pointer information into the screen. This is expensive
/// so it should only be done in cases where the pointers are invalidated
/// in such a way that its difficult to recover otherwise.
pub fn cursorReload(self: *Screen) void {
    defer self.assertIntegrity();

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

    // If we have a style, we need to ensure it is in the page because this
    // method may also be called after a page change.
    if (self.cursor.style_id != style.default_id) {
        self.manualStyleUpdate() catch |err| {
            // This failure should not happen because manualStyleUpdate
            // handles page splitting, overflow, and more. This should only
            // happen if we're out of RAM. In this case, we'll just degrade
            // gracefully back to the default style.
            log.err("failed to update style on cursor reload err={}", .{err});
            self.cursor.style = .{};
            self.cursor.style_id = 0;
        };
    }
}

/// Scroll the active area and keep the cursor at the bottom of the screen.
/// This is a very specialized function but it keeps it fast.
pub fn cursorDownScroll(self: *Screen) !void {
    assert(self.cursor.y == self.pages.rows - 1);
    defer self.assertIntegrity();

    if (comptime build_options.kitty_graphics) {
        // Scrolling dirties the images because it updates their placements pins.
        self.kitty_images.dirty = true;
    }

    // If we have no scrollback, then we shift all our rows instead.
    if (self.no_scrollback) {
        // If we have a single-row screen, we have no rows to shift
        // so our cursor is in the correct place we just have to clear
        // the cells.
        if (self.pages.rows == 1) {
            const page: *Page = &self.cursor.page_pin.node.data;
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );
            self.cursorMarkDirty();
        } else {
            // The call to `eraseRow` will move the tracked cursor pin up by one
            // row, but we don't actually want that, so we keep the old pin and
            // put it back after calling `eraseRow`.
            const old_pin = self.cursor.page_pin.*;

            // eraseRow will shift everything below it up.
            try self.pages.eraseRow(.{ .active = .{} });

            // Note we don't need to mark anything dirty in this branch
            // because eraseRow will mark all the rotated rows as dirty
            // in the entire page.

            // We don't use `cursorChangePin` here because we aren't
            // actually changing the pin, we're keeping it the same.
            self.cursor.page_pin.* = old_pin;

            // We do, however, need to refresh the cached page row
            // and cell, because `eraseRow` will have moved the row.
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        }
    } else {
        const old_pin = self.cursor.page_pin.*;

        // Grow our pages by one row. The PageList will handle if we need to
        // allocate, prune scrollback, whatever.
        _ = try self.pages.grow();

        self.cursorChangePin(new_pin: {
            // We do this all in a block here because referencing this pin
            // after cursorChangePin is unsafe, and we want to keep it out
            // of scope.

            // If our pin page change it means that the page that the pin
            // was on was pruned. In this case, grow() moves the pin to
            // the top-left of the new page. This effectively moves it by
            // one already, we just need to fix up the x value.
            const page_pin = if (old_pin.node == self.cursor.page_pin.node)
                self.cursor.page_pin.down(1).?
            else reuse: {
                var pin = self.cursor.page_pin.*;
                pin.x = self.cursor.x;
                break :reuse pin;
            };

            // These assertions help catch some pagelist math errors. Our
            // x/y should be unchanged after the grow.
            if (build_options.slow_runtime_safety) {
                const active = self.pages.pointFromPin(
                    .active,
                    page_pin,
                ).?.active;
                assert(active.x == self.cursor.x);
                assert(active.y == self.cursor.y);
            }

            break :new_pin page_pin;
        });
        const page_rac = self.cursor.page_pin.rowAndCell();
        self.cursor.page_row = page_rac.row;
        self.cursor.page_cell = page_rac.cell;

        // Our new row is always dirty
        self.cursorMarkDirty();

        // Clear the new row so it gets our bg color. We only do this
        // if we have a bg color at all.
        if (self.cursor.style.bg_color != .none) {
            const page: *Page = &self.cursor.page_pin.node.data;
            self.clearCells(
                page,
                self.cursor.page_row,
                page.getCells(self.cursor.page_row),
            );
        }
    }

    if (self.cursor.style_id != style.default_id) {
        // The newly created line needs to be styled according to
        // the bg color if it is set.
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

/// This scrolls the active area at and above the cursor.
/// The lines below the cursor are not scrolled.
pub fn cursorScrollAbove(self: *Screen) !void {
    // We unconditionally mark the cursor row as dirty here because
    // the cursor always changes page rows inside this function, and
    // when that happens it can mean the text in the old row needs to
    // be re-shaped because the cursor splits runs to break ligatures.
    self.cursorMarkDirty();

    // If the cursor is on the bottom of the screen, its faster to use
    // our specialized function for that case.
    if (self.cursor.y == self.pages.rows - 1) {
        return try self.cursorDownScroll();
    }

    defer self.assertIntegrity();

    // Logic below assumes we always have at least one row that isn't moving
    assert(self.cursor.y < self.pages.rows - 1);

    // Explanation:
    //  We don't actually move everything that's at or above the cursor row,
    //  since this would require us to shift up our ENTIRE scrollback, which
    //  would be ridiculously expensive. Instead, we insert a new row at the
    //  end of the pagelist (`grow()`), and move everything BELOW the cursor
    //  DOWN by one row. This has the same practical result but it's a whole
    //  lot cheaper in 99% of cases.

    const old_pin = self.cursor.page_pin.*;
    if (try self.pages.grow()) |_| {
        try self.cursorScrollAboveRotate();
    } else {
        // In this case, it means grow() didn't allocate a new page.

        if (self.cursor.page_pin.node == self.pages.pages.last) {
            // If we're on the last page we can do a very fast path because
            // all the rows we need to move around are within a single page.

            // Note: we don't need to call cursorChangePin here because
            // the pin page is the same so there is no accounting to do
            // for styles or any of that.
            assert(old_pin.node == self.cursor.page_pin.node);
            self.cursor.page_pin.* = self.cursor.page_pin.down(1).?;

            const pin = self.cursor.page_pin;
            const page: *Page = &self.cursor.page_pin.node.data;

            // Rotate the rows so that the newly created empty row is at the
            // beginning. e.g. [ 0 1 2 3 ] in to [ 3 0 1 2 ].
            var rows = page.rows.ptr(page.memory.ptr);
            fastmem.rotateOnceR(Row, rows[pin.y..page.size.rows]);

            // Mark the whole page as dirty.
            //
            // Technically we only need to mark from the cursor row to the
            // end but this is a hot function, so we want to minimize work.
            page.dirty = true;

            // Setup our cursor caches after the rotation so it points to the
            // correct data
            const page_rac = self.cursor.page_pin.rowAndCell();
            self.cursor.page_row = page_rac.row;
            self.cursor.page_cell = page_rac.cell;
        } else {
            // We didn't grow pages but our cursor isn't on the last page.
            // In this case we need to do more work because we need to copy
            // elements between pages.
            //
            // An example scenario of this is shown below:
            //
            //      +----------+ = PAGE 0
            //  ... :          :
            //     +-------------+ ACTIVE
            // 4302 |1A00000000| | 0
            // 4303 |2B00000000| | 1
            //      :^         : : = PIN 0
            // 4304 |3C00000000| | 2
            //      +----------+ :
            //      +----------+ : = PAGE 1
            //    0 |4D00000000| | 3
            //    1 |5E00000000| | 4
            //      +----------+ :
            //     +-------------+
            try self.cursorScrollAboveRotate();
        }
    }

    if (self.cursor.style_id != style.default_id) {
        // The newly created line needs to be styled according to
        // the bg color if it is set.
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

fn cursorScrollAboveRotate(self: *Screen) !void {
    self.cursorChangePin(self.cursor.page_pin.down(1).?);

    // Go through each of the pages following our pin, shift all rows
    // down by one, and copy the last row of the previous page.
    var current = self.pages.pages.last.?;
    while (current != self.cursor.page_pin.node) : (current = current.prev.?) {
        const prev = current.prev.?;
        const prev_page = &prev.data;
        const cur_page = &current.data;
        const prev_rows = prev_page.rows.ptr(prev_page.memory.ptr);
        const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);

        // Rotate the pages down: [ 0 1 2 3 ] => [ 3 0 1 2 ]
        fastmem.rotateOnceR(Row, cur_rows[0..cur_page.size.rows]);

        // Copy the last row of the previous page to the top of current.
        try cur_page.cloneRowFrom(
            prev_page,
            &cur_rows[0],
            &prev_rows[prev_page.size.rows - 1],
        );

        // Mark dirty on the page, since we are dirtying all rows with this.
        cur_page.dirty = true;
    }

    // Our current is our cursor page, we need to rotate down from
    // our cursor and clear our row.
    assert(current == self.cursor.page_pin.node);
    const cur_page = &current.data;
    const cur_rows = cur_page.rows.ptr(cur_page.memory.ptr);
    fastmem.rotateOnceR(Row, cur_rows[self.cursor.page_pin.y..cur_page.size.rows]);
    self.clearCells(
        cur_page,
        &cur_rows[self.cursor.page_pin.y],
        cur_page.getCells(&cur_rows[self.cursor.page_pin.y]),
    );

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark from the cursor row to the
    // end but this is a hot function, so we want to minimize work.
    cur_page.dirty = true;

    // Setup cursor cache data after all the rotations so our
    // row is valid.
    const page_rac = self.cursor.page_pin.rowAndCell();
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Move the cursor down if we're not at the bottom of the screen. Otherwise
/// scroll. Currently only used for testing.
inline fn cursorDownOrScroll(self: *Screen) !void {
    if (self.cursor.y + 1 < self.pages.rows) {
        self.cursorDown(1);
    } else {
        try self.cursorDownScroll();
    }
}

/// Copy another cursor. The cursor can be on any screen but the x/y
/// must be within our screen bounds.
pub fn cursorCopy(self: *Screen, other: Cursor, opts: struct {
    /// Copy the hyperlink from the other cursor. If not set, this will
    /// clear our current hyperlink.
    hyperlink: bool = true,
}) !void {
    assert(other.x < self.pages.cols);
    assert(other.y < self.pages.rows);

    // End any currently active hyperlink on our cursor.
    self.endHyperlink();

    const old = self.cursor;
    self.cursor = other;
    errdefer self.cursor = old;

    // Keep our old style ID so it can be properly cleaned up below.
    self.cursor.style_id = old.style_id;

    // Hyperlinks will be managed separately below.
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;

    // Keep our old page pin and X/Y because:
    // 1. The old style will need to be cleaned up from the page it's from.
    // 2. The new position navigated to by `cursorAbsolute` needs to be in our
    //    own screen.
    self.cursor.page_pin = old.page_pin;
    self.cursor.x = old.x;
    self.cursor.y = old.y;

    // Call manual style update in order to clean up our old style, if we have
    // one, and also to load the style from the other cursor, if it had one.
    try self.manualStyleUpdate();

    // Move to the correct location to match the other cursor.
    self.cursorAbsolute(other.x, other.y);

    // If the other cursor had a hyperlink, add it to ours.
    if (opts.hyperlink and other.hyperlink_id != 0) {
        // Get the hyperlink from the other cursor's page.
        const other_page = &other.page_pin.node.data;
        const other_link = other_page.hyperlink_set.get(other_page.memory, other.hyperlink_id);

        const uri = other_link.uri.slice(other_page.memory);
        const id_ = switch (other_link.id) {
            .explicit => |id| id.slice(other_page.memory),
            .implicit => null,
        };

        // And it to our cursor.
        self.startHyperlink(uri, id_) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };
    }
}

/// Always use this to write to cursor.page_pin.*.
///
/// This specifically handles the case when the new pin is on a different
/// page than the old AND we have a style or hyperlink set. In that case,
/// we must release our old one and insert the new one, since styles are
/// stored per-page.
///
/// Note that this can change the cursor pin AGAIN if the process of
/// setting up our cursor forces a capacity adjustment of the underlying
/// cursor page, so any references to the page pin should be re-read
/// from `self.cursor.page_pin` after calling this.
inline fn cursorChangePin(self: *Screen, new: Pin) void {
    // Moving the cursor affects text run splitting (ligatures) so
    // we must mark the old and new page dirty. We do this as long
    // as the pins are not equal
    if (!self.cursor.page_pin.eql(new)) {
        self.cursorMarkDirty();
        new.markDirty();
    }

    // If our pin is on the same page, then we can just update the pin.
    // We don't need to migrate any state.
    if (self.cursor.page_pin.node == new.node) {
        self.cursor.page_pin.* = new;
        return;
    }

    // If we have an old style then we need to release it from the old page.
    const old_style_: ?style.Style = if (self.cursor.style_id == style.default_id)
        null
    else
        self.cursor.style;
    if (old_style_ != null) {
        // Release the style directly from the old page instead of going through
        // manualStyleUpdate, because the cursor position may have already been
        // updated but the pin has not, which would fail integrity checks.
        const old_page: *Page = &self.cursor.page_pin.node.data;
        old_page.styles.release(old_page.memory, self.cursor.style_id);
        self.cursor.style = .{};
        self.cursor.style_id = style.default_id;
    }

    // If we have a hyperlink then we need to release it from the old page.
    if (self.cursor.hyperlink != null) {
        const old_page: *Page = &self.cursor.page_pin.node.data;
        old_page.hyperlink_set.release(old_page.memory, self.cursor.hyperlink_id);
    }

    // Update our pin to the new page
    self.cursor.page_pin.* = new;

    // On the new page, we need to migrate our style
    if (old_style_) |old_style| {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            // This failure should not happen because manualStyleUpdate
            // handles page splitting, overflow, and more. This should only
            // happen if we're out of RAM. In this case, we'll just degrade
            // gracefully back to the default style.
            log.err("failed to update style on cursor change err={}", .{err});
            self.cursor.style = .{};
            self.cursor.style_id = 0;
        };
    }

    // On the new page, we need to migrate our hyperlink
    if (self.cursor.hyperlink) |link| {
        // So we don't attempt to free any memory in the replaced page.
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;

        // Re-add
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on cursor change err={}", .{err});
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
}

/// Mark the cursor position as dirty.
/// TODO: test
pub inline fn cursorMarkDirty(self: *Screen) void {
    self.cursor.page_row.dirty = true;
}

/// Reset the cursor row's soft-wrap state and the cursor's pending wrap.
/// Also handles clearing the spacer head on the cursor row and resetting
/// the wrap_continuation flag on the next row if necessary.
///
/// NOTE(qwerasd): This method is not scrolling region aware, and cannot be
/// since it's on Screen not Terminal. This needs to be addressed down the
/// line. Not an extremely urgent issue since it's an edge case of an edge
/// case, but not ideal.
pub fn cursorResetWrap(self: *Screen) void {
    // Reset the cursor's pending wrap state
    self.cursor.pending_wrap = false;

    const page_row = self.cursor.page_row;

    if (!page_row.wrap) return;

    // This row does not wrap and the next row is not wrapped to
    page_row.wrap = false;

    if (self.cursor.page_pin.down(1)) |next_row| {
        next_row.rowAndCell().row.wrap_continuation = false;
    }

    // If the last cell in the row is a spacer head we need to clear it.
    const cells = self.cursor.page_pin.cells(.all);
    const cell = cells[self.cursor.page_pin.node.data.size.cols - 1];
    if (cell.wide == .spacer_head) {
        self.clearCells(
            &self.cursor.page_pin.node.data,
            page_row,
            cells[self.cursor.page_pin.node.data.size.cols - 1 ..][0..1],
        );
    }
}

/// Options for scrolling the viewport of the terminal grid. The reason
/// we have this in addition to PageList.Scroll is because we have additional
/// scroll behaviors that are not part of the PageList.Scroll enum.
pub const Scroll = union(enum) {
    /// For all of these, see PageList.Scroll.
    active,
    top,
    pin: Pin,
    row: usize,
    delta_row: isize,
    delta_prompt: isize,
};

/// Scroll the viewport of the terminal grid.
pub inline fn scroll(self: *Screen, behavior: Scroll) void {
    defer self.assertIntegrity();

    if (comptime build_options.kitty_graphics) {
        // No matter what, scrolling marks our image state as dirty since
        // it could move placements. If there are no placements or no images
        // this is still a very cheap operation.
        self.kitty_images.dirty = true;
    }

    switch (behavior) {
        .active => self.pages.scroll(.{ .active = {} }),
        .top => self.pages.scroll(.{ .top = {} }),
        .pin => |p| self.pages.scroll(.{ .pin = p }),
        .row => |v| self.pages.scroll(.{ .row = v }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
        .delta_prompt => |v| self.pages.scroll(.{ .delta_prompt = v }),
    }
}

/// See PageList.scrollClear. In addition to that, we reset the cursor
/// to be on top.
pub inline fn scrollClear(self: *Screen) !void {
    defer self.assertIntegrity();

    try self.pages.scrollClear();
    self.cursorReload();

    if (comptime build_options.kitty_graphics) {
        // No matter what, scrolling marks our image state as dirty since
        // it could move placements. If there are no placements or no images
        // this is still a very cheap operation.
        self.kitty_images.dirty = true;
    }
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub inline fn viewportIsBottom(self: Screen) bool {
    return self.pages.viewport == .active;
}

/// Erase the region specified by tl and br, inclusive. This will physically
/// erase the rows meaning the memory will be reclaimed (if the underlying
/// page is empty) and other rows will be shifted up.
pub inline fn eraseRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
) void {
    defer self.assertIntegrity();

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
    defer self.assertIntegrity();

    var it = self.pages.pageIterator(.right_down, tl, bl);
    while (it.next()) |chunk| {
        for (chunk.rows()) |*row| {
            const cells_offset = row.cells;
            const cells_multi: [*]Cell = row.cells.ptr(chunk.node.data.memory);
            const cells = cells_multi[0..self.pages.cols];

            // Clear all cells
            if (protected) {
                self.clearUnprotectedCells(&chunk.node.data, row, cells);
                // We need to preserve other row attributes since we only
                // cleared unprotected cells.
                row.cells = cells_offset;
            } else {
                self.clearCells(&chunk.node.data, row, cells);
                row.* = .{ .cells = cells_offset };
            }

            row.dirty = true;
        }
    }
}

/// Clear the cells with the blank cell.
///
/// This takes care to handle cleaning up graphemes and styles.
pub fn clearCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    // This whole operation does unsafe things, so we just want to assert
    // the end state.
    page.pauseIntegrityChecks(true);
    defer {
        page.pauseIntegrityChecks(false);
        page.assertIntegrity();
        self.assertIntegrity();
    }

    if (comptime std.debug.runtime_safety) {
        // Our row and cells should be within the page.
        const page_rows = page.rows.ptr(page.memory.ptr);
        assert(@intFromPtr(row) >= @intFromPtr(&page_rows[0]));
        assert(@intFromPtr(row) <= @intFromPtr(&page_rows[page.size.rows - 1]));

        const row_cells = page.getCells(row);
        assert(@intFromPtr(&cells[0]) >= @intFromPtr(&row_cells[0]));
        assert(@intFromPtr(&cells[cells.len - 1]) <= @intFromPtr(&row_cells[row_cells.len - 1]));
    }

    // If we have managed memory (styles, graphemes, or hyperlinks)
    // in this row then we go cell by cell and clear them if present.
    if (row.grapheme) {
        for (cells) |*cell| {
            if (cell.hasGrapheme())
                page.clearGrapheme(cell);
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the graphemes, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == self.pages.cols) {
            row.grapheme = false;
        } else {
            page.updateRowGraphemeFlag(row);
        }
    }

    if (row.hyperlink) {
        for (cells) |*cell| {
            if (cell.hyperlink)
                page.clearHyperlink(cell);
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the hyperlinks, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == self.pages.cols) {
            row.hyperlink = false;
        } else {
            page.updateRowHyperlinkFlag(row);
        }
    }

    if (row.styled) {
        for (cells) |*cell| {
            if (cell.hasStyling())
                page.styles.release(page.memory, cell.style_id);
        }

        // If we have no left/right scroll region we can be sure
        // that we've cleared all the styles, so we clear the
        // flag, otherwise we ask the page to update the flag.
        if (cells.len == self.pages.cols) {
            row.styled = false;
        } else {
            page.updateRowStyledFlag(row);
        }
    }

    if (comptime build_options.kitty_graphics) {
        if (row.kitty_virtual_placeholder and
            cells.len == self.pages.cols)
        {
            for (cells) |c| {
                if (c.codepoint() == kitty.graphics.unicode.placeholder) {
                    break;
                }
            } else row.kitty_virtual_placeholder = false;
        }
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
    var x0: usize = 0;
    var x1: usize = 0;

    while (x0 < cells.len) clear: {
        while (cells[x0].protected) {
            x0 += 1;
            if (x0 >= cells.len) break :clear;
        }
        x1 = x0 + 1;
        while (x1 < cells.len and !cells[x1].protected) {
            x1 += 1;
        }
        self.clearCells(page, row, cells[x0..x1]);
        x0 = x1;
    }

    page.assertIntegrity();
    self.assertIntegrity();
}

/// Clean up boundary conditions where a cell will become discontiguous with
/// a neighboring cell because either one of them will be moved and/or cleared.
///
/// For performance reasons this is specialized to operate on the cursor row.
///
/// Handles the boundary between the cell at `x` and the cell at `x - 1`.
///
/// So, for example, when moving a region of cells [a, b] (inclusive), call this
/// function with `x = a` and `x = b + 1`. It is okay if `x` is out of bounds by
/// 1, this will be interpreted correctly.
///
/// DOES NOT MODIFY ROW WRAP STATE! See `cursorResetWrap` for that.
///
/// The following boundary conditions are handled:
///
/// - `x - 1` is a wide character and `x` is a spacer tail:
///   o Both cells will be cleared.
///   o If `x - 1` is the start of the row and was wrapped from a previous row
///     then the previous row is checked for a spacer head, which is cleared if
///     present.
///
/// - `x == 0` and is a wide character:
///   o If the row is a wrap continuation then the previous row will be checked
///     for a spacer head, which is cleared if present.
///
/// - `x == cols` and `x - 1` is a spacer head:
///   o `x - 1` will be cleared.
///
/// NOTE(qwerasd): This method is not scrolling region aware, and cannot be
/// since it's on Screen not Terminal. This needs to be addressed down the
/// line. Not an extremely urgent issue since it's an edge case of an edge
/// case, but not ideal.
pub fn splitCellBoundary(
    self: *Screen,
    x: size.CellCountInt,
) void {
    const page = &self.cursor.page_pin.node.data;

    page.pauseIntegrityChecks(true);
    defer page.pauseIntegrityChecks(false);

    const cols = self.cursor.page_pin.node.data.size.cols;

    // `x` may be up to an INCLUDING `cols`, since that signifies splitting
    // the boundary to the right of the final cell in the row.
    assert(x <= cols);

    // [ A B C D E F|]
    //              ^ Boundary between final cell and row end.
    if (x == cols) {
        if (!self.cursor.page_row.wrap) return;

        const cells = self.cursor.page_pin.cells(.all);

        // Spacer head at end of wrapped row.
        if (cells[cols - 1].wide == .spacer_head) {
            self.clearCells(
                page,
                self.cursor.page_row,
                cells[cols - 1 ..][0..1],
            );
        }

        return;
    }

    // [|A B C D E F ]
    //  ^ Boundary between first cell and row start.
    //
    //  OR
    //
    // [ A|B C D E F ]
    //    ^ Boundary between first cell and second cell.
    //
    // First cell may be a wrapped wide cell with a spacer
    // head on the previous row that needs to be cleared.
    if ((x == 0 or x == 1) and self.cursor.page_row.wrap_continuation) {
        const cells = self.cursor.page_pin.cells(.all);

        // If the first cell in a row is wide the previous row
        // may have a spacer head which needs to be cleared.
        if (cells[0].wide == .wide) {
            if (self.cursor.page_pin.up(1)) |p_row| {
                const p_rac = p_row.rowAndCell();
                const p_cells = p_row.cells(.all);
                const p_cell = p_cells[p_row.node.data.size.cols - 1];
                if (p_cell.wide == .spacer_head) {
                    self.clearCells(
                        &p_row.node.data,
                        p_rac.row,
                        p_cells[p_row.node.data.size.cols - 1 ..][0..1],
                    );
                }
            }
        }
    }

    // If x is 0 then we're done.
    if (x == 0) return;

    // [ ... X|Y ... ]
    //        ^ Boundary between two cells in the middle of the row.
    {
        assert(x > 0);
        assert(x < cols);

        const cells = self.cursor.page_pin.cells(.all);

        const left = cells[x - 1];
        switch (left.wide) {
            // There should not be spacer heads in the middle of the row.
            .spacer_head => unreachable,

            // We don't need to do anything for narrow cells or spacer tails.
            .narrow, .spacer_tail => {},

            // A wide char would be split, so must be cleared.
            .wide => {
                self.clearCells(
                    page,
                    self.cursor.page_row,
                    cells[x - 1 ..][0..2],
                );
            },
        }
    }
}

/// Returns the blank cell to use when doing terminal operations that
/// require preserving the bg color.
pub inline fn blankCell(self: *const Screen) Cell {
    if (self.cursor.style_id == style.default_id) return .{};
    return self.cursor.style.bgCell() orelse .{};
}

pub const Resize = struct {
    /// The new size to resize to
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// Whether to reflow soft-wrapped text.
    ///
    /// This will reflow soft-wrapped text. If the screen size is getting
    /// smaller and the maximum scrollback size is exceeded, data will be
    /// lost from the top of the scrollback.
    reflow: bool = true,

    /// Set this to enable prompt redraw on resize. This signals
    /// that the running program can redraw the prompt if the cursor is
    /// currently at a prompt. This detects OSC133 prompts lines and clears
    /// them. If set to `.last`, only the most recent prompt line is cleared.
    prompt_redraw: osc.semantic_prompt.Redraw = .false,
};

/// Resize the screen. The rows or cols can be bigger or smaller.
///
/// If this returns an error, the screen is left in a likely garbage state.
/// It is very hard to undo this operation without blowing up our memory
/// usage. The only way to recover is to reset the screen. The only way
/// this really fails is if page allocation is required and fails, which
/// probably means the system is in trouble anyways. I'd like to improve this
/// in the future but it is not a priority particularly because this scenario
/// (resize) is difficult.
pub inline fn resize(
    self: *Screen,
    opts: Resize,
) !void {
    defer self.assertIntegrity();

    if (comptime build_options.kitty_graphics) {
        // No matter what we mark our image state as dirty
        self.kitty_images.dirty = true;
    }

    // Release the cursor style while resizing just
    // in case the cursor ends up on a different page.
    const cursor_style = self.cursor.style;
    self.cursor.style = .{};
    self.manualStyleUpdate() catch unreachable;
    defer {
        // Restore the cursor style.
        self.cursor.style = cursor_style;
        self.manualStyleUpdate() catch |err| {
            // This failure should not happen because manualStyleUpdate
            // handles page splitting, overflow, and more. This should only
            // happen if we're out of RAM. In this case, we'll just degrade
            // gracefully back to the default style.
            log.err("failed to update style on cursor reload err={}", .{err});
            self.cursor.style = .{};
            self.cursor.style_id = 0;
        };
    }

    // If we have a hyperlink, release it from the old page
    // and then we need to re-add it to the new page. This needs
    // to happen because resize below typically reallocates a
    // new page so the old hyperlink is invalid.
    const hyperlink_ = self.cursor.hyperlink;
    if (self.cursor.hyperlink_id != 0) {
        // Note we do NOT use endHyperlink because we want to keep
        // our allocated self.cursor.hyperlink valid.
        var page = &self.cursor.page_pin.node.data;
        page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = null;
    }

    // We need to insert a tracked pin for our saved cursor so we can
    // modify its X/Y for reflow.
    const saved_cursor_pin: ?*Pin = saved_cursor: {
        const sc = self.saved_cursor orelse break :saved_cursor null;
        const pin = self.pages.pin(.{ .active = .{
            .x = sc.x,
            .y = sc.y,
        } }) orelse break :saved_cursor null;
        break :saved_cursor try self.pages.trackPin(pin);
    };
    defer if (saved_cursor_pin) |p| self.pages.untrackPin(p);

    // If our cursor is on a prompt or input line, clear it so the shell can
    // redraw it. This works with OSC 133 semantic prompts.
    //
    // We check cursor.semantic_content rather than page_row.semantic_prompt
    // because some shells (e.g., Nu) mark input areas with OSC 133 B but don't
    // mark continuation lines with k=s. If the input spans multiple lines and
    // continuation lines are unmarked, checking only page_row.semantic_prompt
    // would miss them. By checking semantic_content, we assume that if the
    // cursor is on anything other than command output, we're at a prompt/input
    // line and should clear from there.
    if (opts.prompt_redraw != .false and
        self.cursor.semantic_content != .output)
    prompt: {
        switch (opts.prompt_redraw) {
            .false => unreachable,

            // For `.last`, only clear the current line where the cursor is.
            // For `.true`, clear all prompt lines starting from the beginning.
            .last => {
                const page = &self.cursor.page_pin.node.data;
                const row = self.cursor.page_row;
                const cells = page.getCells(row);
                self.clearCells(page, row, cells);
            },

            .true => {
                const start = start: {
                    var it = self.cursor.page_pin.promptIterator(
                        .left_up,
                        null,
                    );
                    break :start it.next() orelse {
                        // This should never happen because promptIterator should always
                        // find a prompt if we already verified our row is some kind of
                        // prompt.
                        log.warn("cursor on prompt line but promptIterator found no prompt", .{});
                        break :prompt;
                    };
                };

                // Clear cells from our start down. We replace it with spaces,
                // and do not physically erase the rows (eraseRows) because the
                // shell is going to expect this space to be available.
                var it = start.rowIterator(.right_down, null);
                while (it.next()) |pin| {
                    const page = &pin.node.data;
                    const row = pin.rowAndCell().row;
                    const cells = page.getCells(row);
                    self.clearCells(page, row, cells);
                }
            },
        }
    }

    // Perform the resize operation.
    try self.pages.resize(.{
        .rows = opts.rows,
        .cols = opts.cols,
        .reflow = opts.reflow,
        .cursor = .{ .x = self.cursor.x, .y = self.cursor.y },
    });

    // If we have no scrollback and we shrunk our rows, we must explicitly
    // erase our history. This is because PageList always keeps at least
    // a page size of history.
    if (self.no_scrollback) {
        self.pages.eraseRows(.{ .history = .{} }, null);
    }

    // If our cursor was updated, we do a full reload so all our cursor
    // state is correct.
    self.cursorReload();

    // If we reflowed a saved cursor, update it.
    if (saved_cursor_pin) |p| {
        // This should never fail because a non-null saved_cursor_pin
        // implies a non-null saved_cursor.
        const sc = &self.saved_cursor.?;
        if (self.pages.pointFromPin(.active, p.*)) |pt| {
            sc.x = @intCast(pt.active.x);
            sc.y = @intCast(pt.active.y);

            // If we had pending wrap set and we're no longer at the end of
            // the line, we unset the pending wrap and move the cursor to
            // reflect the correct next position.
            if (sc.pending_wrap and sc.x != opts.cols - 1) {
                sc.pending_wrap = false;
                sc.x += 1;
            }
        } else {
            // I think this can happen if the screen is resized to be
            // less rows or less cols and our saved cursor moves outside
            // the active area. In this case, there isn't anything really
            // reasonable we can do so we just move the cursor to the
            // top-left. It may be reasonable to also move the cursor to
            // match the primary cursor. Any behavior is fine since this is
            // totally unspecified.
            sc.x = 0;
            sc.y = 0;
            sc.pending_wrap = false;
        }
    }

    // Fix up our hyperlink if we had one.
    if (hyperlink_) |link| {
        self.startHyperlink(link.uri, switch (link.id) {
            .explicit => |v| v,
            .implicit => null,
        }) catch |err| {
            // This shouldn't happen because startHyperlink should handle
            // resizing. This only happens if we're truly out of RAM. Degrade
            // to forgetting the hyperlink.
            log.err("failed to update hyperlink on resize err={}", .{err});
        };

        // Remove our old link
        link.deinit(self.alloc);
        self.alloc.destroy(link);
    }
}

/// Set a style attribute for the current cursor.
///
/// If the style can't be set due to any internal errors (memory-related),
/// then this will revert back to the existing style and return an error.
pub fn setAttribute(
    self: *Screen,
    attr: sgr.Attribute,
) PageList.IncreaseCapacityError!void {
    // If we fail to set our style for any reason, we should revert
    // back to the old style. If we fail to do that, we revert back to
    // the default style.
    const old_style = self.cursor.style;
    errdefer {
        self.cursor.style = old_style;
        self.manualStyleUpdate() catch |err| {
            log.warn("setAttribute error restoring old style after failure err={}", .{err});
            self.cursor.style = .{};
            self.manualStyleUpdate() catch unreachable;
        };
    }

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

        .overline => {
            self.cursor.style.flags.overline = true;
        },

        .reset_overline => {
            self.cursor.style.flags.overline = false;
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
///
/// This function can NOT fail if the cursor style is changing to the
/// default style.
///
/// If this returns an error, the style change did not take effect and
/// the cursor style is reverted back to the default. The only scenario
/// this returns an error is if there is a physical memory allocation failure
/// or if there is no possible way to increase style capacity to store
/// the style.
///
/// This function WILL split pages as necessary to accommodate the new style.
/// So if OutOfSpace is returned, it means that even after splitting the page
/// there was still no room for the new style.
pub fn manualStyleUpdate(self: *Screen) PageList.IncreaseCapacityError!void {
    defer self.assertIntegrity();
    var page: *Page = &self.cursor.page_pin.node.data;

    // std.log.warn("active styles={}", .{page.styles.count()});

    // Release our previous style if it was not default.
    if (self.cursor.style_id != style.default_id) {
        page.styles.release(page.memory, self.cursor.style_id);
    }

    // If our new style is the default, just reset to that
    if (self.cursor.style.default()) {
        self.cursor.style_id = style.default_id;
        return;
    }

    // Clear the cursor style ID to prevent weird things from happening
    // if the page capacity has to be adjusted which would end up calling
    // manualStyleUpdate again.
    //
    // This also ensures that if anything fails below, we fall back to
    // clearing our style.
    self.cursor.style_id = style.default_id;

    // After setting the style, we need to update our style map.
    // Note that we COULD lazily do this in print. We should look into
    // if that makes a meaningful difference. Our priority is to keep print
    // fast because setting a ton of styles that do nothing is uncommon
    // and weird.
    const id = page.styles.add(
        page.memory,
        self.cursor.style,
    ) catch |err| id: {
        // Our style map is full or needs to be rehashed, so we need to
        // increase style capacity (or rehash).
        const node = self.increaseCapacity(
            self.cursor.page_pin.node,
            switch (err) {
                error.OutOfMemory => .styles,
                error.NeedsRehash => null,
            },
        ) catch |increase_err| switch (increase_err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutOfSpace => space: {
                // Out of space, we need to split the page. Split wherever
                // is using less capacity and hope that works. If it doesn't
                // work, we tried.
                try self.splitForCapacity(self.cursor.page_pin.*);
                break :space self.cursor.page_pin.node;
            },
        };

        page = &node.data;
        break :id page.styles.add(
            page.memory,
            self.cursor.style,
        ) catch |err2| switch (err2) {
            error.OutOfMemory => {
                // This shouldn't happen because increaseCapacity is
                // guaranteed to increase our capacity by at least one and
                // we only need one space, but again, I don't want to crash
                // here so let's log loudly and reset.
                log.err("style addition failed after capacity increase", .{});
                return error.OutOfMemory;
            },
            error.NeedsRehash => {
                // This should be impossible because we rehash above
                // and rehashing should never result in a duplicate. But
                // we don't want to simply hard crash so log it and
                // clear our style.
                log.err("style rehash resulted in needs rehash", .{});
                return;
            },
        };
    };
    errdefer page.styles.release(page.memory, id);

    self.cursor.style_id = id;
}

/// Split at the given pin so that the pinned row moves to the page
/// with less used capacity after the split.
///
/// The primary use case for this is to handle IncreaseCapacityError
/// OutOfSpace conditions where we need to split the page in order
/// to make room for more managed memory.
///
/// If the caller cares about where the pin moves to, they should
/// setup a tracked pin before calling this and then check that.
/// In many calling cases, the input pin is tracked (e.g. the cursor
/// pin).
///
/// If this returns OOM then its a system OOM. If this returns OutOfSpace
/// then it means the page can't be split further.
fn splitForCapacity(
    self: *Screen,
    pin: Pin,
) PageList.SplitError!void {
    // Get our capacities. We include our target row because its
    // capacity will be preserved.
    const bytes_above = Page.layout(pin.node.data.exactRowCapacity(
        0,
        pin.y + 1,
    )).total_size;
    const bytes_below = Page.layout(pin.node.data.exactRowCapacity(
        pin.y,
        pin.node.data.size.rows,
    )).total_size;

    // We need to track the old cursor pin because if our split
    // moves the cursor pin we need to update our accounting.
    const old_cursor = self.cursor.page_pin.*;

    // If our bytes above are less than bytes below, we move the pin
    // to split down one since splitting includes the pinned row in
    // the new node.
    try self.pages.split(if (bytes_above < bytes_below)
        pin.down(1) orelse pin
    else
        pin);

    // Cursor didn't change nodes, we're done.
    if (self.cursor.page_pin.node == old_cursor.node) return;

    // Cursor changed, we need to restore the old pin then use
    // cursorChangePin to move to the new pin. The old node is guaranteed
    // to still exist, just not the row.
    //
    // Note that page_row and all that will be invalid, it points to the
    // new node, but at the time of writing this we don't need any of that
    // to be right in cursorChangePin.
    const new_cursor = self.cursor.page_pin.*;
    self.cursor.page_pin.* = old_cursor;
    self.cursorChangePin(new_cursor);
}

/// Append a grapheme to the given cell within the current cursor row.
pub fn appendGrapheme(
    self: *Screen,
    cell: *Cell,
    cp: u21,
) PageList.IncreaseCapacityError!void {
    defer self.cursor.page_pin.node.data.assertIntegrity();
    self.cursor.page_pin.node.data.appendGrapheme(
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
            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .grapheme_bytes,
            );

            // The cell pointer is now invalid, so we need to get it from
            // the reloaded cursor pointers.
            const reloaded_cell: *Cell = switch (std.math.order(cell_idx, self.cursor.x)) {
                .eq => self.cursor.page_cell,
                .lt => self.cursorCellLeft(@intCast(self.cursor.x - cell_idx)),
                .gt => self.cursorCellRight(@intCast(cell_idx - self.cursor.x)),
            };

            self.cursor.page_pin.node.data.appendGrapheme(
                self.cursor.page_row,
                reloaded_cell,
                cp,
            ) catch |err2| {
                comptime assert(@TypeOf(err2) == error{OutOfMemory});
                // This should never happen because we just increased capacity.
                // Log loudly but still return an error so we don't just
                // crash.
                log.err("grapheme append failed after capacity increase", .{});
                return err2;
            };
        },
    };
}

/// Start the hyperlink state. Future cells will be marked as hyperlinks with
/// this state. Note that various terminal operations may clear the hyperlink
/// state, such as switching screens (alt screen).
pub fn startHyperlink(
    self: *Screen,
    uri: []const u8,
    id_: ?[]const u8,
) PageList.IncreaseCapacityError!void {
    // Create our pending entry.
    const link: hyperlink.Hyperlink = .{
        .uri = uri,
        .id = if (id_) |id| .{
            .explicit = id,
        } else implicit: {
            defer self.cursor.hyperlink_implicit_id += 1;
            break :implicit .{ .implicit = self.cursor.hyperlink_implicit_id };
        },
    };
    errdefer switch (link.id) {
        .explicit => {},
        .implicit => self.cursor.hyperlink_implicit_id -= 1,
    };

    // Loop until we have enough page memory to add the hyperlink
    while (true) {
        if (self.startHyperlinkOnce(link)) {
            return;
        } else |err| switch (err) {
            // An actual self.alloc OOM is a fatal error.
            error.OutOfMemory => return error.OutOfMemory,

            // strings table is out of memory, adjust it up
            error.StringsOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .string_bytes,
            ),

            // hyperlink set is out of memory, adjust it up
            error.SetOutOfMemory => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            ),

            // hyperlink set is too full, rehash it
            error.SetNeedsRehash => _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                null,
            ),
        }

        self.assertIntegrity();
    }
}

/// This is like startHyperlink but if we have to adjust page capacities
/// this returns error.PageAdjusted. This is useful so that we unwind
/// all the previous state and try again.
fn startHyperlinkOnce(
    self: *Screen,
    source: hyperlink.Hyperlink,
) (Allocator.Error || Page.InsertHyperlinkError)!void {
    // End any prior hyperlink
    self.endHyperlink();

    // Allocate our new Hyperlink entry in non-page memory. This
    // lets us quickly get access to URI, ID.
    const link = try self.alloc.create(hyperlink.Hyperlink);
    errdefer self.alloc.destroy(link);
    link.* = try source.dupe(self.alloc);
    errdefer link.deinit(self.alloc);

    // Insert the hyperlink into page memory
    var page = &self.cursor.page_pin.node.data;
    const id: hyperlink.Id = try page.insertHyperlink(link.*);

    // Save it all
    self.cursor.hyperlink = link;
    self.cursor.hyperlink_id = id;
}

/// End the hyperlink state so that future cells aren't part of the
/// current hyperlink (if any). This is safe to call multiple times.
pub fn endHyperlink(self: *Screen) void {
    // If we have no hyperlink state then do nothing
    if (self.cursor.hyperlink_id == 0) {
        assert(self.cursor.hyperlink == null);
        return;
    }

    // Release the old hyperlink state. If there are cells using the
    // hyperlink this will work because the creation creates a reference
    // and all additional cells create a new reference. This release will
    // just release our initial reference.
    //
    // If the ref count reaches zero the set will not delete the item
    // immediately; it is kept around in case it is used again (this is
    // how RefCountedSet works). This causes some memory fragmentation but
    // is fine because if it is ever pruned the context deleted callback
    // will be called.
    var page: *Page = &self.cursor.page_pin.node.data;
    page.hyperlink_set.release(page.memory, self.cursor.hyperlink_id);
    self.cursor.hyperlink.?.deinit(self.alloc);
    self.alloc.destroy(self.cursor.hyperlink.?);
    self.cursor.hyperlink_id = 0;
    self.cursor.hyperlink = null;
}

/// Set the current hyperlink state on the current cell.
pub fn cursorSetHyperlink(self: *Screen) PageList.IncreaseCapacityError!void {
    assert(self.cursor.hyperlink_id != 0);

    var page = &self.cursor.page_pin.node.data;
    if (page.setHyperlink(
        self.cursor.page_row,
        self.cursor.page_cell,
        self.cursor.hyperlink_id,
    )) {
        // Success, increase the refcount for the hyperlink.
        page.hyperlink_set.use(page.memory, self.cursor.hyperlink_id);
        return;
    } else |err| switch (err) {
        // hyperlink_map is out of space, realloc the page to be larger
        error.HyperlinkMapOutOfMemory => {
            // Attempt to allocate the space that would be required to
            // insert a new copy of the cursor hyperlink uri in to the
            // string alloc, since right now increaseCapacity always just
            // adds an extra copy even if one already exists in the page.
            // If this alloc fails then we know we also need to grow our
            // string bytes.
            //
            // FIXME: increaseCapacity should not do this.
            while (self.cursor.hyperlink) |link| {
                if (page.string_alloc.alloc(
                    u8,
                    page.memory,
                    link.uri.len,
                )) |slice| {
                    // We don't bother freeing because we're
                    // about to free the entire page anyway.
                    _ = slice;
                    break;
                } else |_| {}

                // We didn't have enough room, let's increase string bytes
                const new_node = try self.increaseCapacity(
                    self.cursor.page_pin.node,
                    .string_bytes,
                );
                assert(new_node == self.cursor.page_pin.node);
                page = &new_node.data;
            }

            _ = try self.increaseCapacity(
                self.cursor.page_pin.node,
                .hyperlink_bytes,
            );

            // Retry
            //
            // We check that the cursor hyperlink hasn't been destroyed
            // by the capacity adjustment first though- since despite the
            // terrible code above, that can still apparently happen ._.
            if (self.cursor.hyperlink_id > 0) {
                return try self.cursorSetHyperlink();
            }
        },
    }
}

/// Modify the semantic content type of the cursor. This should
/// be preferred over setting it manually since it handles all the
/// proper accounting.
pub fn cursorSetSemanticContent(self: *Screen, t: union(enum) {
    prompt: osc.semantic_prompt.PromptKind,
    output,
    input: enum { clear_explicit, clear_eol },
}) void {
    const cursor = &self.cursor;

    switch (t) {
        .output => {
            cursor.semantic_content = .output;
            cursor.semantic_content_clear_eol = false;
        },

        .input => |clear| {
            cursor.semantic_content = .input;
            cursor.semantic_content_clear_eol = switch (clear) {
                .clear_explicit => false,
                .clear_eol => true,
            };
        },

        .prompt => |kind| {
            self.semantic_prompt.seen = true;
            cursor.semantic_content = .prompt;
            cursor.semantic_content_clear_eol = false;
            cursor.page_row.semantic_prompt = switch (kind) {
                .initial, .right => .prompt,
                .continuation, .secondary => .prompt_continuation,
            };
        },
    }
}

/// Set the selection to the given selection. If this is a tracked selection
/// then the screen will take ownership of the selection. If this is untracked
/// then the screen will convert it to tracked internally. This will automatically
/// untrack the prior selection (if any).
///
/// Set the selection to null to clear any previous selection.
///
/// This is always recommended over setting `selection` directly. Beyond
/// managing memory for you, it also performs safety checks that the selection
/// is always tracked.
pub fn select(self: *Screen, sel_: ?Selection) Allocator.Error!void {
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
    self.dirty.selection = true;
}

/// Same as select(null) but can't fail.
pub fn clearSelection(self: *Screen) void {
    if (self.selection) |*sel| {
        sel.deinit(self);
        self.dirty.selection = true;
    }
    self.selection = null;
}

pub const SelectionString = struct {
    /// The selection to convert to a string.
    sel: Selection,

    /// If true, trim whitespace around the selection.
    trim: bool = true,

    /// If non-null, a stringmap will be written here. This will use
    /// the same allocator as the call to selectionString. The string will
    /// be duplicated here and in the return value so both must be freed.
    map: ?*StringMap = null,
};

const selectionString_tw = tripwire.module(enum {
    copy_map,
}, selectionString);

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
///
/// For more flexibility, use a ScreenFormatter directly.
pub fn selectionString(
    self: *Screen,
    alloc: Allocator,
    opts: SelectionString,
) Allocator.Error![:0]const u8 {
    // We'll use this as our buffer to build our string.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // Create a formatter and use that to emit our text.
    var formatter: ScreenFormatter = .init(
        self,
        .{
            .emit = .plain,
            .unwrap = true,
            .trim = opts.trim,
        },
    );
    formatter.content = .{ .selection = opts.sel };

    // If we have a string map, we need to set that up.
    var pins: std.ArrayList(Pin) = .empty;
    defer pins.deinit(alloc);
    if (opts.map != null) formatter.pin_map = .{
        .alloc = alloc,
        .map = &pins,
    };

    // Emit. Since this is an allocating writer, a failed write
    // just becomes an OOM.
    formatter.format(&aw.writer) catch return error.OutOfMemory;

    // Build our final text and if we have a string map set that up.
    const text = try aw.toOwnedSliceSentinel(0);
    errdefer alloc.free(text);
    if (opts.map) |map| {
        const map_string = try alloc.dupeZ(u8, text);
        errdefer alloc.free(map_string);
        try selectionString_tw.check(.copy_map);
        const map_pins = try pins.toOwnedSlice(alloc);
        map.* = .{
            .string = map_string,
            .map = map_pins,
        };
    }

    return text;
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
    const semantic_prompt_state: ?Cell.SemanticContent = state: {
        if (!opts.semantic_prompt_boundary) break :state null;
        const rac = opts.pin.rowAndCell();
        break :state rac.cell.semantic_content;
    };

    // The real start of the row is the first row in the soft-wrap.
    const start_pin: Pin = start_pin: {
        var it = opts.pin.rowIterator(.left_up, null);
        var it_prev: Pin = it.next().?; // skip self

        // First, check the current row for semantic boundaries before the clicked position.
        if (semantic_prompt_state) |v| {
            const row = it_prev.rowAndCell().row;
            const cells = it_prev.node.data.getCells(row);
            // Scan backwards from clicked position to find where our content starts
            for (0..opts.pin.x + 1) |i| {
                const x_rev = opts.pin.x - i;
                if (cells[x_rev].semantic_content != v) {
                    var copy = it_prev;
                    copy.x = @intCast(x_rev + 1);
                    break :start_pin copy;
                }
            }

            // No boundary found before clicked position on current row.
            // If row doesn't wrap from above, start is at column 0.
            // Otherwise, continue checking previous rows.
        }

        while (it.next()) |p| {
            const row = p.rowAndCell().row;

            if (!row.wrap) {
                var copy = it_prev;
                copy.x = 0;
                break :start_pin copy;
            }

            if (semantic_prompt_state) |v| {
                // We need to check every cell in this row in reverse
                // order since we're going up and back.
                const cells = p.node.data.getCells(row);
                for (0..cells.len) |x| {
                    const x_rev = cells.len - 1 - x;
                    const cell = cells[x_rev];
                    if (cell.semantic_content != v) break :start_pin it_prev;
                    it_prev = p;
                    it_prev.x = @intCast(x_rev);
                }

                continue;
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
                // We need to check every cell in this row
                const cells = p.node.data.getCells(row);

                // If this is our pin row we can start from our x because
                // the start_pin logic already found the real start.
                const start_offset = if (p.node == opts.pin.node and
                    p.y == opts.pin.y) opts.pin.x else 0;

                // Handle the zero case specially because if the first
                // col doesn't match then we end at the end of the prior
                // row. But if this is the first row, we can't go back,
                // so we scan forward to find where our content ends.
                if (start_offset == 0 and cells[0].semantic_content != v) {
                    var prev = p.up(1).?;
                    prev.x = p.node.data.size.cols - 1;
                    break :end_pin prev;
                }

                // For every other case, we end at the prior cell.
                for (start_offset.., cells[start_offset..]) |x, cell| {
                    if (cell.semantic_content != v) {
                        var copy = p;
                        copy.x = @intCast(x - 1);
                        break :end_pin copy;
                    }
                }
            }

            if (!row.wrap) {
                var copy = p;
                copy.x = p.node.data.size.cols - 1;
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

    return .init(start, end, false);
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

    return .init(start, end, false);
}

/// Select the nearest word to start point that is between start_pt and
/// end_pt (inclusive). Because it selects "nearest" to start point, start
/// point can be before or after end point.
///
/// The boundary_codepoints parameter should be a slice of u21 codepoints that
/// mark word boundaries, passed through to selectWord.
///
/// TODO: test this
pub fn selectWordBetween(
    self: *Screen,
    start: Pin,
    end: Pin,
    boundary_codepoints: []const u21,
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
        if (self.selectWord(pin, boundary_codepoints)) |sel| return sel;
    }

    return null;
}

/// Select the word under the given point. A word is any consecutive series
/// of characters that are exclusively whitespace or exclusively non-whitespace.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenario
/// this happens is if the point pt is outside of the written screen space.
///
/// The boundary_codepoints parameter should be a slice of u21 codepoints that
/// mark word boundaries. This is expected to be pre-parsed from the config.
pub fn selectWord(
    self: *Screen,
    pin: Pin,
    boundary_codepoints: []const u21,
) ?Selection {
    _ = self;

    // If our cell is empty we can't select a word, because we can't select
    // areas where the screen is not yet written.
    const start_cell = pin.rowAndCell().cell;
    if (!start_cell.hasText()) return null;

    // Determine if we are a boundary or not to determine what our boundary is.
    const expect_boundary = std.mem.indexOfAny(
        u21,
        boundary_codepoints,
        &[_]u21{start_cell.content.codepoint},
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
                u21,
                boundary_codepoints,
                &[_]u21{cell.content.codepoint},
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;

            // If we are going to the next row and it isn't wrapped, we
            // return the previous.
            if (p.x == p.node.data.size.cols - 1 and !rac.row.wrap) {
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
            if (p.x == p.node.data.size.cols - 1 and !rac.row.wrap) {
                break :start prev;
            }

            // If we reached an empty cell its always a boundary
            if (!cell.hasText()) break :start prev;

            // If we do not match our expected set, we hit a boundary
            const this_boundary = std.mem.indexOfAny(
                u21,
                boundary_codepoints,
                &[_]u21{cell.content.codepoint},
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;

            prev = p;
        }

        break :start prev;
    };

    return .init(start, end, false);
}

/// Select the command output under the given point. The limits of the output
/// are determined by semantic prompt information provided by shell integration.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible:
///  - the point pt is outside of the written screen space.
///  - the point pt is on a prompt / input line.
pub fn selectOutput(self: *Screen, pin: Pin) ?Selection {
    // If our pin right now is not on output, then we return nothing.
    if (pin.rowAndCell().cell.semantic_content != .output) return null;

    // Get the post prior prompt from this pin. This is the prompt whose
    // output we'll be capturing.
    const prompt_pin: Pin = prompt: {
        // If we have a prompt above this point (including this point),
        // then thats the prompt we want to capture output from.
        var it = pin.promptIterator(.left_up, null);
        if (it.next()) |p| break :prompt p;

        // If we don't have a prompt, then we assume that we're
        // capturing all the output up to the next prompt.
        it = pin.promptIterator(.right_down, null);
        const next = it.next() orelse return null;

        // We'll capture from the start of the screen to just above
        // the prompt and will trim the trailing whitespace.
        const start_pin = self.pages.getTopLeft(.screen);
        var end_pin = next.up(1) orelse return null;
        end_pin.x = end_pin.node.data.size.cols - 1;
        var cell_it = end_pin.cellIterator(.left_up, start_pin);
        while (cell_it.next()) |p| {
            const cell = p.rowAndCell().cell;
            end_pin = p;
            if (cell.hasText()) break;
        }

        return .init(
            start_pin,
            end_pin,
            false,
        );
    };

    // Grab our content
    var hl = self.pages.highlightSemanticContent(
        prompt_pin,
        .output,
    ) orelse return null;

    // Trim our trailing whitespace
    var cell_it = hl.end.cellIterator(.left_up, hl.start);
    while (cell_it.next()) |p| {
        const cell = p.rowAndCell().cell;
        hl.end = p;
        if (cell.hasText()) break;
    }

    return .init(hl.start, hl.end, false);
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

pub const PromptClickMove = struct {
    left: usize,
    right: usize,

    pub const zero = PromptClickMove{
        .left = 0,
        .right = 0,
    };
};

/// Determine the inputs necessary to move the cursor to the given
/// click location within a prompt input area.
///
/// If the cursor isn't currently at a prompt input location, this
/// returns no movement.
///
/// This feature depends on well-behaved OSC133 shell integration. Specifically,
/// this only moves over designated input areas (OSC 133 B). It is assumed
/// that the shell will only move the cursor to input cells, so prompt cells
/// and other blank cells are ignored as part of the movement calculation.
pub fn promptClickMove(
    self: *Screen,
    click_pin: Pin,
) PromptClickMove {
    // If we're not at an input cell with our cursor, no movement will
    // ever be possible.
    if (self.cursor.semantic_content != .input and
        self.cursor.page_cell.semantic_content != .input) return .zero;

    return switch (self.semantic_prompt.click) {
        // None doesn't support movement and click_events must use a
        // different mechanism (SGR mouse events) that callers must handle.
        .none, .click_events => .zero,
        .cl => |cl| switch (cl) {
            // All of these currently use dumb line-based navigation.
            // But eventually we'll support more.
            .line,
            .multiple,
            .conservative_vertical,
            .smart_vertical,
            => self.promptClickLine(click_pin),
        },
    };
}

/// Determine the inputs required to move from the cursor to the given
/// click location. If the cursor isn't currently at a prompt input
/// location, this will return zero.
///
/// This currently only supports moving a single line.
fn promptClickLine(self: *Screen, click_pin: Pin) PromptClickMove {
    // If our click pin is our cursor pin, no movement is needed.
    // Do this early so we can assume later that they are different.
    const cursor_pin = self.cursor.page_pin.*;
    if (cursor_pin.eql(click_pin)) return .zero;

    // If our cursor is before our click, we're only emitting right inputs.
    if (cursor_pin.before(click_pin)) {
        var count: usize = 0;

        // We go row-by-row because soft-wrapped rows are still a single
        // line to a shell, so we can't just look at our page row.
        var row_it = cursor_pin.rowIterator(
            .right_down,
            click_pin,
        );
        row_it: while (row_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            const cells = row_pin.node.data.getCells(rac.row);

            // Determine if this row is our cursor.
            const is_cursor_row = row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y;

            // If this is not the cursor row, verify it's still part of the
            // continuation of our starting prompt.
            if (!is_cursor_row and
                rac.row.semantic_prompt != .prompt_continuation) break;

            // Determine where our input starts.
            const start_x: usize = start_x: {
                // If this is our cursor row then we start after the cursor.
                if (is_cursor_row) break :start_x cursor_pin.x + 1;

                // Otherwise, we start at the first input cell, because
                // we expect the shell to properly translate arrows across
                // lines to the start of the input. Some shells indent
                // where input starts on subsequent lines so we must do
                // this.
                for (cells, 0..) |cell, x| {
                    if (cell.semantic_content == .input) break :start_x x;
                }

                // We never found an input cell, so we need to move to the
                // next row.
                break :start_x cells.len;
            };

            // Iterate over the input cells and assume arrow keys only
            // jump to input cells.
            for (cells[start_x..], start_x..) |cell, x| {
                // Ignore non-input cells, but allow breaks. We assume
                // the shell will translate arrow keys to only input
                // areas.
                if (cell.semantic_content != .input) continue;

                // Increment our input count
                count += 1;

                // If this is our target, we're done.
                if (row_pin.node == click_pin.node and
                    row_pin.y == click_pin.y and
                    x == click_pin.x)
                    break :row_it;
            }

            // If this row isn't soft-wrapped, we need to break out
            // because line based moving only handles single lines.
            // We're done!
            if (!rac.row.wrap) {
                // If we never found our pin, that means we clicked further
                // right/beyond it. If we're already on a non-empty input cell
                // then we add one so we can move to the newest, empty cell
                // at the end, matching typical editor behavior.
                if (self.cursor.page_cell.semantic_content == .input) count += 1;

                break;
            }
        }

        return .{ .left = 0, .right = count };
    }

    // Otherwise, cursor is after click, so we're emitting left inputs.
    var count: usize = 0;

    // We go row-by-row because soft-wrapped rows are still a single
    // line to a shell, so we can't just look at our page row.
    var row_it = cursor_pin.rowIterator(
        .left_up,
        click_pin,
    );
    row_it: while (row_it.next()) |row_pin| {
        const rac = row_pin.rowAndCell();
        const cells = row_pin.node.data.getCells(rac.row);

        // Determine the length of the cells we look at in this row.
        const end_len: usize = end_len: {
            // If this is our cursor row then we end before the cursor.
            if (row_pin.node == cursor_pin.node and
                row_pin.y == cursor_pin.y) break :end_len cursor_pin.x;

            // Otherwise, we end at the last cell in the row.
            break :end_len cells.len;
        };

        // Iterate backwards over the input cells.
        for (0..end_len) |rev_x| {
            const x: usize = end_len - 1 - rev_x;
            const cell = cells[x];

            // Ignore non-input cells.
            if (cell.semantic_content != .input) continue;

            // Increment our input count
            count += 1;

            // If this is our target, we're done.
            if (row_pin.node == click_pin.node and
                row_pin.y == click_pin.y and
                x == click_pin.x)
                break :row_it;
        }

        // If this row is not a wrap continuation, then break out
        if (!rac.row.wrap_continuation) break;
    }

    return .{ .left = count, .right = 0 };
}

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
pub fn dumpString(
    self: *const Screen,
    writer: *std.Io.Writer,
    opts: struct {
        /// The start and end points of the dump, both inclusive. The x will
        /// be ignored and the full row will always be dumped.
        tl: Pin,
        br: ?Pin = null,

        /// If true, this will unwrap soft-wrapped lines. If false, this will
        /// dump the screen as it is visually seen in a rendered window.
        unwrap: bool = true,
    },
) std.Io.Writer.Error!void {
    // Create a formatter and use that to emit our text.
    var formatter: ScreenFormatter = .init(self, .{
        .emit = .plain,
        .unwrap = opts.unwrap,
        .trim = false,
    });

    // Set up the selection based on the pins
    const tl = opts.tl;
    const br = opts.br orelse self.pages.getBottomRight(.screen).?;

    formatter.content = .{
        .selection = Selection.init(
            tl,
            br,
            false, // not rectangle
        ),
    };

    // Emit
    try formatter.format(writer);
}

/// You should use dumpString, this is a restricted version mostly for
/// legacy and convenience reasons for unit tests.
pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = false,
    });

    return try builder.toOwnedSlice();
}

/// You should use dumpString, this is a restricted version mostly for
/// legacy and convenience reasons for unit tests.
pub fn dumpStringAllocUnwrapped(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try self.dumpString(&builder.writer, .{
        .tl = self.pages.getTopLeft(tl),
        .br = self.pages.getBottomRight(tl) orelse return error.UnknownPoint,
        .unwrap = true,
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
            if (self.cursor.semantic_content_clear_eol) {
                self.cursorSetSemanticContent(.output);
            } else switch (self.cursor.semantic_content) {
                .output => {},
                .prompt, .input => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
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

            try self.cursor.page_pin.node.data.appendGrapheme(
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
            switch (self.cursor.semantic_content) {
                .output => {},
                .input, .prompt => self.cursor.page_row.semantic_prompt = .prompt_continuation,
            }
        }

        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = c },
                    .style_id = self.cursor.style_id,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a ref-counted style, increase.
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.data;
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();
            },

            2 => {
                // Need a wide spacer head
                if (self.cursor.x == self.pages.cols - 1) {
                    self.cursor.page_cell.* = .{
                        .content_tag = .codepoint,
                        .content = .{ .codepoint = 0 },
                        .wide = .spacer_head,
                        .protected = self.cursor.protected,
                        .semantic_content = self.cursor.semantic_content,
                    };

                    // If we have a hyperlink, add it to the cell.
                    if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

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
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

                // Write our tail
                self.cursorRight(1);
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = 0 },
                    .wide = .spacer_tail,
                    .protected = self.cursor.protected,
                    .semantic_content = self.cursor.semantic_content,
                };

                // If we have a hyperlink, add it to the cell.
                if (self.cursor.hyperlink_id > 0) try self.cursorSetHyperlink();

                // If we have a ref-counted style, increase twice.
                if (self.cursor.style_id != style.default_id) {
                    const page = self.cursor.page_pin.node.data;
                    page.styles.use(page.memory, self.cursor.style_id);
                    page.styles.use(page.memory, self.cursor.style_id);
                    self.cursor.page_row.styled = true;
                }
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

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
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

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
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

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 2, .max_scrollback = 1000 });
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

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 2, .max_scrollback = 0 });
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

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 2, .max_scrollback = 0 });
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

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    s.cursorAbsolute(2, 3);
    try testing.expect(s.cursor.x == 2);
    try testing.expect(s.cursor.y == 3);

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    try s2.cursorCopy(s.cursor, .{});
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

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    const page = &s2.cursor.page_pin.node.data;

    // Bold should create our style
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);

    // Copy default style, should release our style
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen cursorCopy style deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 2048 });
    defer s2.deinit();

    // We need to get the cursor on a new page.
    const first_page_size = s2.pages.pages.first.?.data.capacity.rows;

    // Fill the scrollback with blank lines until
    // there are only 5 rows left on the first page.
    s2.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");

    // s2.pages.diagram(...):
    //
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4300 |1         | | 0
    // 4301 |2         | | 1
    // 4302 |3         | | 2
    // 4303 |4         | | 3
    // 4304 |5         | | 4
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |6         | | 5
    //    1 |7         | | 6
    //    2 |8         | | 7
    //    3 |9         | | 8
    //    4 |10        | | 9
    //      :  ^       : : = PIN 0
    //      +----------+ :
    //     +-------------+

    // This should be PAGE 1
    const page = &s2.cursor.page_pin.node.data;

    // It should be the last page in the list.
    try testing.expectEqual(&s2.pages.pages.last.?.data, page);
    // It should have a previous page.
    try testing.expect(s2.cursor.page_pin.node.prev != null);

    // The cursor should be at 2, 9
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);

    // Bold should create our style in page 1.
    try s2.setAttribute(.{ .bold = {} });
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s2.cursor.style.flags.bold);

    // Copy the cursor for the first screen. This should release
    // the style from page 1 and move the cursor back to page 0.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(!s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
    // The page after the page the cursor is now in should be page 1.
    try testing.expectEqual(page, &s2.cursor.page_pin.node.next.?.data);
    // The cursor should be at 0, 0
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}

test "Screen cursorCopy style copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    const page = &s2.cursor.page_pin.node.data;
    try s2.cursorCopy(s.cursor, .{});
    try testing.expect(s2.cursor.style.flags.bold);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
}

test "Screen cursorCopy hyperlink deref" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    const page = &s2.cursor.page_pin.node.data;

    // Create a hyperlink for the cursor.
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);

    // Copy a cursor with no hyperlink, should release our hyperlink.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}

test "Screen cursorCopy hyperlink deref new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 2048 });
    defer s2.deinit();

    // We need to get the cursor on a new page.
    const first_page_size = s2.pages.pages.first.?.data.capacity.rows;

    // Fill the scrollback with blank lines until
    // there are only 5 rows left on the first page.
    s2.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 5) |_| {
        try s2.testWriteString("\n");
    }
    s2.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s2.testWriteString("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");

    // s2.pages.diagram(...):
    //
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4300 |1         | | 0
    // 4301 |2         | | 1
    // 4302 |3         | | 2
    // 4303 |4         | | 3
    // 4304 |5         | | 4
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |6         | | 5
    //    1 |7         | | 6
    //    2 |8         | | 7
    //    3 |9         | | 8
    //    4 |10        | | 9
    //      :  ^       : : = PIN 0
    //      +----------+ :
    //     +-------------+

    // This should be PAGE 1
    const page = &s2.cursor.page_pin.node.data;

    // It should be the last page in the list.
    try testing.expectEqual(&s2.pages.pages.last.?.data, page);
    // It should have a previous page.
    try testing.expect(s2.cursor.page_pin.node.prev != null);

    // The cursor should be at 2, 9
    try testing.expect(s2.cursor.x == 2);
    try testing.expect(s2.cursor.y == 9);

    // Create a hyperlink for the cursor, should be in page 1.
    try s2.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);

    // Copy the cursor for the first screen. This should release
    // the hyperlink from page 1 and move the cursor back to page 0.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
    // The page after the page the cursor is now in should be page 1.
    try testing.expectEqual(page, &s2.cursor.page_pin.node.next.?.data);
    // The cursor should be at 0, 0
    try testing.expect(s2.cursor.x == 0);
    try testing.expect(s2.cursor.y == 0);
}

test "Screen cursorCopy hyperlink copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    // Create a hyperlink for the cursor.
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.data.hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    const page = &s2.cursor.page_pin.node.data;

    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);

    // Copy the cursor with the hyperlink.
    try s2.cursorCopy(s.cursor, .{});
    try testing.expectEqual(@as(usize, 1), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id != 0);
}

test "Screen cursorCopy hyperlink copy disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    // Create a hyperlink for the cursor.
    try s.startHyperlink("https://example.com/", null);
    try testing.expectEqual(@as(usize, 1), s.cursor.page_pin.node.data.hyperlink_set.count());
    try testing.expect(s.cursor.hyperlink_id != 0);

    var s2 = try Screen.init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s2.deinit();
    const page = &s2.cursor.page_pin.node.data;

    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);

    // Copy the cursor with the hyperlink.
    try s2.cursorCopy(s.cursor, .{ .hyperlink = false });
    try testing.expectEqual(@as(usize, 0), page.hyperlink_set.count());
    try testing.expect(s2.cursor.hyperlink_id == 0);
}

test "Screen style basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();
    const page = &s.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.bold);

    // Set another style, we should still only have one since it was unused
    try s.setAttribute(.{ .italic = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());
    try testing.expect(s.cursor.style.flags.italic);
}

test "Screen style reset to default" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();
    const page = &s.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    // Reset to default
    try s.setAttribute(.{ .reset_bold = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen style reset with unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();
    const page = &s.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    // Reset to default
    try s.setAttribute(.{ .unset = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count());
}

test "Screen clearRows active one line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    try s.testWriteString("hello, world");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows active multi line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    try s.testWriteString("hello\nworld");
    s.clearRows(.{ .active = .{} }, null, false);
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows active styled line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("hello world");
    try s.setAttribute(.{ .unset = {} });

    // We should have one style
    const page = &s.cursor.page_pin.node.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count());

    s.clearRows(.{ .active = .{} }, null, false);

    // We should have none because active cleared it
    try testing.expectEqual(@as(usize, 0), page.styles.count());

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen clearRows protected" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    try s.testWriteString("\n");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;
    try s.testWriteString("UNPROTECTED");
    s.cursor.protected = true;
    try s.testWriteString("PROTECTED");
    s.cursor.protected = false;

    s.clearRows(.{ .active = .{} }, null, true);

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("           PROTECTED\nPROTECTED           PROTECTED", str);
}

test "Screen eraseRows history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 1000 });
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

    var s = try Screen.init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 1000 });
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

test "Screen eraseRows active partial" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    try s.testWriteString("1\n2\n3");

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("1\n2\n3", str);
    }

    s.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = 1 } });

    {
        const str = try s.dumpStringAlloc(alloc, .{ .active = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
    {
        const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(str);
        try testing.expectEqualStrings("3", str);
    }
}

test "Screen: cursorDown across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Scroll down enough to go to another page
    const start_page = &s.pages.pages.last.?.data;
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page != page);
    }

    // Scroll back to the previous page
    s.cursorUp(1);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page == page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = &s.cursor.page_pin.node.data;
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the next page and we should have that style
    s.cursorDown(1);
    {
        const page = &s.cursor.page_pin.node.data;
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: cursorUp across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Scroll down enough to go to another page
    const start_page = &s.pages.pages.last.?.data;
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page != page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = &s.cursor.page_pin.node.data;
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the prev page and we should have that style
    s.cursorUp(1);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page == page);

        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: cursorAbsolute across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Scroll down enough to go to another page
    const start_page = &s.pages.pages.last.?.data;
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page != page);
    }

    // Go back up, set a style
    try s.setAttribute(.{ .bold = {} });
    {
        const page = &s.cursor.page_pin.node.data;
        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back down into the prev page and we should have that style
    s.cursorAbsolute(1, 1);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expect(start_page == page);

        const styleval = page.styles.get(
            page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }
}

test "Screen: cursorAbsolute to page with insufficient capacity" {
    // This test checks for a very specific edge case
    // which previously resulted in memory corruption.
    //
    // The conditions for this edge case are as such:
    // - The cursor has an associated style or other managed memory.
    // - The cursor moves to a different page.
    // - The new page is at capacity and must have its capacity adjusted.

    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Scroll down enough to go to another page
    const start_page = &s.pages.pages.last.?.data;
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    const new_page = &s.cursor.page_pin.node.data;

    // We need our page to change for this test to make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    try testing.expect(start_page != new_page);

    // Add styles to the start page until it reaches capacity.
    {
        // Pause integrity checks because they're slow and
        // we're not testing this, this is just setup.
        start_page.pauseIntegrityChecks(true);
        defer start_page.pauseIntegrityChecks(false);
        defer start_page.assertIntegrity();

        var n: u24 = 1;
        while (start_page.styles.add(
            start_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }

    // Set a style on the cursor.
    try s.setAttribute(.{ .bold = {} });
    {
        const styleval = new_page.styles.get(
            new_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    // Go back up into the start page and we should still have that style.
    s.cursorAbsolute(1, 1);
    {
        const cur_page = &s.cursor.page_pin.node.data;
        // The page we're on now should NOT equal start_page, since its
        // capacity should have been adjusted, which invalidates our ptr.
        try testing.expect(start_page != cur_page);
        // To make sure we DID change pages we check we're not on new_page.
        try testing.expect(new_page != cur_page);

        const styleval = cur_page.styles.get(
            cur_page.memory,
            s.cursor.style_id,
        );
        try testing.expect(styleval.flags.bold);
    }

    s.cursor.page_pin.node.data.assertIntegrity();
    new_page.assertIntegrity();
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    // Everything is dirty because we have no scrollback
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    // Scrolling to the bottom does nothing
    s.scroll(.{ .active = {} });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrolling with a single-row screen no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 1, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Screen should be dirty
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
}

test "Screen: scrolling with a single-row screen with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 1, .max_scrollback = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD");

    // Scroll down, should still be bottom
    try s.cursorDownScroll();
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Active should be dirty
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));

    // Scrollback also dirty because cursor moved from there
    try testing.expect(s.pages.isDirty(.{ .screen = .{ .x = 0, .y = 0 } }));

    s.scroll(.{ .delta_row = -1 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: scrolling across pages preserves style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();
    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    const start_page = &s.pages.pages.last.?.data;

    // Scroll down enough to go to another page
    const rem = start_page.capacity.rows - start_page.size.rows + 1;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    // We need our page to change for this test o make sense. If this
    // assertion fails then the bug is in the test: we should be scrolling
    // above enough for a new page to show up.
    const page = &s.pages.pages.last.?.data;
    try testing.expect(start_page != page);

    const styleval = page.styles.get(
        page.memory,
        s.cursor.style_id,
    );
    try testing.expect(styleval.flags.bold);
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 50 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

test "Screen: scrolling moves viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });

    {
        // Test our contents rotated
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n1ABCD", contents);
    }

    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}

test "Screen: scrolling when viewport is pruned" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 215, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Write some to create scrollback and move back into our scrollback.
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.scroll(.{ .delta_row = -2 });

    // Our viewport is now somewhere pinned. Create so much scrollback
    // that we prune it.
    try s.testWriteString("\n");
    for (0..1000) |_| try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, s.pages.getTopLeft(.viewport)));
    }
}

test "Screen: scroll and clear full screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 5 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 5 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 5 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
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

test "Screen: scroll above same page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
    defer s.deinit();
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // At this point:
    //  +-------------+ ACTIVE
    //   +----------+ : = PAGE 0
    // 0 |1ABCD00000| | 0
    // 1 |2EFGH00000| | 1
    //   :^         : : = PIN 0
    // 2 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    try s.cursorScrollAbove();

    //   +----------+ = PAGE 0
    // 0 |1ABCD00000|
    //  +-------------+ ACTIVE
    // 1 |2EFGH00000| | 0
    // 2 |          | | 1
    //   :^         : : = PIN 0
    // 3 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0 row 1 (active row 0) is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0 row 2 (active row 1) is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 0 row 3 (active row 2) is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above same page but cursor on previous page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.data.capacity.rows;
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page and have a second
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1A00000000| | 0
    // 4306 |2B00000000| | 1
    //      :^         : : = PIN 0
    // 4307 |3C00000000| | 2
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |4D00000000| | 3
    //    1 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    try s.cursorScrollAbove();

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1A00000000|
    //     +-------------+ ACTIVE
    // 4306 |2B00000000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3C00000000| | 2
    //    1 |4D00000000| | 3
    //    2 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // The rest of the rows are dirty because they've been modified or are new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
}

test "Screen: scroll above same page but cursor on previous page last row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.data.capacity.rows;
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 2) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page and have a second
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.pages.pages.first.?.next != null);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4306 |1A00000000| | 0
    // 4307 |2B00000000| | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3C00000000| | 2
    //    1 |4D00000000| | 3
    //    2 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    try s.cursorScrollAbove();

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4306 |1A00000000|
    //     +-------------+ ACTIVE
    // 4307 |2B00000000| | 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |          | | 1
    //      :^         : : = PIN 0
    //    1 |3C00000000| | 2
    //    2 |4D00000000| | 3
    //    3 |5E00000000| | 4
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2B\n\n3C\n4D\n5E", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's final row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 1's rows are all dirty because every row was moved.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));

    // Attempt to clear the style from the cursor and
    // then assert the integrity of both of our pages.
    //
    // This catches a case of memory corruption where the cursor
    // is moved between pages without accounting for style refs.
    try s.setAttribute(.{ .reset_bg = {} });
    s.pages.pages.first.?.data.assertIntegrity();
    s.pages.pages.last.?.data.assertIntegrity();
}

test "Screen: scroll above creates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
    defer s.deinit();

    // We need to get the cursor to a new page
    const first_page_size = s.pages.pages.first.?.data.capacity.rows;
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    // At this point:
    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1ABCD00000| | 0
    // 4306 |2EFGH00000| | 1
    //      :^         : : = PIN 0
    // 4307 |3IJKL00000| | 2
    //      +----------+ :
    //     +-------------+
    try s.cursorScrollAbove();

    //      +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1ABCD00000|
    //     +-------------+ ACTIVE
    // 4306 |2EFGH00000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3IJKL00000| | 2
    //      +----------+ :
    //     +-------------+

    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0's final row is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 1's row is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above with cursor on non-final row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 4, .max_scrollback = 10 });
    defer s.deinit();

    // Get the cursor to be 2 rows above a new page
    const first_page_size = s.pages.pages.first.?.data.capacity.rows;
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    // Write 3 lines of text, forcing the last line into the first
    // row of a new page. Move our cursor onto the previous page.
    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1AB\n2BC\n3DE\n4FG");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // Ensure we're still on the first page. So our cursor is on the first
    // page but we have two pages of data.
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    //      +----------+ = PAGE 0
    //  ... :          :
    //     +-------------+ ACTIVE
    // 4305 |1AB0000000| | 0
    // 4306 |2BC0000000| | 1
    //      :^         : : = PIN 0
    // 4307 |3DE0000000| | 2
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |4FG0000000| | 3
    //      +----------+ :
    //     +-------------+
    try s.cursorScrollAbove();

    //     +----------+ = PAGE 0
    //  ... :          :
    // 4305 |1AB0000000|
    //     +-------------+ ACTIVE
    // 4306 |2BC0000000| | 0
    // 4307 |          | | 1
    //      :^         : : = PIN 0
    //      +----------+ :
    //      +----------+ : = PAGE 1
    //    0 |3DE0000000| | 2
    //    1 |4FG0000000| | 3
    //      +----------+ :
    //     +-------------+
    // try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2BC\n\n3DE\n4FG", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0's penultimate row is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0's final row is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 1's row is dirty because it's new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: scroll above no scrollback bottom of page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();

    const first_page_size = s.pages.pages.first.?.data.capacity.rows;
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 3) |_| try s.testWriteString("\n");
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s.setAttribute(.{ .direct_color_bg = .{ .r = 155 } });
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    s.cursorAbsolute(0, 1);
    s.pages.clearDirty();

    // At this point:
    //  +-------------+ ACTIVE
    //   +----------+ : = PAGE 0
    // 0 |1ABCD00000| | 0
    // 1 |2EFGH00000| | 1
    //   :^         : : = PIN 0
    // 2 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    try s.cursorScrollAbove();

    //   +----------+ = PAGE 0
    // 0 |1ABCD00000|
    //  +-------------+ ACTIVE
    // 1 |2EFGH00000| | 0
    // 2 |          | | 1
    //   :^         : : = PIN 0
    // 3 |3IJKL00000| | 2
    //   +----------+ :
    //  +-------------+

    //try s.pages.diagram(std.io.getStdErr().writer());

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n\n3IJKL", contents);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        const cell = list_cell.cell;
        try testing.expect(cell.content_tag == .bg_color_rgb);
        try testing.expectEqual(Cell.RGB{
            .r = 155,
            .g = 0,
            .b = 0,
        }, cell.content.color_rgb);
    }

    // Page 0 row 1 (active row 0) is dirty because the cursor moved off of it.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    // Page 0 row 2 (active row 1) is dirty because it was cleared.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    // Page 0 row 3 (active row 2) is dirty because it is new.
    try testing.expect(s.pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
}

test "Screen: clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 10 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

test "Screen: clone contains subset of selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 4, .max_scrollback = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Select the full screen
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 0, .y = 3 } }).?,
        false,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
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
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone contains subset of rectangle selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 4, .max_scrollback = 1 });
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Select the full screen from x=1 to x=3
    try s.select(Selection.init(
        s.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 3, .y = 3 } }).?,
        true,
    ));

    // Clone
    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 1 } },
        .{ .active = .{ .y = 2 } },
    );
    defer s2.deinit();

    // Our selection should remain valid and be properly clipped
    // preserving the columns of the start and end points of the
    // selection.
    {
        const sel = s2.selection.?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s2.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 3,
        } }, s2.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: clone basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 3 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Resize
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expectEqual(5, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);
    try s.resize(.{ .cols = 10, .rows = 2, .reflow = false });

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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resize(.{ .cols = 6, .rows = 2, .reflow = false });

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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.pages.rows) |y| {
        const list_cell = s.pages.getCell(.{ .active = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        list_cell.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 7, .reflow = false });

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

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 20, .rows = 3, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 4, .rows = 3, .reflow = false });

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

    var s = try init(alloc, .{ .cols = 7, .rows = 3, .max_scrollback = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 10, .reflow = false });

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 7, .rows = 3, .max_scrollback = 2 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 7, .rows = 2, .reflow = false });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try s.scrollClear();
    s.cursorAbsolute(0, 0);
    try s.testWriteString("A\nB");

    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 2, .reflow = false });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_scrollback = 3 });
    defer s.deinit();
    const str = "1A2B\n3C4E\n5F6G";
    try s.testWriteString(str);

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }

    // Resize
    try s.resize(.{ .cols = 2, .rows = 10, .reflow = false });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4E\n5F\n6G";
        try testing.expectEqualStrings(expected, contents);
    }

    // Every second row should be wrapped
    for (0..6) |y| {
        const list_cell = s.pages.getCell(.{ .screen = .{
            .x = 0,
            .y = @intCast(y),
        } }).?;
        const row = list_cell.row;
        const wrapped = (y % 2 == 0);
        try testing.expectEqual(wrapped, row.wrap);
    }
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 10 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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
    try s.resize(.{ .cols = 5, .rows = 10 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const cursor = s.cursor;
    try s.resize(.{ .cols = 10, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 10, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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

    try s.resize(.{ .cols = 8, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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

    try s.resize(.{ .cols = 4, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();

    // Set one of the rows to be a prompt
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("1ABCD\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("2EFGH");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("\n3IJKL");

    try s.resize(.{ .cols = 10, .rows = 3, .reflow = false });

    const expected = "1ABCD\n2EFGH\n3IJKL";
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }

    // Our one row should still be a semantic prompt, the others should not.
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .prompt);
    }
    {
        const list_cell = s.pages.getCell(.{ .active = .{ .x = 0, .y = 2 } }).?;
        try testing.expect(list_cell.row.semantic_prompt == .none);
    }
}

test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 10, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 6, .rows = 3, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 10, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 7, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 15, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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
    try s.resize(.{ .cols = 10, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_scrollback = 5 });
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
    try s.resize(.{ .cols = 7, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 4, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{ .cols = 5, .rows = 10 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 5, .rows = 1 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 5, .rows = 1 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 10 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 5, .rows = 1 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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
    try s.resize(.{ .cols = 5, .rows = 1 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 3 });
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
    try s.resize(.{ .cols = 5, .rows = 2 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);

    s.cursorAbsolute(0, 0);
    const cursor = s.cursor;
    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
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

    try s.resize(.{ .cols = 3, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
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

    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
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

    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 2 });
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

    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 5 });
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Lets do a scroll and clear operation
    try s.scrollClear();

    // Move our cursor to the beginning
    s.cursorAbsolute(0, 0);

    try s.resize(.{ .cols = 3, .rows = 3 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 3 });
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

    try s.resize(.{ .cols = 2, .rows = 10 });

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

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 10 });
    defer s.deinit();
    const str = "1ABC";
    try s.testWriteString(str);

    // Grow
    try s.resize(.{ .cols = 5, .rows = 10 });
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
    try s.resize(.{ .cols = 5, .rows = 3 });
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
    try s.resize(.{ .cols = 5, .rows = 10 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 1, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 1, .rows = 1 });
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

    var s = try init(alloc, .{ .cols = 3, .rows = 3, .max_scrollback = 0 });
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

    try s.resize(.{ .cols = 2, .rows = 3 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_scrollback = 0 });
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

    try s.resize(.{ .cols = 1, .rows = 2 });
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: resize more cols with wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 3, .rows = 2, .max_scrollback = 0 });
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

    try s.resize(.{ .cols = 4, .rows = 2 });
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

    var s = try init(alloc, .{ .cols = 3, .rows = 3, .max_scrollback = 0 });
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

    try s.resize(.{ .cols = 8, .rows = 2 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 2, .max_scrollback = 0 });
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
    try s.resize(.{ .cols = 3, .rows = 2 });
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

test "Screen: resize more cols with cursor at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n"); 
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });

    // Cursor should not move
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(1, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more cols with cursor not at prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n"); 
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_eol });
    try s.testWriteString("echo\n");
    try s.testWriteString("output");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(.{
        .cols = 20,
        .rows = 3,
        .prompt_redraw = .true,
    });

    // Cursor should not move
    try testing.expectEqual(6, s.cursor.x);
    try testing.expectEqual(2, s.cursor.y);

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> echo\noutput";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize with prompt_redraw last clears only one line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 4, .max_scrollback = 5 });
    defer s.deinit();

    // zig fmt: off
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");
    try s.testWriteString("world");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello\nworld";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor is at end of "world" line with semantic_content = .input
    try s.resize(.{
        .cols = 20,
        .rows = 4,
        .prompt_redraw = .last,
    });

    // With .last, only the current line where cursor is should be cleared
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "ABCDE\n> hello";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize with prompt_redraw last multiline prompt clears only last line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 5 });
    defer s.deinit();

    // Create a 3-line prompt: 1 initial + 2 continuation lines
    // zig fmt: off
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("line1\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line2\n");
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    try s.testWriteString("line3");
    // zig fmt: on

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2\nline3";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor is at end of line3 (the last continuation line)
    try s.resize(.{
        .cols = 30,
        .rows = 5,
        .prompt_redraw = .last,
    });

    // With .last, only line3 (where cursor is) should be cleared
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        const expected = "line1\nline2";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: select untracked" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
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

test "Screen: selectLine across full soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("1ABCD2EFGH\n3IJKL");

    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Screen: selectLine across soft-wrap ignores blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
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

    var s = try init(alloc, .{ .cols = 2, .rows = 3, .max_scrollback = 5 });
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

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("ABCDE\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("A    ");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("> ");

    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ABCDE\nA    \n> ", contents);
    }

    // Selecting output stops at the prompt even if soft-wrapped
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "A";
        try testing.expectEqualStrings(expected, contents);
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

test "Screen: selectLine semantic prompt to input boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Write prompt followed by user input on same row: "$>command"
    // Using non-whitespace to avoid whitespace trimming affecting the test
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");

    // Selecting from prompt should only select prompt
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

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 8,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic input to output boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Row 0: user input
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("ls -la\n");
    // Row 1: command output
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("file.txt");

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("ls -la", contents);
    }

    // Selecting from output should only select output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("file.txt", contents);
    }
}

test "Screen: selectLine semantic mid-row boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Single row with output then prompt then input: "out$>cmd"
    // Using non-whitespace to avoid whitespace trimming affecting the test
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$>");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd");

    // Selecting from output should stop at prompt
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from prompt should only select prompt
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from input should only select input
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 6,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 5,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic boundary soft-wrap with mid-row transition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Row 0: prompt "$ " + input "cmd" (soft-wraps)
    // Row 1: input continues "12" + output "out"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("cmd12");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("out");

    // Verify layout
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ cmd\n12out", contents);
    }

    // Selecting from input on row 0 should get all input across soft-wrap
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }

    // Selecting from input on row 1 should get all input across soft-wrap
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("cmd12", contents);
    }

    // Selecting from output should only get output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("out", contents);
    }
}

test "Screen: selectLine semantic boundary disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Write prompt followed by input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("command");

    // With semantic_prompt_boundary = false, should select entire line
    {
        var sel = s.selectLine(.{
            .pin = s.pages.pin(.{ .active = .{
                .x = 0,
                .y = 0,
            } }).?,
            .semantic_prompt_boundary = false,
        }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("$ command", contents);
    }
}

test "Screen: selectLine semantic boundary first cell of row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Row 0: input that soft-wraps
    // Row 1: output starts at first cell
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("12345");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("ABCDE");

    // Verify soft-wrap happened
    {
        const pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const row = pin.rowAndCell().row;
        try testing.expect(row.wrap);
    }

    // Selecting from input should stop before output on row 1
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 0,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }

    // Selecting from output should only get output
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
}

test "Screen: selectLine semantic all same content" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // All prompt content that soft-wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt text");

    // Verify soft-wrap
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("promp\nt tex\nt", contents);
    }

    // Should select all prompt content across soft-wraps
    {
        var sel = s.selectLine(.{ .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).? }).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("prompt text", contents);
    }
}

test "Screen: selectWord" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"', '│', '`', '|', ':', ';',
        ',', '(', ')',  '[',  ']', '{',   '}', '<', '>', '$',
    };

    // Outside of active area
    // try testing.expect(s.selectWord(.{ .x = 9, .y = 0 }) == null);
    // try testing.expect(s.selectWord(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 0,
            .y = 0,
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString(" 1234012\n 123");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"', '│', '`', '|', ':', ';',
        ',', '(', ')',  '[',  ']', '{',   '}', '<', '>', '$',
    };

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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("1       1\n 123");

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"', '│', '`', '|', ':', ';',
        ',', '(', ')',  '[',  ']', '{',   '}', '<', '>', '$',
    };

    // Going forward
    {
        var sel = s.selectWord(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 0,
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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
        } }).?, boundary_codepoints).?;
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

    // Default boundary codepoints for word selection
    const boundary_codepoints = &[_]u21{
        0,   ' ', '\t', '\'', '"', '│', '`', '|', ':', ';',
        ',', '(', ')',  '[',  ']', '{',   '}', '<', '>', '$',
    };

    const cases = [_][]const u8{
        " 'abc' \n123",
        " \"abc\" \n123",
        " │abc│ \n123",
        " `abc` \n123",
        " |abc| \n123",
        " :abc: \n123",
        " ;abc; \n123",
        " ,abc, \n123",
        " (abc( \n123",
        " )abc) \n123",
        " [abc[ \n123",
        " ]abc] \n123",
        " {abc{ \n123",
        " }abc} \n123",
        " <abc< \n123",
        " >abc> \n123",
        " $abc$ \n123",
    };

    for (cases) |case| {
        var s = try init(alloc, .{ .cols = 20, .rows = 10, .max_scrollback = 0 });
        defer s.deinit();
        try s.testWriteString(case);

        // Inside character forward
        {
            var sel = s.selectWord(s.pages.pin(.{ .active = .{
                .x = 2,
                .y = 0,
            } }).?, boundary_codepoints).?;
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
            } }).?, boundary_codepoints).?;
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
            } }).?, boundary_codepoints).?;
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
            } }).?, boundary_codepoints).?;
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

    var s = try init(alloc, .{ .cols = 10, .rows = 15, .max_scrollback = 0 });
    defer s.deinit();

    // Build content with cell-level semantic content:
    // Row 0-1: output1 (output)
    // Row 2: prompt2 (prompt)
    // Row 3: input2 (input)
    // Row 4-7: output2 (output, with overflow causing wrap)
    // Row 8: "$ " (prompt) + "input3" (input)
    // Row 9-11: output3 (output)
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output1\n");
    try s.testWriteString("output1\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("prompt2\n");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input2\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output2output2output2output2\n");
    try s.testWriteString("output2\n");
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("$ ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("input3\n");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("output3\n");
    try s.testWriteString("output3\n");
    try s.testWriteString("output3");

    // First output block (rows 0-1), should select those rows
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 1,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings("output1\noutput1", contents);
    }
    // Second output block (rows 4-7)
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 3,
            .y = 7,
        } }).?).?;
        defer sel.deinit(&s);
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        try testing.expectEqualStrings(
            "output2output2output2output2\noutput2",
            contents,
        );
    }
    // Third output block (rows 9-11)
    {
        var sel = s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 10,
        } }).?).?;
        defer sel.deinit(&s);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 9,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 6,
            .y = 11,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    // Click on prompt should return null
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 1,
            .y = 8,
        } }).?) == null);
    }
    // Click on input should return null
    {
        try testing.expect(s.selectOutput(s.pages.pin(.{ .active = .{
            .x = 5,
            .y = 8,
        } }).?) == null);
    }
}

test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString start outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString end outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim empty line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1AB  \n\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    const sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        false,
    );

    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(contents);
        const expected = "1AB  \n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
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
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
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
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 3, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/289
test "Screen: selectionString empty with soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 2, .max_scrollback = 0 });
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
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString with zero width joiner" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 1, .max_scrollback = 0 });
    defer s.deinit();
    const str = "👨‍"; // this has a ZWJ
    try s.testWriteString(str);

    // Integrity check
    {
        const pin = s.pages.pin(.{ .screen = .{ .y = 0, .x = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try testing.expectEqual(@as(u21, 0x1F468), cell.content.codepoint);
        try testing.expectEqual(Cell.Wide.wide, cell.wide);
        const cps = pin.node.data.lookupGrapheme(cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
    }

    // The real test
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "👨‍";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString, rectangle, basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 30, .rows = 5, .max_scrollback = 0 });
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

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, w/EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 30, .rows = 5, .max_scrollback = 0 });
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

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, more complex w/breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 30, .rows = 8, .max_scrollback = 0 });
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

    const contents = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = true,
    });
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 2048 });
    defer s.deinit();

    const first_page_size = s.pages.pages.first.?.data.capacity.rows;

    // Lazy way to seek to the first page boundary.
    s.pages.pages.first.?.data.pauseIntegrityChecks(true);
    for (0..first_page_size - 1) |_| {
        try s.testWriteString("\n");
    }
    s.pages.pages.first.?.data.pauseIntegrityChecks(false);

    try s.testWriteString("123456789\n!@#$%^&*(\n123456789");

    {
        const sel = Selection.init(
            s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
            s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        const contents = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = true,
        });
        defer alloc.free(contents);
        const expected = "123456789\n!@#$%^&*(\n123";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: lineIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD\n2EFGH";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("2EFGH", actual);
    }
}

test "Screen: lineIterator soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(s.pages.pin(.{ .viewport = .{} }).?);
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const sel = iter.next().?;
        const actual = try s.selectionString(alloc, .{
            .sel = sel,
            .trim = false,
        });
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }
    // try testing.expect(iter.next() == null);
}

test "Screen: hyperlink start/end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Screen: hyperlink reuse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }

    // Use it for the first time
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    const id = s.cursor.hyperlink_id;

    // Reuse the same hyperlink, expect we have the same ID
    try s.startHyperlink("http://example.com", null);
    try testing.expectEqual(id, s.cursor.hyperlink_id);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Screen: hyperlink cursor state on resize" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This test depends on underlying PageList implementation so
    // it may be invalid one day. It's here to document/verify the
    // current behavior.

    var s = try init(alloc, .{ .cols = 5, .rows = 10, .max_scrollback = 0 });
    defer s.deinit();

    // Start a hyperlink
    try s.startHyperlink("http://example.com", null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    // Resize. Any column growth will trigger a page to be reallocated.
    try s.resize(.{ .cols = 10, .rows = 10 });
    try testing.expect(s.cursor.hyperlink_id != 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }

    s.endHyperlink();
    try testing.expect(s.cursor.hyperlink_id == 0);
    {
        const page = &s.cursor.page_pin.node.data;
        try testing.expectEqual(0, page.hyperlink_set.count());
    }
}

test "Screen: cursorSetHyperlink OOM + URI too large for string alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();

    // Start a hyperlink with a URI that just barely fits in the string alloc.
    // This will ensure that additional string alloc space is needed for the
    // redundant copy of the URI when the page is re-alloced.
    const uri = "a" ** (pagepkg.std_capacity.string_bytes - 8);
    try s.startHyperlink(uri, null);

    // Figure out how many cells should can have hyperlinks in this page,
    // and write twice that number, to guarantee the capacity needs to be
    // increased at some point.
    const base_capacity = s.cursor.page_pin.node.data.hyperlinkCapacity();
    const base_string_bytes = s.cursor.page_pin.node.data.capacity.string_bytes;
    for (0..base_capacity * 2) |_| {
        try s.cursorSetHyperlink();
        if (s.cursor.x >= s.pages.cols - 1) {
            try s.cursorDownOrScroll();
            s.cursorHorizontalAbsolute(0);
        } else {
            s.cursorRight(1);
        }
    }

    // Make sure the capacity really did increase.
    try testing.expect(base_capacity < s.cursor.page_pin.node.data.hyperlinkCapacity());
    // And that our string_bytes increased as well.
    try testing.expect(base_string_bytes < s.cursor.page_pin.node.data.capacity.string_bytes);
}

test "Screen: increaseCapacity cursor style ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback = 0,
    });
    defer s.deinit();
    try s.setAttribute(.bold);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    const old_style = s.cursor.style;

    {
        const page = &s.pages.pages.last.?.data;
        // 5 chars + cursor = 6 refs
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
    }

    // This forces the page to change via increaseCapacity.
    const new_node = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Cursor's page_pin should now point to the new node
    try testing.expect(s.cursor.page_pin.node == new_node);

    // Verify cursor's page_cell and page_row are correctly reloaded from the pin
    const page_rac = s.cursor.page_pin.rowAndCell();
    try testing.expect(s.cursor.page_row == page_rac.row);
    try testing.expect(s.cursor.page_cell == page_rac.cell);

    // Style should be preserved
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);

    // After increaseCapacity, the 5 chars are cloned (5 refs) and
    // the cursor's style is re-added (1 ref) = 6 total.
    {
        const page = &s.pages.pages.last.?.data;
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
    }
}

test "Screen: increaseCapacity cursor hyperlink ref count preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback = 0,
    });
    defer s.deinit();
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    {
        const page = &s.pages.pages.last.?.data;
        // Cursor has the hyperlink active = 1 count in hyperlink_set
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }

    // This forces the page to change via increaseCapacity.
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Hyperlink should be preserved with correct URI
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);

    // After increaseCapacity, the hyperlink is re-added to the new page.
    {
        const page = &s.pages.pages.last.?.data;
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}

test "Screen: increaseCapacity cursor with both style and hyperlink preserved" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{
        .cols = 5,
        .rows = 5,
        .max_scrollback = 0,
    });
    defer s.deinit();

    // Set both a non-default style AND an active hyperlink.
    // Write one character first with bold to mark the row as styled,
    // then start the hyperlink and write more characters.
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("1ABCD");

    // We should have one page and it should be our cursor page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.pages.pages.first == s.cursor.page_pin.node);

    const old_style = s.cursor.style;

    {
        const page = &s.pages.pages.last.?.data;
        // 5 chars + cursor = 6 refs for bold style
        try testing.expectEqual(
            6,
            page.styles.refCount(page.memory, s.cursor.style_id),
        );
        // Cursor has the hyperlink active = 1 count in hyperlink_set
        try testing.expectEqual(1, page.hyperlink_set.count());
        try testing.expect(s.cursor.style_id != style.default_id);
        try testing.expect(s.cursor.hyperlink_id != 0);
        try testing.expect(s.cursor.hyperlink != null);
    }

    // This forces the page to change via increaseCapacity.
    _ = try s.increaseCapacity(
        s.cursor.page_pin.node,
        .grapheme_bytes,
    );

    // Style should be preserved
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expect(s.cursor.style_id != style.default_id);

    // Hyperlink should be preserved with correct URI
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expect(s.cursor.hyperlink_id != 0);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);

    // After increaseCapacity, both style and hyperlink are re-added to the new page.
    {
        const page = &s.pages.pages.last.?.data;
        const ref_count = page.styles.refCount(page.memory, s.cursor.style_id);
        try testing.expectEqual(6, ref_count);
        try testing.expectEqual(1, page.hyperlink_set.count());
    }
}

test "Screen: increaseCapacity non-cursor page returns early" {
    // Test that calling increaseCapacity on a page that is NOT the cursor's
    // page properly delegates to pages.increaseCapacity without doing the
    // extra cursor accounting (style/hyperlink re-adding).
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10000,
    });
    defer s.deinit();

    // Set up a custom style and hyperlink on the cursor
    try s.setAttribute(.bold);
    try s.startHyperlink("https://example.com/", null);
    try s.testWriteString("Hello");

    // Store cursor state before growing pages
    const old_style = s.cursor.style;
    const old_style_id = s.cursor.style_id;
    const old_hyperlink = s.cursor.hyperlink;
    const old_hyperlink_id = s.cursor.hyperlink_id;

    // The cursor is on the first (and only) page
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);

    // Grow pages until we have multiple pages. The cursor's pin stays on
    // the first page since we're just adding rows.
    const first_page_node = s.pages.pages.first.?;
    first_page_node.data.pauseIntegrityChecks(true);
    for (0..first_page_node.data.capacity.rows - first_page_node.data.size.rows) |_| {
        _ = try s.pages.grow();
    }
    first_page_node.data.pauseIntegrityChecks(false);
    _ = try s.pages.grow();

    // Now we have two pages
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    const second_page = s.pages.pages.last.?;

    // Cursor should still be on the first page (where it was created)
    try testing.expect(s.cursor.page_pin.node == s.pages.pages.first.?);
    try testing.expect(s.cursor.page_pin.node != second_page);

    const second_page_styles_cap = second_page.data.capacity.styles;
    const cursor_page_styles_cap = s.cursor.page_pin.node.data.capacity.styles;

    // Call increaseCapacity on the second page (NOT the cursor's page)
    const new_second_page = try s.increaseCapacity(second_page, .styles);

    // The second page should have increased capacity
    try testing.expectEqual(
        second_page_styles_cap * 2,
        new_second_page.data.capacity.styles,
    );

    // The cursor's page (first page) should be unchanged
    try testing.expectEqual(
        cursor_page_styles_cap,
        s.cursor.page_pin.node.data.capacity.styles,
    );

    // Cursor state should be completely unchanged since we didn't touch its page
    try testing.expectEqual(old_style, s.cursor.style);
    try testing.expectEqual(old_style_id, s.cursor.style_id);
    try testing.expectEqual(old_hyperlink, s.cursor.hyperlink);
    try testing.expectEqual(old_hyperlink_id, s.cursor.hyperlink_id);

    // Verify hyperlink is still valid
    try testing.expect(s.cursor.hyperlink != null);
    try testing.expectEqualStrings("https://example.com/", s.cursor.hyperlink.?.uri);
}

test "Screen: cursorDown to page with insufficient capacity" {
    // Regression test for https://github.com/ghostty-org/ghostty/issues/10282
    //
    // This test exposes a use-after-realloc bug in cursorDown (and similar
    // cursor movement functions). The bug pattern:
    //
    // 1. cursorDown creates a by-value copy of the pin via page_pin.down(n)
    // 2. cursorChangePin is called, which may trigger adjustCapacity
    //    if the target page's style map is full
    // 3. adjustCapacity frees the old page and creates a new one
    // 4. The local pin copy still points to the freed page
    // 5. rowAndCell() on the stale pin accesses freed memory

    const testing = std.testing;
    const alloc = testing.allocator;

    // Small screen to make page boundary crossing easy to set up
    var s = try init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 1 });
    defer s.deinit();

    // Scroll down enough to create a second page
    const start_page = &s.pages.pages.last.?.data;
    const rem = start_page.capacity.rows;
    start_page.pauseIntegrityChecks(true);
    for (0..rem) |_| try s.cursorDownOrScroll();
    start_page.pauseIntegrityChecks(false);

    // Cursor should now be on a new page
    const new_page = &s.cursor.page_pin.node.data;
    try testing.expect(start_page != new_page);

    // Fill new_page's style map to capacity. When we move INTO this page
    // with a style set, adjustCapacity will be triggered.
    {
        new_page.pauseIntegrityChecks(true);
        defer new_page.pauseIntegrityChecks(false);
        defer new_page.assertIntegrity();

        var n: u24 = 1;
        while (new_page.styles.add(
            new_page.memory,
            .{ .bg_color = .{ .rgb = @bitCast(n) } },
        )) |_| n += 1 else |_| {}
    }

    // Move cursor to start of active area and set a style
    s.cursorAbsolute(0, 0);
    try s.setAttribute(.bold);
    try testing.expect(s.cursor.style.flags.bold);
    try testing.expect(s.cursor.style_id != style.default_id);

    // Find the row just before the page boundary
    for (0..s.pages.rows - 1) |row| {
        s.cursorAbsolute(0, @intCast(row));
        const cur_node = s.cursor.page_pin.node;
        if (s.cursor.page_pin.down(1)) |next_pin| {
            if (next_pin.node != cur_node) {
                // Cursor is at 'row', moving down crosses to new_page
                try testing.expect(&next_pin.node.data == new_page);

                // This cursorDown triggers the bug: the local page_pin copy
                // becomes stale after adjustCapacity, causing rowAndCell()
                // to access freed memory.
                s.cursorDown(1);

                // If the fix is applied, verify correct state
                try testing.expect(s.cursor.y == row + 1);
                try testing.expect(s.cursor.style.flags.bold);

                break;
            }
        }
    } else {
        // Didn't find boundary
        try testing.expect(false);
    }
}

test "Screen setAttribute increases capacity when style map is full" {
    // Tests that setAttribute succeeds when the style map is full by
    // increasing page capacity. When capacity is at max and increaseCapacity
    // returns OutOfSpace, manualStyleUpdate will split the page instead.
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use a small screen with multiple rows
    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 10 });
    defer s.deinit();

    // Write content to multiple rows
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");

    // Get the page and fill its style map to capacity
    const page = &s.cursor.page_pin.node.data;
    const original_styles_capacity = page.capacity.styles;

    // Fill the style map to capacity using the StyleSet's layout capacity
    // which accounts for the load factor
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

    // Now try to set a new unique attribute that would require a new style slot
    // This should succeed by increasing capacity (or splitting if at max capacity)
    try s.setAttribute(.bold);

    // The style should have been applied (bold flag set)
    try testing.expect(s.cursor.style.flags.bold);

    // The cursor should have a valid non-default style_id
    try testing.expect(s.cursor.style_id != style.default_id);

    // Either the capacity increased or the page was split/changed
    const current_page = &s.cursor.page_pin.node.data;
    const capacity_increased = current_page.capacity.styles > original_styles_capacity;
    const page_changed = current_page != page;
    try testing.expect(capacity_increased or page_changed);
}

test "Screen setAttribute splits page on OutOfSpace at max styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{
        .cols = 10,
        .rows = 10,
        .max_scrollback = 0,
    });
    defer s.deinit();

    // Write content to multiple rows so we have something to split
    try s.testWriteString("line1\nline2\nline3\nline4\nline5");

    // Remember the original node
    const original_node = s.cursor.page_pin.node;

    // Increase the page's style capacity to max by repeatedly calling increaseCapacity
    // Use Screen.increaseCapacity to properly maintain cursor state
    const max_styles = std.math.maxInt(size.CellCountInt);
    while (s.cursor.page_pin.node.data.capacity.styles < max_styles) {
        _ = s.increaseCapacity(
            s.cursor.page_pin.node,
            .styles,
        ) catch break;
    }

    // Get the page reference after increaseCapacity - cursor may have moved
    var page = &s.cursor.page_pin.node.data;
    try testing.expectEqual(max_styles, page.capacity.styles);

    // Fill the style map to capacity using the StyleSet's layout capacity
    // which accounts for the load factor
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

    // Track the node before setAttribute
    const node_before_set = s.cursor.page_pin.node;

    // Now try to set a new unique attribute that would require a new style slot
    // At max capacity, increaseCapacity will return OutOfSpace, triggering page split
    try s.setAttribute(.bold);

    // The style should have been applied (bold flag set)
    try testing.expect(s.cursor.style.flags.bold);

    // The cursor should have a valid non-default style_id
    try testing.expect(s.cursor.style_id != style.default_id);

    // The page should have been split
    const page_was_split = s.cursor.page_pin.node != node_before_set or
        node_before_set.next != null or
        node_before_set.prev != null or
        s.cursor.page_pin.node != original_node;
    try testing.expect(page_was_split);
}

test "selectionString map allocation failure cleanup" {
    // This test verifies that if toOwnedSlice fails when building
    // the StringMap, we don't leak the already-allocated map.string.
    const testing = std.testing;
    const alloc = testing.allocator;
    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    try s.testWriteString("hello");

    // Get a selection
    const sel = Selection.init(
        s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?,
        false,
    );

    // Trigger allocation failure on toOwnedSlice
    var map: StringMap = undefined;
    selectionString_tw.errorAlways(.copy_map, error.OutOfMemory);
    const result = s.selectionString(alloc, .{
        .sel = sel,
        .map = &map,
    });
    try testing.expectError(error.OutOfMemory, result);
    try selectionString_tw.end(.reset);

    // If this test passes without memory leaks (when run with testing.allocator),
    // it means the errdefer properly cleaned up map.string when toOwnedSlice failed.
}

test "Screen: promptClickMove line right basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor back to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click on first 'l' (column 4), should require 2 right movements (h->e->l)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right cursor not on input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    s.cursorSetSemanticContent(.output);

    // Move cursor back to prompt area (column 0, the '>')
    s.cursorAbsolute(0, 0);

    // Cursor is on prompt, not input - should return zero
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right click on same position" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to column 4
    s.cursorAbsolute(4, 0);

    // Click on same position - no movement needed
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write: "> h" then output "X" then input "llo"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");

    // Move cursor to column 2 (the 'h')
    s.cursorAbsolute(2, 0);

    // Click on 'l' at column 5 - should skip the 'X' output cell
    // Movement: h (start) -> l (col 4) -> l (col 5) = 2 right movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 2), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input that wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    // Write 8 chars of input, first row has 2 for prompt + 8 input = 10 cols
    try s.testWriteString("abcdefgh");
    // Continue on next row (soft-wrapped)
    try s.testWriteString("ij");

    // Verify soft wrap occurred
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }

    // Move cursor to column 2 (the 'a')
    s.cursorAbsolute(2, 0);

    // Click on 'j' at column 1, row 1 - should count all input cells
    // Movement: a->b->c->d->e->f->g->h->i->j = 9 right movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 1, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 9), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove disabled when click is none" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Click mode is .none by default (disabled)
    try testing.expectEqual(Screen.SemanticPrompt.SemanticClick.none, s.semantic_prompt.click);

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input
    s.cursorAbsolute(2, 0);

    // Click should return zero since click mode is disabled
    const click_pin = s.pages.pin(.{ .active = .{ .x = 4, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(PromptClickMove.zero, result);
}

test "Screen: promptClickMove line right stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write prompt and input on first line
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    // Hard wrap (newline)
    try s.testWriteString("\n");
    try s.testWriteString("world");

    // Move cursor to column 2 (the 'h')
    s.cursorAbsolute(2, 0);

    // Click on 'w' at column 0, row 1 - but line mode stops at hard wrap
    // Should only move to end of first line: h->e->l->l->o = 4 movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at end of first line, not cross hard wrap
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line right stops at non-continuation row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Row 0: PROMPT "> hello"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello\n");

    // Row 1: CONTINUATION "world"
    s.cursorSetSemanticContent(.{ .prompt = .continuation });
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("world\n");

    // Row 2: NEW PROMPT "> again"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("again");

    // Verify content
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> hello\nworld\n> again", contents);
    }

    // Move cursor to 'w' at column 0, row 1
    s.cursorAbsolute(0, 1);

    // Click on 'a' at column 2, row 2 - but row 2 is a new prompt
    // Should stop at end of "world": w->o->r->l->d = 4 movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at 'd' (end of world), not cross to new prompt
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove line left basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is at column 7 (after 'o'), move it to column 6 (the 'o')
    s.cursorAbsolute(6, 0);

    // Click on 'h' (column 2), should require 4 left movements (o->l->l->e->h)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left skips non-input cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write: "> h" then output "X" then input "llo"
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("h");
    s.cursorSetSemanticContent(.output);
    try s.testWriteString("X");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("llo");

    // Move cursor to column 6 (the 'o')
    s.cursorAbsolute(6, 0);

    // Click on 'h' at column 2 - should skip the 'X' output cell
    // Movement: o->l->l->h = 3 left movements (skipping X)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 3), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left soft-wrapped line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input that wraps
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    // Write 8 chars of input, first row has 2 for prompt + 8 input = 10 cols
    try s.testWriteString("abcdefgh");
    // Continue on next row (soft-wrapped)
    try s.testWriteString("ij");

    // Verify soft wrap occurred
    {
        const contents = try s.dumpStringAlloc(alloc, .{ .viewport = .{} });
        defer alloc.free(contents);
        try testing.expectEqualStrings("> abcdefgh\nij", contents);
    }

    // Cursor is at column 2, row 1 (after 'j'). Move to 'j' at column 1.
    s.cursorAbsolute(1, 1);

    // Click on 'a' at column 2, row 0 - should count all input cells backwards
    // Movement: j->i->h->g->f->e->d->c->b->a = 9 left movements
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 9), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove line left stops at hard wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write prompt and input on first line, then hard wrap
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");
    // Hard wrap (newline)
    try s.testWriteString("\n");
    try s.testWriteString("world");

    // Move cursor to 'd' at column 4, row 1 (an actual input cell)
    s.cursorAbsolute(4, 1);

    // Click on 'h' at column 2, row 0 - but line mode stops at hard wrap
    // Should only move to start of second line, not cross to row 0
    const click_pin = s.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    // Should stop at start of second line: d->l->r->o->w = 4 movements
    try testing.expectEqual(@as(usize, 4), result.left);
    try testing.expectEqual(@as(usize, 0), result.right);
}

test "Screen: promptClickMove click right of input same line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Set up: "> hello" where "> " is prompt and "hello" is input
    // Clicking to the right of the 'o' should move cursor past the input

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click beyond the input (column 15) - should move to one past the 'o'
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor at end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is already at column 7 (one past 'o') after writing
    // Click beyond the input (column 15) - no movement needed since
    // cursor is already at the end position
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input on lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to start of input (column 2, the 'h')
    s.cursorAbsolute(2, 0);

    // Click on a lower line (row 1) - should move to end of input
    // This is outside the prompt area so should clamp to end
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    // From 'h', we need to pass e, l, l, o (4 cells) + 1 past end = 5
    try testing.expectEqual(@as(usize, 5), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor at end lower line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Cursor is at column 7 after writing (one past 'o')
    // Click on a lower line (row 1) - cursor already at end, no movement needed
    const click_pin = s.pages.pin(.{ .active = .{ .x = 5, .y = 1 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 0), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}

test "Screen: promptClickMove click right of input cursor on last char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();

    // Enable line click mode
    s.semantic_prompt.click = .{ .cl = .line };

    // Write a prompt and input
    s.cursorSetSemanticContent(.{ .prompt = .initial });
    try s.testWriteString("> ");
    s.cursorSetSemanticContent(.{ .input = .clear_explicit });
    try s.testWriteString("hello");

    // Move cursor to last input char (column 6, the 'o')
    s.cursorAbsolute(6, 0);

    // Click beyond the input (column 15)
    const click_pin = s.pages.pin(.{ .active = .{ .x = 15, .y = 0 } }).?;
    const result = s.promptClickMove(click_pin);

    try testing.expectEqual(@as(usize, 1), result.right);
    try testing.expectEqual(@as(usize, 0), result.left);
}
