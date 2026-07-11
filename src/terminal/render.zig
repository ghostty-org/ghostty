const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fastmem = @import("../fastmem.zig");
const lib = @import("lib.zig");
const color = @import("color.zig");
const cursor = @import("cursor.zig");
const highlight = @import("highlight.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const page = @import("page.zig");
const PageList = @import("PageList.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Style = @import("style.zig").Style;
const Terminal = @import("Terminal.zig");

// Developer note: this is in src/terminal and not src/renderer because
// the goal is that this remains generic to multiple renderers. This can
// aid specifically with libghostty-vt with converting terminal state to
// a renderable form.

/// Contains the state required to render the screen, including optimizing
/// for repeated render calls and only rendering dirty regions.
///
/// Previously, our renderer would use `clone` to clone the screen within
/// the viewport to perform rendering. This worked well enough that we kept
/// it all the way up through the Ghostty 1.2.x series, but the clone time
/// was repeatedly a bottleneck blocking IO.
///
/// Rather than a generic clone that tries to clone all screen state per call
/// (within a region), a stateful approach that optimizes for only what a
/// renderer needs to do makes more sense.
///
/// To use this, initialize the render state to empty, then call `update`
/// on each frame to update the state to the latest terminal state.
///
///     var state: RenderState = .empty;
///     defer state.deinit(alloc);
///     state.update(alloc, &terminal);
///
/// ## Two-Phase Updates
///
/// For callers that synchronize terminal access (e.g. a renderer thread
/// sharing a lock with an IO thread), the update can be split into two
/// phases to minimize the time the terminal must be held exclusively:
/// `beginUpdate` requires terminal access, while `endUpdate` completes
/// any deferred work using only memory owned by the render state.
///
///     {
///         mutex.lock();
///         defer mutex.unlock();
///         try state.beginUpdate(alloc, &terminal);
///     }
///
///     // The IO thread is free to modify the terminal while we
///     // complete the update.
///     state.endUpdate();
///
/// The render state must be treated as incomplete between the two calls.
/// `update` is a convenience that performs both phases in one call.
///
/// ## Memory
///
/// Note: the render state retains as much memory as possible between updates
/// to prevent future allocations. If a very large frame is rendered once,
/// the render state will retain that much memory until deinit. To avoid
/// waste, it is recommended that the caller `deinit` and start with an
/// empty render state every so often.
pub const RenderState = struct {
    /// The current screen dimensions. It is possible that these don't match
    /// the renderer's current dimensions in grid cells because resizing
    /// can happen asynchronously. For example, for Metal, our NSView resizes
    /// at a different time than when our internal terminal state resizes.
    /// This can lead to a one or two frame mismatch a renderer needs to
    /// handle.
    ///
    /// The viewport is always exactly equal to the active area size so this
    /// is also the viewport size.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// The color state for the terminal.
    colors: Colors,

    /// Cursor state within the viewport.
    cursor: Cursor,

    /// The rows (y=0 is top) of the viewport. Guaranteed to be `rows` length.
    ///
    /// This is a MultiArrayList because only the update cares about
    /// the allocators. Callers care about all the other properties, and
    /// this better optimizes cache locality for read access for those
    /// use cases.
    row_data: std.MultiArrayList(Row),

    /// The dirty state of the render state. This is set by the update method.
    /// The renderer/caller should set this to false when it has handled
    /// the dirty state.
    dirty: Dirty,

    /// The screen type that this state represents. This is used primarily
    /// to detect changes.
    screen: ScreenSet.Key,

    /// The last viewport pin used to generate this state. This is NOT
    /// a tracked pin and is generally NOT safe to read other than the direct
    /// values for comparison.
    viewport_pin: ?PageList.Pin = null,

    /// The cached selection so we can avoid expensive selection calculations
    /// if possible.
    selection_cache: ?SelectionCache = null,

    /// The pending style runs requiring an endUpdate call, in the
    /// order they were recorded. If multiple begins happen without an
    /// endUpdate call, runs accumulate; rows rebuilt more than once
    /// may then have superseded (stale) runs in this list, which is
    /// harmless: newer runs are appended later so they win, and cells
    /// not covered by newer runs have a default style ID in their raw
    /// data so their style is undefined by contract anyway. See
    /// beginUpdate.
    pending_styles: std.ArrayList(StyleRun) = .empty,

    /// Initial state.
    pub const empty: RenderState = .{
        .rows = 0,
        .cols = 0,
        .colors = .{
            .background = .{ .r = 0, .g = 0, .b = 0 },
            .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
            .cursor = null,
            .palette = color.default,
        },
        .cursor = .{
            .active = .{ .x = 0, .y = 0 },
            .viewport = null,
            .cell = .{},
            .style = undefined,
            .visual_style = .block,
            .password_input = false,
            .visible = true,
            .blinking = false,
        },
        .row_data = .empty,
        .dirty = .false,
        .screen = .primary,
    };

    /// The color state for the terminal.
    ///
    /// The background/foreground will be reversed if the terminal reverse
    /// color mode is on! You do not need to handle that manually!
    pub const Colors = struct {
        background: color.RGB,
        foreground: color.RGB,
        cursor: ?color.RGB,
        palette: color.Palette,
    };

    pub const Cursor = struct {
        /// The x/y position of the cursor within the active area.
        active: point.Coordinate,

        /// The x/y position of the cursor within the viewport. This
        /// may be null if the cursor is not visible within the viewport.
        viewport: ?Viewport,

        /// The cell data for the cursor position. Managed memory is not
        /// safe to access from this.
        cell: page.Cell,

        /// The style, always valid even if the cell is default style.
        style: Style,

        /// The visual style of the cursor itself, such as a block or
        /// bar.
        visual_style: cursor.Style,

        /// True if the cursor is detected to be at a password input field.
        password_input: bool,

        /// Cursor visibility state determined by the terminal mode.
        visible: bool,

        /// Cursor blink state determined by the terminal mode.
        blinking: bool,

        pub const Viewport = struct {
            /// The x/y position of the cursor within the viewport.
            x: size.CellCountInt,
            y: size.CellCountInt,

            /// Whether the cursor is part of a wide character and
            /// on the tail of it. If so, some renderers may use this
            /// to move the cursor back one.
            wide_tail: bool,
        };
    };

    /// A row within the viewport.
    pub const Row = struct {
        /// Arena used for any heap allocations for cell contents
        /// in this row. Importantly, this is NOT used for the MultiArrayList
        /// itself. We do this on purpose so that we can easily clear rows,
        /// but retain cached MultiArrayList capacities since grid sizes don't
        /// change often.
        arena: ArenaAllocator.State,

        /// The page pin. Its copied values may be compared, but its node must
        /// not be dereferenced unless the terminal state is protected from
        /// changes since the last `update` call.
        pin: PageList.Pin,

        /// The page node generation captured alongside `pin`. This lets
        /// consumers validate the pin without dereferencing its node after
        /// the terminal lock has been released.
        serial: u64,

        /// Raw row data.
        raw: page.Row,

        /// The cells in this row. Guaranteed to be `cols` length.
        cells: std.MultiArrayList(Cell),

        /// A dirty flag that can be used by the renderer to track
        /// its own draw state. `update` will mark this true whenever
        /// this row is changed, too.
        dirty: bool,

        /// The x range of the selection within this row.
        selection: ?[2]size.CellCountInt,

        /// The highlights within this row.
        highlights: std.ArrayList(Highlight),
    };

    pub const Highlight = struct {
        /// A special tag that can be used by the caller to differentiate
        /// different highlight types. The value is opaque to the RenderState.
        tag: u8,

        /// The x ranges of highlights within this row.
        range: [2]size.CellCountInt,
    };

    pub const Cell = struct {
        /// Always set, this is the raw copied cell data from page.Cell.
        /// The managed memory (hyperlinks, graphames, etc.) is NOT safe
        /// to access from here. It is duplicated into the other fields if
        /// it exists.
        raw: page.Cell,

        /// Grapheme data for the cell. This is undefined unless the
        /// raw cell's content_tag is `codepoint_grapheme`.
        grapheme: []const u21,

        /// The style data for the cell. This is undefined unless
        /// the style_id is non-default on raw.
        style: Style,
    };

    // Dirty state.
    pub const Dirty = lib.Enum(lib.target, &.{
        // Not dirty at all. Can skip rendering if prior state was
        // already rendered.
        "false",

        // Some rows changed but not all. None of the global state
        // changed such as colors.
        "partial",

        // Global state changed or dimensions changed. All rows should
        // be redrawn.
        "full",
    });

    const SelectionCache = struct {
        selection: Selection,
        tl_pin: PageList.Pin,
        br_pin: PageList.Pin,
    };

    /// A run of cells within one row sharing one style, pending
    /// denormalization into the per-cell data. This is populated by
    /// `beginUpdate` and consumed by `endUpdate`. This exists so that
    /// the (potentially large) denormalization of styles into cells
    /// can happen outside of any terminal locks. See `beginUpdate`.
    pub const StyleRun = struct {
        /// The viewport row.
        y: size.CellCountInt,

        /// Start (inclusive) and end (exclusive) x coordinates.
        start: size.CellCountInt,
        end: size.CellCountInt,

        /// The style for this cell range.
        style: Style,
    };

    pub fn deinit(self: *RenderState, alloc: Allocator) void {
        for (
            self.row_data.items(.arena),
            self.row_data.items(.cells),
        ) |state, *cells| {
            var arena: ArenaAllocator = state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
        }
        self.row_data.deinit(alloc);
        self.pending_styles.deinit(alloc);
    }

    /// Update the render state to the latest terminal state.
    ///
    /// This is a convenience function that performs a full update in
    /// one call, equivalent to `beginUpdate` immediately followed by
    /// `endUpdate`. Callers that hold a lock over the terminal state
    /// should prefer calling the two phases directly so that the lock
    /// is only held for `beginUpdate`.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn update(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        try self.beginUpdate(alloc, t);
        self.endUpdate();
    }

    /// Begin an update of the render state to the latest terminal
    /// state. Every begin must be completed with an `endUpdate` call
    /// before the render state is read.
    ///
    /// This two-phase structure exists for callers that lock the
    /// terminal state: only this function requires terminal access, so
    /// a caller can hold its lock for this call only and then call
    /// `endUpdate` after releasing it. `endUpdate` exclusively reads
    /// and writes memory owned by the render state.
    ///
    /// Work that doesn't require terminal access may be deferred to
    /// `endUpdate` to keep this call (and therefore lock hold time) as
    /// short as possible. At the time of writing, the deferred work is
    /// the per-cell style denormalization, so between this call and
    /// `endUpdate` the per-cell `style` data of any updated rows is
    /// stale and must not be read. More work may be deferred in the
    /// future; callers should treat the render state as incomplete
    /// until `endUpdate` is called.
    ///
    /// This will reset the terminal dirty state since it is consumed
    /// by this render state update.
    pub fn beginUpdate(
        self: *RenderState,
        alloc: Allocator,
        t: *Terminal,
    ) Allocator.Error!void {
        const s: *Screen = t.screens.active;
        const viewport_pin = s.pages.getTopLeft(.viewport);
        const redraw = redraw: {
            // If our screen key changed, we need to do a full rebuild
            // because our render state is viewport-specific.
            if (t.screens.active_key != self.screen) break :redraw true;

            // If our terminal is dirty at all, we do a full rebuild. These
            // dirty values are full-terminal dirty values.
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :redraw true;
            }

            // If our screen is dirty at all, we do a full rebuild. This is
            // a full screen dirty tracker.
            {
                const Int = @typeInfo(Screen.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.screens.active.dirty);
                if (v > 0) break :redraw true;
            }

            // If our dimensions changed, we do a full rebuild.
            if (self.rows != s.pages.rows or
                self.cols != s.pages.cols)
            {
                break :redraw true;
            }

            // If our viewport pin changed, we do a full rebuild.
            if (self.viewport_pin) |old| {
                if (!old.eql(viewport_pin)) break :redraw true;
            }

            break :redraw false;
        };

        // Always set our cheap fields, its more expensive to compare
        self.rows = s.pages.rows;
        self.cols = s.pages.cols;
        self.viewport_pin = viewport_pin;
        self.cursor.active = .{ .x = s.cursor.x, .y = s.cursor.y };
        self.cursor.cell = s.cursor.page_cell.*;
        self.cursor.style = s.cursor.style;
        self.cursor.visual_style = s.cursor.cursor_style;
        self.cursor.password_input = t.flags.password_input;
        self.cursor.visible = t.modes.get(.cursor_visible);
        self.cursor.blinking = t.modes.get(.cursor_blinking);

        // Always reset the cursor viewport position. In the future we can
        // probably cache this by comparing the cursor pin and viewport pin
        // but may not be worth it.
        self.cursor.viewport = null;

        // Colors.
        self.colors.cursor = t.colors.cursor.get();

        // The palette is a relatively large copy (768 bytes at the time
        // of writing) so we only copy it when it could have changed. All
        // palette modifications set a terminal-level dirty flag (see
        // Terminal.Dirty.palette), and any terminal-level dirty flag
        // forces a redraw, so checking redraw is sufficient.
        if (redraw) self.colors.palette = t.colors.palette.current;

        bg_fg: {
            // Background/foreground can be unset initially which would
            // depend on "default" background/foreground. The expected use
            // case of Terminal is that the caller set their own configured
            // defaults on load so this doesn't happen.
            const bg = t.colors.background.get() orelse break :bg_fg;
            const fg = t.colors.foreground.get() orelse break :bg_fg;
            if (t.modes.get(.reverse_colors)) {
                self.colors.background = fg;
                self.colors.foreground = bg;
            } else {
                self.colors.background = bg;
                self.colors.foreground = fg;
            }
        }

        // Ensure our row length is exactly our height, freeing or allocating
        // data as necessary. In most cases we'll have a perfectly matching
        // size.
        if (self.row_data.len != self.rows) {
            @branchHint(.unlikely);

            if (self.row_data.len < self.rows) {
                // Resize our rows to the desired length, marking any added
                // values undefined.
                const old_len = self.row_data.len;
                try self.row_data.resize(alloc, self.rows);

                // Initialize all our values. Its faster to use slice() + set()
                // because appendAssumeCapacity does this multiple times.
                var row_data = self.row_data.slice();
                for (old_len..self.rows) |y| {
                    row_data.set(y, .{
                        .arena = .{},
                        .pin = undefined,
                        .serial = undefined,
                        .raw = undefined,
                        .cells = .empty,
                        .dirty = true,
                        .selection = null,
                        .highlights = .empty,
                    });
                }
            } else {
                const row_data = self.row_data.slice();
                for (
                    row_data.items(.arena)[self.rows..],
                    row_data.items(.cells)[self.rows..],
                ) |state, *cell| {
                    var arena: ArenaAllocator = state.promote(alloc);
                    arena.deinit();
                    cell.deinit(alloc);
                }
                self.row_data.shrinkRetainingCapacity(self.rows);
            }
        }

        // Break down our row data
        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_rows = row_data.items(.raw);
        const row_cells = row_data.items(.cells);
        const row_sels = row_data.items(.selection);
        const row_highlights = row_data.items(.highlights);
        const row_dirties = row_data.items(.dirty);

        // If we're redrawing then every row will be rebuilt, superseding
        // any pending style runs from prior updates. Clearing also
        // guarantees pending runs always match the current dimensions
        // (dimension changes force a redraw).
        if (redraw) self.pending_styles.clearRetainingCapacity();

        // Go through and setup our rows. We iterate page chunks rather
        // than individual rows so that per-page work (dirty flags, cursor
        // detection, memory pointers) is hoisted out of the row loop. This
        // makes the common case of a clean (or mostly clean) frame very
        // cheap: a contiguous scan of row dirty flags.
        const builder: RowBuilder = .{
            .alloc = alloc,
            .cols = self.cols,
            .arenas = row_arenas,
            .raws = row_rows,
            .cells = row_cells,
            .sels = row_sels,
            .highlights = row_highlights,
            .dirties = row_dirties,
            .pending_styles = &self.pending_styles,
        };
        var y: usize = 0;
        var any_dirty: bool = false;
        var page_it = viewport_pin.pageIterator(.right_down, null);
        while (y < self.rows) {
            const chunk = page_it.next() orelse break;
            const node = chunk.node;
            const node_serial = node.serial;
            const p: *page.Page = node.page();

            // The number of rows we consume from this chunk. The chunk
            // may extend beyond the viewport (the viewport is always
            // exactly `rows` tall) so we clamp.
            const take: usize = @min(
                @as(usize, chunk.end - chunk.start),
                self.rows - y,
            );

            // Find our cursor if we haven't found it yet. We do this even
            // if rows are not dirty because the cursor is unrelated. We
            // can check the chunk bounds once rather than every row.
            if (self.cursor.viewport == null and
                node == s.cursor.page_pin.node)
            cursor: {
                const cy = s.cursor.page_pin.y;
                if (cy < chunk.start or cy >= chunk.start + take) break :cursor;
                self.cursor.viewport = .{
                    .y = @intCast(y + (cy - chunk.start)),
                    .x = s.cursor.x,

                    // Future: we should use our own state here to look this
                    // up rather than calling this.
                    .wide_tail = if (s.cursor.x > 0)
                        s.cursorCellLeft(1).wide == .wide
                    else
                        false,
                };
            }

            // The page-level dirty flag applies to every row in the chunk.
            // We consume (clear) it now; each node appears at most once in
            // this iteration and we're the only consumer of dirty state.
            const page_dirty = p.dirty;
            if (page_dirty) p.dirty = false;

            // Get our contiguous rows for this chunk.
            const page_rows: []page.Row = p.rows.ptr(p.memory)[chunk.start..][0..take];
            assert(p.size.cols == self.cols);

            // Store our pins and their node generations. We have to store
            // these even for rows that aren't dirty because dirty is only a
            // renderer optimization; it doesn't apply to memory movement.
            // This lets us remap any cell pins back to an exact entry in our
            // RenderState and validate them later without dereferencing a
            // potentially stale node.
            //
            // We can skip the writes when the pins and serials are unchanged:
            // if we're not redrawing, every value was stored by a prior update
            // (row count changes force a redraw). Within a single update a
            // node appears at most once and its stored pins have consecutive
            // y values, so if the first and last entries of this chunk's range
            // already match then every entry in between matches too.
            if (redraw or
                row_pins[y].node != node or
                row_pins[y].y != chunk.start or
                row_serials[y] != node_serial or
                row_pins[y + take - 1].node != node or
                row_pins[y + take - 1].y != chunk.start + take - 1 or
                row_serials[y + take - 1] != node_serial)
            {
                for (
                    row_pins[y..][0..take],
                    row_serials[y..][0..take],
                    chunk.start..,
                ) |*pin, *serial, py| {
                    pin.* = .{ .node = node, .y = @intCast(py) };
                    serial.* = node_serial;
                }
            }

            if (!redraw and !page_dirty) {
                // Only dirty rows (usually none) need a rebuild. Scan the
                // dirty flags a group at a time; the dirty bit is directly
                // testable on the packed row representation.
                var i: usize = 0;
                while (take - i >= RowDirtyMask.group_len) : (i += RowDirtyMask.group_len) {
                    if (RowDirtyMask.match(page_rows, i)) {
                        @branchHint(.likely);
                        continue;
                    }

                    for (page_rows[i..][0..RowDirtyMask.group_len], i..) |*page_row, j| {
                        if (!page_row.dirty) continue;
                        page_row.dirty = false;
                        any_dirty = true;
                        try builder.row(p, page_row, y + j);
                    }
                }
                while (i < take) : (i += 1) {
                    const page_row = &page_rows[i];
                    if (!page_row.dirty) continue;
                    page_row.dirty = false;
                    any_dirty = true;
                    try builder.row(p, page_row, y + i);
                }
            } else {
                // Rebuild every row in the chunk.
                any_dirty = true;
                for (page_rows, 0..) |*page_row, i| {
                    page_row.dirty = false;
                    try builder.row(p, page_row, y + i);
                }
            }

            y += take;
        }
        assert(y == self.rows);

        // If our screen has a selection, then mark the rows with the
        // selection. We do this outside of the loop above because its unlikely
        // a selection exists and because the way our selections are structured
        // today is very inefficient.
        //
        // NOTE: To improve the performance of the block below, we'll need
        // to rethink how we model selections in general.
        //
        // There are performance improvements that can be made here, though.
        // For example, `containedRow` recalculates a bunch of information
        // we can cache.
        if (s.selection) |*sel| selection: {
            @branchHint(.unlikely);

            // Populate our selection cache to avoid some expensive
            // recalculation.
            const cache: *const SelectionCache = cache: {
                if (self.selection_cache) |*c| cache_check: {
                    // If we're redrawing, we recalculate the cache just to
                    // be safe.
                    if (redraw) break :cache_check;

                    // If our selection isn't equal, we aren't cached!
                    if (!c.selection.eql(sel.*)) break :cache_check;

                    // If we have no dirty rows, we can not recalculate.
                    if (!any_dirty) break :selection;

                    // We have dirty rows, we can utilize the cache.
                    break :cache c;
                }

                // Create a new cache
                const tl_pin = sel.topLeft(s);
                const br_pin = sel.bottomRight(s);
                self.selection_cache = .{
                    .selection = .init(tl_pin, br_pin, sel.rectangle),
                    .tl_pin = tl_pin,
                    .br_pin = br_pin,
                };
                break :cache &self.selection_cache.?;
            };

            // Grab the inefficient data we need from the selection. At
            // least we can cache it.
            const tl = s.pages.pointFromPin(.screen, cache.tl_pin).?.screen;
            const br = s.pages.pointFromPin(.screen, cache.br_pin).?.screen;

            // We need to determine if our selection is within the viewport.
            // The viewport is generally very small so the efficient way to
            // do this is to traverse the viewport pages and check for the
            // matching selection pages.
            for (
                row_pins,
                row_sels,
            ) |pin, *sel_bounds| {
                const p = s.pages.pointFromPin(.screen, pin).?.screen;
                const row_sel = sel.containedRowCached(
                    s,
                    cache.tl_pin,
                    cache.br_pin,
                    pin,
                    tl,
                    br,
                    p,
                ) orelse continue;
                const start = row_sel.start();
                const end = row_sel.end();
                assert(start.node == end.node);
                assert(start.x <= end.x);
                assert(start.y == end.y);
                sel_bounds.* = .{ start.x, end.x };
            }
        }

        // Handle dirty state.
        if (redraw) {
            // Fully redraw resets some other state.
            self.screen = t.screens.active_key;
            self.dirty = .full;

            // Note: we don't clear any row_data here because our rebuild
            // above did this.
        } else if (any_dirty and self.dirty == .false) {
            self.dirty = .partial;
        }

        // Clear our dirty flags
        t.flags.dirty = .{};
        s.dirty = .{};
    }

    /// Complete a prior `beginUpdate` call by performing any deferred
    /// work. At the time of writing, this denormalizes the pending
    /// style runs into the per-cell style data.
    ///
    /// This only reads and writes memory owned by the render state, so
    /// it is safe to call while the terminal is being modified (no
    /// terminal lock is required).
    pub fn endUpdate(self: *RenderState) void {
        // Common case: no styled rows were rebuilt.
        if (self.pending_styles.items.len == 0) return;

        const row_data = self.row_data.slice();
        const row_cells = row_data.items(.cells);
        for (self.pending_styles.items) |run| {
            // Defensive: the row data may have changed shape if the
            // caller violated ordering (e.g. an error path skipped an
            // endUpdate between updates). Any update that changes
            // dimensions clears the pending list (redraw), so this
            // should never actually trigger, but the cost is trivial.
            if (run.y >= row_cells.len) continue;
            const styles = row_cells[run.y].slice().items(.style);
            const end = @min(run.end, styles.len);
            const start = @min(run.start, end);

            @memset(styles[start..end], run.style);
        }
        self.pending_styles.clearRetainingCapacity();
    }

    /// Update the highlights in the render state from the given flattened
    /// highlights. Because this uses flattened highlights, it does not require
    /// reading from the terminal state so it should be done outside of
    /// any critical sections.
    ///
    /// This will not clear any previous highlights, so the caller must
    /// manually clear them if desired.
    pub fn updateHighlightsFlattened(
        self: *RenderState,
        alloc: Allocator,
        tag: u8,
        hls: []const highlight.Flattened,
    ) Allocator.Error!void {
        // Fast path, we have no highlights!
        if (hls.len == 0) return;

        // This is, admittedly, horrendous. This is some low hanging fruit
        // to optimize. In my defense, screens are usually small, the number
        // of highlights is usually small, and this only happens on the
        // viewport outside of a locked area. Still, I'd love to see this
        // improved someday.

        // We need to track whether any row had a match so we can mark
        // the dirty state.
        var any_dirty: bool = false;

        const row_data = self.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_dirties = row_data.items(.dirty);
        const row_pins = row_data.items(.pin);
        const row_serials = row_data.items(.serial);
        const row_highlights_slice = row_data.items(.highlights);
        for (
            row_arenas,
            row_pins,
            row_serials,
            row_highlights_slice,
            row_dirties,
        ) |*row_arena, row_pin, row_serial, *row_highlights, *dirty| {
            for (hls) |hl| {
                const chunks_slice = hl.chunks.slice();
                const nodes = chunks_slice.items(.node);
                const serials = chunks_slice.items(.serial);
                const starts = chunks_slice.items(.start);
                const ends = chunks_slice.items(.end);
                for (0.., nodes) |i, node| {
                    // If this node generation doesn't match or we're not
                    // within the row range, skip it. Both serials are copied
                    // values, so this never dereferences a node outside the
                    // terminal lock.
                    if (node != row_pin.node or
                        serials[i] != row_serial or
                        row_pin.y < starts[i] or
                        row_pin.y >= ends[i]) continue;

                    // We're a match!
                    var arena = row_arena.promote(alloc);
                    defer row_arena.* = arena.state;
                    const arena_alloc = arena.allocator();
                    try row_highlights.append(
                        arena_alloc,
                        .{
                            .tag = tag,
                            .range = .{
                                if (i == 0 and
                                    row_pin.y == starts[0])
                                    hl.top_x
                                else
                                    0,
                                if (i == nodes.len - 1 and
                                    row_pin.y == ends[nodes.len - 1] - 1)
                                    hl.bot_x
                                else
                                    self.cols - 1,
                            },
                        },
                    );

                    dirty.* = true;
                    any_dirty = true;
                }
            }
        }

        // Mark our dirty state.
        if (any_dirty and self.dirty == .false) self.dirty = .partial;
    }

    pub const StringMap = std.ArrayListUnmanaged(point.Coordinate);

    /// Convert the current render state contents to a UTF-8 encoded
    /// string written to the given writer. This will unwrap all the wrapped
    /// rows. This is useful for a minimal viewport search.
    ///
    /// This currently writes empty cell contents as \x00 and writes all
    /// blank lines. This is fine for our current usage (link search) but
    /// we can adjust this later.
    ///
    /// NOTE: There is a limitation in that wrapped lines before/after
    /// the top/bottom line of the viewport are not included, since
    /// the render state cuts them off.
    pub fn string(
        self: *const RenderState,
        writer: *std.Io.Writer,
        map: ?struct {
            alloc: Allocator,
            map: *StringMap,
        },
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        const row_slice = self.row_data.slice();
        const row_rows = row_slice.items(.raw);
        const row_cells = row_slice.items(.cells);

        for (
            0..,
            row_rows,
            row_cells,
        ) |y, row, cells| {
            const cells_slice = cells.slice();
            for (
                0..,
                cells_slice.items(.raw),
                cells_slice.items(.grapheme),
            ) |x, cell, graphemes| {
                var len: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch
                    return error.WriteFailed;
                try writer.print("{u}", .{cell.codepoint()});
                if (cell.hasGrapheme()) {
                    for (graphemes) |cp| {
                        len += std.unicode.utf8CodepointSequenceLength(cp) catch
                            return error.WriteFailed;
                        try writer.print("{u}", .{cp});
                    }
                }

                if (map) |m| try m.map.appendNTimes(m.alloc, .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                }, len);
            }

            if (!row.wrap) {
                try writer.writeAll("\n");
                if (map) |m| try m.map.append(m.alloc, .{
                    .x = @intCast(cells_slice.len),
                    .y = @intCast(y),
                });
            }
        }
    }

    /// A set of coordinates representing cells.
    pub const CellSet = std.AutoArrayHashMapUnmanaged(point.Coordinate, void);

    /// Returns a map of the cells that match to an OSC8 hyperlink over the
    /// given point in the render state.
    ///
    /// IMPORTANT: The terminal must not have updated since the last call to
    /// `update`. If there is any chance the terminal has updated, the caller
    /// must first call `update` again to refresh the render state.
    ///
    /// For example, you may want to hold a lock for the duration of the
    /// update and hyperlink lookup to ensure no updates happen in between.
    pub fn linkCells(
        self: *const RenderState,
        alloc: Allocator,
        viewport_point: point.Coordinate,
    ) Allocator.Error!CellSet {
        var result: CellSet = .empty;
        errdefer result.deinit(alloc);

        const row_slice = self.row_data.slice();
        const row_pins = row_slice.items(.pin);
        const row_cells = row_slice.items(.cells);

        // Our viewport point is sent in by the caller and can't be trusted.
        // If it is outside the valid area then just return empty because
        // we can't possibly have a link there.
        if (viewport_point.x >= self.cols or
            viewport_point.y >= row_pins.len) return result;

        // Grab our link ID
        const link_pin: PageList.Pin = row_pins[viewport_point.y];
        const link_page: *page.Page = link_pin.node.page();
        const link = link: {
            const rac = link_page.getRowAndCell(
                viewport_point.x,
                link_pin.y,
            );

            // The likely scenario is that our mouse isn't even over a link.
            if (!rac.cell.hyperlink) {
                @branchHint(.likely);
                return result;
            }

            const link_id = link_page.lookupHyperlink(rac.cell) orelse
                return result;
            break :link link_page.hyperlink_set.get(
                link_page.memory,
                link_id,
            );
        };

        for (
            0..,
            row_pins,
            row_cells,
        ) |y, pin, cells| {
            for (0.., cells.items(.raw)) |x, cell| {
                if (!cell.hyperlink) continue;

                const other_page: *page.Page = pin.node.page();
                const other = link: {
                    const rac = other_page.getRowAndCell(x, pin.y);
                    const link_id = other_page.lookupHyperlink(rac.cell) orelse continue;
                    break :link other_page.hyperlink_set.get(
                        other_page.memory,
                        link_id,
                    );
                };

                if (link.eql(
                    link_page.memory,
                    other,
                    other_page.memory,
                )) try result.put(alloc, .{
                    .y = @intCast(y),
                    .x = @intCast(x),
                }, {});
            }
        }

        return result;
    }
};

/// The number of rows/cells we scan as a single group when looking for
/// dirty rows or special cells. Rows and cells are small packed structs
/// so a group is scanned with a handful of vector operations.
const scan_group_len = 8;

/// Group scan helper for the row dirty flag. A row that matches has
/// its dirty flag unset.
const RowDirtyMask = page.Mask(
    page.Row,
    &.{"dirty"},
    scan_group_len,
);

/// Group scan helper for the cell fields that require managed memory
/// handling. A cell that matches is a plain (possibly zero) codepoint
/// with a default style, requiring no work beyond the raw copy. See
/// RowBuilder.row.
const CellSpecialMask = page.Mask(page.Cell, &.{
    "content_tag",
    "style_id",
}, scan_group_len);

/// Internal helper for RenderState.update that rebuilds a single row of
/// the render state from the current page contents.
const RowBuilder = struct {
    alloc: Allocator,
    cols: usize,
    arenas: []ArenaAllocator.State,
    raws: []page.Row,
    cells: []std.MultiArrayList(RenderState.Cell),
    sels: []?[2]size.CellCountInt,
    highlights: []std.ArrayList(RenderState.Highlight),
    dirties: []bool,
    pending_styles: *std.ArrayList(RenderState.StyleRun),

    fn row(
        b: *const RowBuilder,
        p: *page.Page,
        page_row: *const page.Row,
        vy: usize,
    ) Allocator.Error!void {
        // Promote our arena. State is copied by value so we need to
        // restore it on all exit paths so we don't leak memory.
        var arena = b.arenas[vy].promote(b.alloc);
        defer b.arenas[vy] = arena.state;

        // Reset our per-row state if we're rebuilding this row. A
        // non-zero cell length means the row was populated by a prior
        // update.
        if (b.cells[vy].len > 0) {
            _ = arena.reset(.retain_capacity);
            b.sels[vy] = null;
            b.highlights[vy] = .empty;
        }
        b.dirties[vy] = true;

        // Get all our cells in the page.
        const page_cells: []const page.Cell = page_row.cells.ptr(p.memory)[0..b.cols];

        // Copy our raw row data
        b.raws[vy] = page_row.*;

        // Note: our cells MultiArrayList uses our general allocator.
        // We do this on purpose because as rows become dirty, we do
        // not want to reallocate space for cells (which are large). This
        // was a source of huge slowdown.
        //
        // Our per-row arena is only used for temporary allocations
        // pertaining to cells directly (e.g. graphemes, hyperlinks).
        const cells: *std.MultiArrayList(RenderState.Cell) = &b.cells[vy];
        if (cells.len != b.cols) try cells.resize(b.alloc, b.cols);

        // We always copy our raw cell data. In the case we have no
        // managed memory, we can skip setting any other fields.
        //
        // This is an important optimization. For plain-text screens
        // this ends up being something around 300% faster based on
        // the `screen-clone` benchmark.
        const cells_slice = cells.slice();
        fastmem.copy(
            page.Cell,
            cells_slice.items(.raw),
            page_cells,
        );
        if (!page_row.managedMemory()) return;

        const arena_alloc = arena.allocator();
        const cells_grapheme = cells_slice.items(.grapheme);
        const n = page_cells.len;
        var x: usize = 0;
        scan: while (x < n) {
            // Skip runs of plain cells a group at a time. Cells that
            // need managed handling are often rare even within rows that
            // have managed memory (e.g. a row is "styled" if a single
            // cell has a style) so groups are skipped with a few vector
            // operations.
            while (n - x >= CellSpecialMask.group_len) {
                if (!CellSpecialMask.match(page_cells, x)) break;
                x += CellSpecialMask.group_len;
            }

            // Scalar scan to the next special cell.
            while (true) {
                if (x >= n) break :scan;
                if (!CellSpecialMask.matchScalar(page_cells[x])) break;
                x += 1;
            }

            const page_cell = &page_cells[x];

            switch (page_cell.content_tag) {
                // Single-codepoint styled cells are by far the most
                // common special cells, and they usually come in long
                // runs sharing one style ID (e.g. a fully styled row
                // usually uses a single style). Find the run and record
                // it: this does one style lookup per run and defers the
                // (large) per-cell fill to endUpdate, outside of any
                // terminal locks.
                .codepoint => {
                    @branchHint(.likely);
                    const sid = page_cell.style_id;
                    assert(sid > 0); // special + codepoint implies styled
                    const style_val: Style = p.styles.get(p.memory, sid).*;

                    // A cell continues the run if its masked special
                    // bits are exactly the style ID of the run (in
                    // particular the content tag must be a plain
                    // codepoint). We can check groups of cells at a
                    // time this way.
                    const pattern = CellSpecialMask.pattern(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eql(
                            page_cells,
                            x,
                            pattern,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (!CellSpecialMask.eqlScalar(
                            page_cells[x],
                            pattern,
                        )) break;
                    }

                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });
                },

                // If we have a multi-codepoint grapheme, look it up and
                // set our content type. Note grapheme cells may also
                // be styled. The style must be recorded as a run (rather
                // than written directly) so that it is ordered correctly
                // relative to possibly-stale runs from prior updates.
                .codepoint_grapheme => {
                    if (page_cell.style_id > 0) {
                        try b.pending_styles.append(b.alloc, .{
                            .y = @intCast(vy),
                            .start = @intCast(x),
                            .end = @intCast(x + 1),
                            .style = p.styles.get(
                                p.memory,
                                page_cell.style_id,
                            ).*,
                        });
                    }
                    cells_grapheme[x] = try arena_alloc.dupe(
                        u21,
                        p.lookupGrapheme(page_cell) orelse &.{},
                    );
                    x += 1;
                },

                // Background-color-only cells. The style is derived
                // entirely from the cell contents. Consecutive cleared
                // cells with the same background are bit-identical, so
                // we run-detect on full equality (e.g. a line cleared
                // with a background color pending is one run).
                .bg_color_rgb, .bg_color_palette => {
                    const style_val: Style = switch (page_cell.content_tag) {
                        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
                            .r = page_cell.content.color_rgb.r,
                            .g = page_cell.content.color_rgb.g,
                            .b = page_cell.content.color_rgb.b,
                        } } },
                        .bg_color_palette => .{ .bg_color = .{
                            .palette = page_cell.content.color_palette,
                        } },
                        else => unreachable,
                    };

                    const first_bits = CellSpecialMask.bits(page_cell.*);
                    const start = x;
                    x += 1;
                    while (n - x >= CellSpecialMask.group_len) {
                        if (!CellSpecialMask.eqlExact(
                            page_cells,
                            x,
                            first_bits,
                        )) break;
                        x += CellSpecialMask.group_len;
                    }
                    while (x < n) : (x += 1) {
                        if (CellSpecialMask.bits(page_cells[x]) != first_bits)
                            break;
                    }

                    try b.pending_styles.append(b.alloc, .{
                        .y = @intCast(vy),
                        .start = @intCast(start),
                        .end = @intCast(x),
                        .style = style_val,
                    });
                },
            }
        }
    }
};

test "styled" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);

    // This fills the screen up
    try t.decaln();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
}

test "basic text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCD");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual('D', cells[0].get(3).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(4).raw.codepoint());
}

test "styled text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mA"); // Bold
    s.nextSlice("\x1b[0;3mB"); // Italic
    s.nextSlice("\x1b[0;4mC"); // Underline

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual('B', cell.raw.codepoint());
        try testing.expect(!cell.style.flags.bold);
        try testing.expect(cell.style.flags.italic);
    }
    try testing.expectEqual('C', cells[0].get(2).raw.codepoint());
    try testing.expectEqual(0, cells[0].get(3).raw.codepoint());
}

/// Verifies that an incrementally updated render state has identical
/// contents to a from-scratch rebuild. This is the load-bearing check
/// for our dirty tracking: if any terminal operation changes row
/// contents without setting a dirty signal that `update` honors
/// (terminal dirty, screen dirty, page dirty, row dirty, viewport pin,
/// or dimensions), the incremental state will contain stale rows and
/// this comparison will fail.
fn testCompareStates(
    incremental: *const RenderState,
    fresh: *const RenderState,
) !void {
    const testing = std.testing;

    // Row metadata that is allowed to be stale in an incremental
    // update. Dirty tracking only guarantees that VISUAL changes are
    // flagged (see page.Row.dirty); these fields are non-visual
    // metadata that the terminal may change without dirtying the row
    // (e.g. Screen.cursorResetWrap clears wrap flags without a dirty
    // mark). This staleness predates the chunked update
    // implementation; it is present in the row-iterator implementation
    // as well.
    const StaleOkMask = page.Mask(page.Row, &.{
        "wrap",
        "wrap_continuation",
        "semantic_prompt",
        "dirty",
    }, 1);

    try testing.expectEqual(fresh.rows, incremental.rows);
    try testing.expectEqual(fresh.cols, incremental.cols);
    try testing.expectEqual(fresh.cursor.active, incremental.cursor.active);
    try testing.expectEqual(fresh.cursor.viewport, incremental.cursor.viewport);
    try testing.expectEqual(
        @as(page.Cell.Backing, @bitCast(fresh.cursor.cell)),
        @as(page.Cell.Backing, @bitCast(incremental.cursor.cell)),
    );

    const inc_data = incremental.row_data.slice();
    const new_data = fresh.row_data.slice();
    try testing.expectEqual(new_data.len, inc_data.len);
    for (0..new_data.len) |y| {
        errdefer std.log.warn("mismatch on row y={}", .{y});

        // Pins must match exactly.
        const inc_pin = inc_data.items(.pin)[y];
        const new_pin = new_data.items(.pin)[y];
        try testing.expectEqual(new_pin.node, inc_pin.node);
        try testing.expectEqual(new_pin.y, inc_pin.y);

        // Raw row data must match, except for non-visual metadata
        // fields which may legitimately be stale (see StaleOkMask).
        const inc_row = inc_data.items(.raw)[y];
        const new_row = new_data.items(.raw)[y];
        try testing.expectEqual(
            StaleOkMask.strip(new_row),
            StaleOkMask.strip(inc_row),
        );

        const inc_cells = inc_data.items(.cells)[y].slice();
        const new_cells = new_data.items(.cells)[y].slice();
        try testing.expectEqual(new_cells.len, inc_cells.len);
        const managed = new_row.managedMemory();
        for (0..new_cells.len) |x| {
            errdefer std.log.warn("mismatch on cell x={}", .{x});

            // Raw cell contents must match.
            const inc_cell = inc_cells.items(.raw)[x];
            const new_cell = new_cells.items(.raw)[x];
            try testing.expectEqual(
                @as(page.Cell.Backing, @bitCast(new_cell)),
                @as(page.Cell.Backing, @bitCast(inc_cell)),
            );

            // The style is only defined if the cell is styled or is
            // a bg-color cell within a row that has managed memory.
            if (new_cell.style_id != 0 or
                (managed and switch (new_cell.content_tag) {
                    .bg_color_rgb, .bg_color_palette => true,
                    else => false,
                }))
            {
                try testing.expect(std.meta.eql(
                    new_cells.items(.style)[x],
                    inc_cells.items(.style)[x],
                ));
            }

            // Graphemes are only defined for grapheme cells.
            if (new_cell.content_tag == .codepoint_grapheme) {
                try testing.expectEqualSlices(
                    u21,
                    new_cells.items(.grapheme)[x],
                    inc_cells.items(.grapheme)[x],
                );
            }
        }
    }
}

test "incremental updates match full rebuild" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Deterministic so failures are reproducible.
    var prng = std.Random.DefaultPrng.init(0xB0BA_CAFE);
    const rand = prng.random();

    var t = try Terminal.init(alloc, .{
        .cols = 20,
        .rows = 8,
        .max_scrollback = 500,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var inc: RenderState = .empty;
    defer inc.deinit(alloc);

    var buf: [64]u8 = undefined;
    for (0..300) |_| {
        // Perform a random batch of operations between updates.
        for (0..rand.intRangeAtMost(usize, 1, 6)) |_| {
            switch (rand.intRangeAtMost(u8, 0, 18)) {
                // Plain text (possibly wrapping and scrolling).
                0, 1, 2 => for (0..rand.intRangeAtMost(usize, 1, 30)) |_| {
                    s.nextSlice(&.{rand.intRangeAtMost(u8, 'A', 'Z')});
                },

                // Newlines to build scrollback and trigger pruning.
                3, 4 => for (0..rand.intRangeAtMost(usize, 1, 10)) |_| {
                    s.nextSlice("x\r\n");
                },

                // Cursor movement.
                5 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{
                    rand.intRangeAtMost(u16, 1, 8),
                    rand.intRangeAtMost(u16, 1, 20),
                })),

                // Styling: bold, truecolor bg, palette fg, reset.
                6 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 3)) {
                    0 => "\x1b[1m",
                    1 => "\x1b[48;2;30;60;90m",
                    2 => "\x1b[38;5;120m",
                    else => "\x1b[0m",
                }),

                // Erase ops (EL, ED variants including scrollback).
                7 => s.nextSlice(switch (rand.intRangeAtMost(u8, 0, 4)) {
                    0 => "\x1b[K",
                    1 => "\x1b[1K",
                    2 => "\x1b[J",
                    3 => "\x1b[2J",
                    else => "\x1b[3J",
                }),

                // Insert/delete lines (row rotations within regions).
                8 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}L", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                9 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}M", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Scroll up/down (page-dirty row rotations).
                10 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}S", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),
                11 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}T", .{
                    rand.intRangeAtMost(u16, 1, 4),
                })),

                // Set/reset scroll regions to exercise bounded scrolls.
                12 => {
                    const top = rand.intRangeAtMost(u16, 1, 4);
                    const bot = rand.intRangeAtMost(u16, top + 1, 8);
                    s.nextSlice(try std.fmt.bufPrint(
                        &buf,
                        "\x1b[{};{}r",
                        .{ top, bot },
                    ));
                },

                // Insert/delete/erase chars within a row.
                13 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}@", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),
                14 => s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{}P", .{
                    rand.intRangeAtMost(u16, 1, 5),
                })),

                // Reverse index (scroll down at top).
                15 => s.nextSlice("\x1bM"),

                // Wide chars and multi-codepoint graphemes.
                16 => s.nextSlice("字👨‍👩‍👧"),

                // Alternate screen switching (screen key redraw path).
                17 => s.nextSlice(if (rand.boolean())
                    "\x1b[?1049h"
                else
                    "\x1b[?1049l"),

                // DECALN full-screen fill.
                18 => s.nextSlice("\x1b#8"),

                else => unreachable,
            }
        }

        // Occasionally scroll the viewport into scrollback and back.
        switch (rand.intRangeAtMost(u8, 0, 9)) {
            0 => t.scrollViewport(.{ .delta = -3 }),
            1 => t.scrollViewport(.{ .delta = 2 }),
            2 => t.scrollViewport(.bottom),
            3 => t.scrollViewport(.top),
            else => {},
        }

        // Update our incremental state first: it must consume the dirty
        // state. The fresh state always fully rebuilds (its dimensions
        // start empty so it always redraws) and so does not depend on
        // any dirty flags.
        try inc.update(alloc, &t);

        var fresh: RenderState = .empty;
        defer fresh.deinit(alloc);
        try fresh.update(alloc, &t);

        try testCompareStates(&inc, &fresh);
    }
}

test "begin and end update" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); // Bold
    s.nextSlice("\x1b[0;3mC"); // Italic

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.beginUpdate(alloc, &t);

    // We should have pending style runs on row 0: one for the bold
    // run and one for the italic run.
    {
        const runs = state.pending_styles.items;
        try testing.expectEqual(2, runs.len);
        try testing.expectEqual(0, runs[0].y);
        try testing.expectEqual(0, runs[0].start);
        try testing.expectEqual(2, runs[0].end);
        try testing.expect(runs[0].style.flags.bold);
        try testing.expectEqual(0, runs[1].y);
        try testing.expectEqual(2, runs[1].start);
        try testing.expectEqual(3, runs[1].end);
        try testing.expect(runs[1].style.flags.italic);
    }

    // End our update. This should denormalize the runs into cells
    // and clear the pending runs.
    state.endUpdate();
    {
        try testing.expectEqual(0, state.pending_styles.items.len);

        const row_data = state.row_data.slice();
        const cells = row_data.items(.cells);
        try testing.expect(cells[0].get(0).style.flags.bold);
        try testing.expect(cells[0].get(1).style.flags.bold);
        try testing.expect(cells[0].get(2).style.flags.italic);
    }
}

test "bg color cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    // Write a styled cell (so the row has managed memory) then erase
    // the rest of the line with a palette background pending. The
    // erase produces bg_color content cells rather than styled cells.
    s.nextSlice("\x1b[1mA\x1b[48;5;1m\x1b[K");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const cells = row_data.items(.cells);
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
        try testing.expect(cell.style.flags.bold);
    }
    for (1..10) |x| {
        const cell = cells[0].get(x);
        try testing.expectEqual(
            page.Cell.ContentTag.bg_color_palette,
            cell.raw.content_tag,
        );
        try testing.expectEqual(
            Style.Color{ .palette = 1 },
            cell.style.bg_color,
        );
    }
}

test "grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A");
    s.nextSlice("👨‍"); // this has a ZWJ

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Verify we have the right number of rows
    const row_data = state.row_data.slice();
    try testing.expectEqual(3, row_data.len);

    // All rows should have cols cells
    const cells = row_data.items(.cells);
    try testing.expectEqual(10, cells[0].len);
    try testing.expectEqual(10, cells[1].len);
    try testing.expectEqual(10, cells[2].len);

    // Row zero should contain our text
    {
        const cell = cells[0].get(0);
        try testing.expectEqual('A', cell.raw.codepoint());
    }
    {
        const cell = cells[0].get(1);
        try testing.expectEqual(0x1F468, cell.raw.codepoint());
        try testing.expectEqual(.wide, cell.raw.wide);
        try testing.expectEqualSlices(u21, &.{0x200D}, cell.grapheme);
    }
    {
        const cell = cells[0].get(2);
        try testing.expectEqual(0, cell.raw.codepoint());
        try testing.expectEqual(.spacer_tail, cell.raw.wide);
    }
}

test "cursor state in viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\x1b[H");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(0, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(0, state.cursor.viewport.?.y);
    try testing.expectEqual('A', state.cursor.cell.codepoint());
    try testing.expect(state.cursor.style.default());

    // Set a style on the cursor
    s.nextSlice("\x1b[1m"); // Bold
    try state.update(alloc, &t);
    try testing.expect(!state.cursor.style.default());
    try testing.expect(state.cursor.style.flags.bold);
    s.nextSlice("\x1b[0m"); // Reset style

    // Move cursor to 2,1
    s.nextSlice("\x1b[2;3H");
    try state.update(alloc, &t);
    try testing.expectEqual(2, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(2, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);
}

test "cursor state out of viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nB\r\nC\r\nD\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Initial update
    try state.update(alloc, &t);
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expectEqual(0, state.cursor.viewport.?.x);
    try testing.expectEqual(1, state.cursor.viewport.?.y);

    // Scroll the viewport
    t.scrollViewport(.top);
    try state.update(alloc, &t);

    // Set a style on the cursor
    try testing.expectEqual(0, state.cursor.active.x);
    try testing.expectEqual(1, state.cursor.active.y);
    try testing.expect(state.cursor.viewport == null);
}

test "dirty state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // First update should trigger redraw due to resize
    try state.update(alloc, &t);
    try testing.expectEqual(.full, state.dirty);

    // Reset dirty flag and dirty rows
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Second update with no changes - no dirty rows
    try state.update(alloc, &t);
    try testing.expectEqual(.false, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        for (dirty) |d| try testing.expect(!d);
    }

    // Write to first line
    s.nextSlice("A");
    try state.update(alloc, &t);
    try testing.expectEqual(.partial, state.dirty);
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        try testing.expect(dirty[0]); // First row dirty
        try testing.expect(!dirty[1]); // Second row clean
    }
}

test "colors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Default colors
    try state.update(alloc, &t);

    // Change cursor color
    s.nextSlice("\x1b]12;#FF0000\x07");
    try state.update(alloc, &t);

    const c = state.colors.cursor.?;
    try testing.expectEqual(0xFF, c.r);
    try testing.expectEqual(0, c.g);
    try testing.expectEqual(0, c.b);

    // Change palette color 0 to White
    s.nextSlice("\x1b]4;0;#FFFFFF\x07");
    try state.update(alloc, &t);
    const p0 = state.colors.palette[0];
    try testing.expectEqual(0xFF, p0.r);
    try testing.expectEqual(0xFF, p0.g);
    try testing.expectEqual(0xFF, p0.b);
}

test "selection single line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(size.CellCountInt, &.{ 0, 2 }, &sels[1].?);
    try testing.expectEqual(null, sels[2]);

    // Clear the selection
    try screen.select(null);
    try state.update(alloc, &t);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqual(null, sels[1]);
    try testing.expectEqual(null, sels[2]);
}

test "selection multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    const screen: *Screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 2 } }).?,
        false,
    ));

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const row_data = state.row_data.slice();
    const sels = row_data.items(.selection);
    try testing.expectEqual(null, sels[0]);
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, screen.pages.cols - 1 },
        &sels[1].?,
    );
    try testing.expectEqualSlices(
        size.CellCountInt,
        &.{ 0, 2 },
        &sels[2].?,
    );
}

test "linkCells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Create a hyperlink
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    try state.update(alloc, &t);

    // Query link at 0,0
    var cells = try state.linkCells(alloc, .{ .x = 0, .y = 0 });
    defer cells.deinit(alloc);

    try testing.expectEqual(4, cells.count());
    try testing.expect(cells.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(cells.contains(.{ .x = 3, .y = 0 }));

    // Query no link
    var cells2 = try state.linkCells(alloc, .{ .x = 4, .y = 0 });
    defer cells2.deinit(alloc);
    try testing.expectEqual(0, cells2.count());
}

test "string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("AB");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();

    try state.string(&w.writer, null);

    const result = try w.toOwnedSlice();
    defer alloc.free(result);

    const expected = "AB\x00\x00\x00\n\x00\x00\x00\x00\x00\n";
    try testing.expectEqualStrings(expected, result);
}

test "linkCells with scrollback spanning pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const viewport_rows: size.CellCountInt = 10;
    const tail_rows: size.CellCountInt = 5;

    var t = try Terminal.init(alloc, .{
        .cols = page.std_capacity.cols,
        .rows = viewport_rows,
        .max_scrollback = 10_000,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    const pages = &t.screens.active.pages;
    const first_page_cap = pages.pages.first.?.capacity().rows;

    // Fill first page
    for (0..first_page_cap - 1) |_| s.nextSlice("\r\n");

    // Create second page with hyperlink
    s.nextSlice("\r\n");
    s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    for (0..(tail_rows - 1)) |_| s.nextSlice("\r\n");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const expected_viewport_y: usize = viewport_rows - tail_rows;
    // BUG: This crashes without the fix
    var cells = try state.linkCells(alloc, .{
        .x = 0,
        .y = expected_viewport_y,
    });
    defer cells.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), cells.count());
}

test "linkCells with invalid viewport point" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Row out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = 0, .y = t.rows + 10 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }

    // Col out of bound
    {
        var cells = try state.linkCells(
            alloc,
            .{ .x = t.cols + 10, .y = 0 },
        );
        defer cells.deinit(alloc);
        try testing.expectEqual(0, cells.count());
    }
}

test "flattened highlights require matching page serial" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    // Capture the live generation while terminal-owned state is in scope so
    // we can also verify beginUpdate copies it into the render row.
    const live_pin = t.screens.active.pages.getTopLeft(.viewport);
    const live_serial = live_pin.node.serial;

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const pin: PageList.Pin = pin: {
        const row_data = state.row_data.slice();
        @memset(row_data.items(.dirty), false);
        state.dirty = .false;
        break :pin row_data.items(.pin)[0];
    };
    const row_serial = state.row_data.items(.serial)[0];
    try testing.expectEqual(live_pin.node, pin.node);
    try testing.expectEqual(live_serial, row_serial);

    // Use the exact node pointer and row captured by the render state, but a
    // different generation. A reused node address must not make this stale
    // flattened highlight match.
    var hl: highlight.Flattened = .{
        .chunks = .empty,
        .top_x = 2,
        .bot_x = 4,
    };
    defer hl.deinit(alloc);
    try hl.chunks.append(alloc, .{
        .node = pin.node,
        .serial = live_serial ^ 1,
        .start = pin.y,
        .end = pin.y + 1,
    });

    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        try testing.expectEqual(0, row_data.items(.highlights)[0].items.len);
        try testing.expect(!row_data.items(.dirty)[0]);
        try testing.expectEqual(.false, state.dirty);
    }

    // The same chunk is accepted once its copied serial also matches.
    hl.chunks.items(.serial)[0] = live_serial;
    try state.updateHighlightsFlattened(alloc, 42, &.{hl});
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights)[0].items;
        try testing.expectEqual(1, row_highlights.len);
        try testing.expectEqual(42, row_highlights[0].tag);
        try testing.expectEqual([2]size.CellCountInt{ 2, 4 }, row_highlights[0].range);
        try testing.expect(row_data.items(.dirty)[0]);
        try testing.expectEqual(.partial, state.dirty);
    }
}

test "dirty row resets highlights" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABC");

    var state: RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Reset dirty state
    state.dirty = .false;
    {
        const row_data = state.row_data.slice();
        const dirty = row_data.items(.dirty);
        @memset(dirty, false);
    }

    // Manually add a highlight to row 0
    {
        const row_data = state.row_data.slice();
        const row_arenas = row_data.items(.arena);
        const row_highlights = row_data.items(.highlights);
        var arena = row_arenas[0].promote(alloc);
        defer row_arenas[0] = arena.state;
        try row_highlights[0].append(arena.allocator(), .{
            .tag = 1,
            .range = .{ 0, 2 },
        });
    }

    // Verify we have a highlight
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(1, row_highlights[0].items.len);
    }

    // Write to row 0 to make it dirty
    s.nextSlice("\x1b[H"); // Move to home
    s.nextSlice("X");
    try state.update(alloc, &t);

    // Verify the highlight was reset on the dirty row
    {
        const row_data = state.row_data.slice();
        const row_highlights = row_data.items(.highlights);
        try testing.expectEqual(0, row_highlights[0].items.len);
    }
}
